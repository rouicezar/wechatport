import Foundation
import Combine
import SQLite3
import Darwin

struct ArchivedBatch: Identifiable {
    let id: String
    let groupID: String
    let groupName: String
    let path: String
    let receivedAt: String
    let state: String
    let filenames: String
    let byteCount: Int64
    var collectionID: String? = nil
    var rawCount: Int = 0
    var failedFiles: Int = 0
    var displayDate: String {
        guard let date = ISO8601DateFormatter().date(from:receivedAt) else { return receivedAt }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"; return formatter.string(from:date)
    }
    var parsed: Bool { ["collected","review_required"].contains(state) }
}
struct ArchiveJob: Identifiable { let id: String; let groupID: String; let groupName: String; let collectionID: String?; let state: String }
struct CollectionRecord: Identifiable { let id: String; let groupID: String; let title: String; let state: String }
struct ChatGroup: Identifiable { let id: String; let name: String }
struct DuplicateReview: Identifiable {
    let id: String
    let message: ParsedMessage
    let candidate: ParsedMessage
    let merged: Bool
    let reviewed: Bool
}
enum ArchiveFailure: LocalizedError {
    case busy, database, invalid, mismatch
    var errorDescription: String? {
        switch self {
        case .busy: return "此工作空间已被另一实例使用，请先关闭另一实例。"
        case .database: return "工作空间索引暂不可用，未报告归档成功。"
        case .invalid: return "批次或目标路径不合法，原附件保持不变。"
        case .mismatch: return "原附件校验未通过，未报告归档成功。"
        }
    }
}
private struct ArchiveManifest: Codable {
    let version: Int
    let batchID: String
    let groupID: String
    let groupName: String
    let receivedAt: String
    let sourceChannel: String
    let attachments: [InboxAttachment]
    var collectionID: String? = nil
}

// All access on the owning serial queue. Lifetime lock rejects a second writer.
final class ArchiveStore {
    let workspace: WorkspaceStore
    private var db: OpaquePointer?
    private var lockFD: Int32 = -1
    init(workspace: WorkspaceStore) throws {
        self.workspace = workspace
        let lock = workspace.metadata.appendingPathComponent("workspace.lock")
        lockFD = workspace.takeReservedWriter() ?? Darwin.open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD); lockFD = -1 }; throw ArchiveFailure.busy
        }
        do {
            let path = workspace.metadata.appendingPathComponent("workspace.sqlite")
            var s = stat()
            if lstat(path.path, &s) == 0 && s.st_mode & S_IFMT != S_IFREG { throw ArchiveFailure.invalid }
            guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw ArchiveFailure.database }
            let version = Int(try rows("PRAGMA user_version").first?.first ?? "0") ?? 0
            guard version <= 2 else { throw WorkspaceFailure.version }
            if version == 1 {
                let folder = workspace.metadata.appendingPathComponent("backups")
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                try WorkspaceStore.requireDirectory(folder)
                let backupURL = folder.appendingPathComponent("workspace-v1-"+UUID().uuidString+".sqlite")
                var backupDB: OpaquePointer?
                guard sqlite3_open_v2(backupURL.path,&backupDB,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE,nil) == SQLITE_OK else { throw ArchiveFailure.database }
                defer { sqlite3_close(backupDB) }
                guard let backup = sqlite3_backup_init(backupDB,"main",db,"main") else { throw ArchiveFailure.database }
                let step = sqlite3_backup_step(backup,-1); let finish = sqlite3_backup_finish(backup)
                guard step == SQLITE_DONE, finish == SQLITE_OK else { throw ArchiveFailure.database }
            }
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA journal_mode=WAL")
            try execute("CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
            let identities = try rows("SELECT value FROM metadata WHERE key='workspace_id'")
            if let row = identities.first { guard row[0] == workspace.info.id else { throw ArchiveFailure.invalid } }
            else { try execute("INSERT INTO metadata VALUES('workspace_id',?)", [workspace.info.id]) }
            try execute("CREATE TABLE IF NOT EXISTS groups(id TEXT PRIMARY KEY,name TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS collections(id TEXT PRIMARY KEY,group_id TEXT NOT NULL REFERENCES groups(id),title TEXT NOT NULL,state TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS archive_jobs(batch_id TEXT PRIMARY KEY,group_id TEXT NOT NULL,group_name TEXT NOT NULL,collection_id TEXT,state TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS batches(id TEXT PRIMARY KEY,group_id TEXT NOT NULL REFERENCES groups(id),path TEXT NOT NULL UNIQUE,received_at TEXT NOT NULL,state TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS duplicate_batches(batch_id TEXT PRIMARY KEY REFERENCES batches(id),linked_batch_id TEXT NOT NULL REFERENCES batches(id))")
            try execute("CREATE TABLE IF NOT EXISTS collection_batches(batch_id TEXT PRIMARY KEY REFERENCES batches(id),collection_id TEXT NOT NULL REFERENCES collections(id))")
            try execute("CREATE TABLE IF NOT EXISTS import_events(id TEXT PRIMARY KEY,batch_id TEXT NOT NULL REFERENCES batches(id),received_at TEXT NOT NULL,outcome TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS attachments(batch_id TEXT NOT NULL REFERENCES batches(id),id TEXT NOT NULL,name TEXT NOT NULL,sha256 TEXT NOT NULL,bytes INTEGER NOT NULL,path TEXT NOT NULL,PRIMARY KEY(batch_id,id))")
            try execute("CREATE TABLE IF NOT EXISTS occurrences(id TEXT PRIMARY KEY,batch_id TEXT NOT NULL REFERENCES batches(id),ordinal INTEGER NOT NULL,payload TEXT NOT NULL,canonical_id TEXT NOT NULL,suspected INTEGER NOT NULL DEFAULT 0)")
            try execute("CREATE TABLE IF NOT EXISTS dedup_overrides(id TEXT PRIMARY KEY REFERENCES occurrences(id),previous_id TEXT NOT NULL,decision TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS active_occurrences(id TEXT PRIMARY KEY REFERENCES occurrences(id),batch_id TEXT NOT NULL REFERENCES batches(id))")
            try execute("INSERT OR IGNORE INTO active_occurrences SELECT id,batch_id FROM occurrences WHERE batch_id NOT IN (SELECT batch_id FROM active_occurrences)")
            try execute("CREATE TABLE IF NOT EXISTS batch_errors(batch_id TEXT PRIMARY KEY REFERENCES batches(id),stage TEXT NOT NULL,message TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS parse_status(batch_id TEXT PRIMARY KEY REFERENCES batches(id),failed INTEGER NOT NULL,warnings TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS records(kind TEXT NOT NULL,id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(kind,id))")
            try execute("INSERT OR IGNORE INTO collections SELECT b.id,b.group_id,'收集 ' || substr(b.received_at,1,10),'collecting' FROM batches b WHERE b.id NOT IN (SELECT batch_id FROM collection_batches)")
            try execute("INSERT OR IGNORE INTO collection_batches SELECT id,id FROM batches WHERE id NOT IN (SELECT batch_id FROM collection_batches)")
            try execute("PRAGMA user_version=2")
        } catch { sqlite3_close(db); db = nil; flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1; throw error }
    }
    deinit { sqlite3_close(db); if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) } }
    private func statement(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw ArchiveFailure.database }
        for (i, value) in values.enumerated() {
            guard sqlite3_bind_text(stmt, Int32(i+1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else { sqlite3_finalize(stmt); throw ArchiveFailure.database }
        }
        return stmt
    }
    func execute(_ sql: String, _ values: [String] = []) throws {
        let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
        let status = sqlite3_step(stmt)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw ArchiveFailure.database }
    }
    func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
        var result: [[String]] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { throw ArchiveFailure.database }
            result.append((0..<sqlite3_column_count(stmt)).map { column in
                guard let p = sqlite3_column_text(stmt, column) else { return "" }; return String(cString: p)
            })
        }
    }
    func groups() throws -> [ChatGroup] {
        try rows("SELECT id,name FROM groups ORDER BY name,id").map { ChatGroup(id: $0[0], name: $0[1]) }
    }
    func canonicalGroupID(name: String) throws -> String? {
        try groups().first { ShareIntake.normalized($0.name) == ShareIntake.normalized(name) }?.id
    }
    func conversationMessages(name: String) throws -> [ParsedMessage] {
        let ids = try groups().filter { ShareIntake.normalized($0.name) == ShareIntake.normalized(name) }.map(\.id)
        let ordered = try rows("SELECT id FROM batches ORDER BY received_at,rowid")
        let order = Dictionary(uniqueKeysWithValues:ordered.enumerated().map { ($0.element[0],$0.offset) })
        var result: [ParsedMessage] = []
        for id in ids { result += try messages(groupID:id) }
        result.sort {
            if $0.batchID != $1.batchID { return (order[$0.batchID] ?? 0) < (order[$1.batchID] ?? 0) }
            return $0.ordinal < $1.ordinal
        }
        return result
    }
    func jobs() throws -> [ArchiveJob] {
        try rows("SELECT batch_id,group_id,group_name,COALESCE(collection_id,''),state FROM archive_jobs WHERE state<>'done' ORDER BY rowid").map { ArchiveJob(id:$0[0],groupID:$0[1],groupName:$0[2],collectionID:$0[3].isEmpty ? nil : $0[3],state:$0[4]) }
    }
    private static func taskTitle(_ received: String) -> String {
        guard let date = ISO8601DateFormatter().date(from:received) else { return "收集任务" }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; return "收集 " + formatter.string(from:date)
    }
    func collections() throws -> [CollectionRecord] {
        try rows("SELECT c.id,c.group_id,c.title,c.state,COALESCE((SELECT b.received_at FROM batches b JOIN collection_batches x ON x.batch_id=b.id WHERE x.collection_id=c.id ORDER BY b.rowid LIMIT 1),'') FROM collections c ORDER BY c.rowid DESC").map {
            let title = $0[2] == "收集 " + $0[4].prefix(10) ? Self.taskTitle($0[4]) : $0[2]
            return CollectionRecord(id:$0[0],groupID:$0[1],title:title,state:$0[3])
        }
    }
    func collectionState(id: String, completed: Bool) throws {
        try execute("UPDATE collections SET state=? WHERE id=?",[completed ? "completed" : "collecting",id])
    }
    func collectionID(batchID: String) throws -> String? { try rows("SELECT collection_id FROM collection_batches WHERE batch_id=?",[batchID]).first?.first }
    func batches(includeDeleted: Bool = false) throws -> [ArchivedBatch] {
        try rows("SELECT b.id,b.group_id,g.name,b.path,b.received_at,b.state,COALESCE((SELECT GROUP_CONCAT(name,char(10)) FROM attachments WHERE batch_id=b.id),''),COALESCE((SELECT SUM(bytes) FROM attachments WHERE batch_id=b.id),0),COALESCE((SELECT collection_id FROM collection_batches WHERE batch_id=b.id),''),(SELECT COUNT(*) FROM active_occurrences WHERE batch_id=b.id),COALESCE((SELECT failed FROM parse_status WHERE batch_id=b.id),0) FROM batches b JOIN groups g ON b.group_id=g.id WHERE (?='1' OR NOT EXISTS(SELECT 1 FROM records r WHERE r.kind='trash_batch' AND r.id=b.id)) ORDER BY b.received_at DESC,b.id",[includeDeleted ? "1" : "0"]).map {
            ArchivedBatch(id: $0[0], groupID: $0[1], groupName: $0[2], path: $0[3], receivedAt: $0[4], state: $0[5],filenames:$0[6],byteCount:Int64($0[7]) ?? 0,collectionID:$0[8].isEmpty ? nil : $0[8],rawCount:Int($0[9]) ?? 0,failedFiles:Int($0[10]) ?? 0)
        }
    }
    func conversationTimings() throws -> [String:MessageSpan] {
        var times: [String:[String]] = [:]
        for row in try rows("SELECT g.name,COALESCE(json_extract(o.payload,'$.timeRaw'),'') FROM occurrences o JOIN active_occurrences a ON a.id=o.id JOIN batches b ON b.id=o.batch_id JOIN groups g ON g.id=b.group_id WHERE b.state IN ('collected','review_required') AND o.id=o.canonical_id AND NOT EXISTS(SELECT 1 FROM records t WHERE t.kind='trash_batch' AND t.id=b.id)") {
            times[ShareIntake.normalized(row[0]),default:[]].append(row[1])
        }
        return times.mapValues { MessageSpan.make($0,timezone:workspace.info.timezone) }
    }
    func trashIDs(_ kind: String) throws -> Set<String> {
        guard ["batch","brief"].contains(kind) else { throw ArchiveFailure.invalid }
        return Set(try rows("SELECT id FROM records WHERE kind=?",["trash_"+kind]).map{$0[0]})
    }
    func setTrashed(_ ids: Set<String>, kind: String, deleted: Bool) throws {
        guard ["batch","brief"].contains(kind), ids.allSatisfy({UUID(uuidString:$0) != nil}) else { throw ArchiveFailure.invalid }
        try execute("BEGIN IMMEDIATE")
        do {
            for id in ids {
                let exists = try kind == "batch" ? rows("SELECT id FROM batches WHERE id=?",[id]) : rows("SELECT id FROM records WHERE kind='brief' AND id=?",[id])
                guard !exists.isEmpty else { throw ArchiveFailure.invalid }
                if deleted { try execute("INSERT OR REPLACE INTO records VALUES(?,?,?)",["trash_"+kind,id,ISO8601DateFormatter().string(from:Date())]) }
                else { try execute("DELETE FROM records WHERE kind=? AND id=?",["trash_"+kind,id]) }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private func regular(_ url: URL, directory: Bool = false) throws {
        var s = stat()
        guard lstat(url.path, &s) == 0, s.st_uid == getuid(), s.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else { throw ArchiveFailure.invalid }
    }
    private func syncDirectory(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw ArchiveFailure.invalid }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw ArchiveFailure.database }
    }
    private func validateManifest(_ manifest: ArchiveManifest, at directory: URL) throws {
        guard manifest.version == 1, UUID(uuidString: manifest.batchID) != nil,
              directory.lastPathComponent == manifest.batchID, UUID(uuidString: manifest.groupID) != nil,
              !manifest.groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !manifest.attachments.isEmpty else { throw ArchiveFailure.invalid }
        try regular(directory, directory: true)
        try regular(directory.appendingPathComponent("attachments"), directory: true)
        var seen = Set<String>()
        for a in manifest.attachments {
            guard UUID(uuidString: a.id) != nil, seen.insert(a.id).inserted,
                  a.relative_path == "attachments/" + a.id + (a.media_type == "text/plain" ? ".txt" : ".zip") else { throw ArchiveFailure.invalid }
            let path = directory.appendingPathComponent(a.relative_path)
            try regular(path)
            let value = try InboxStore.fingerprint(path)
            guard value.0 == a.sha256, value.1 == a.byte_count else { throw ArchiveFailure.mismatch }
        }
    }
    private func register(_ manifest: ArchiveManifest, directory: URL) throws {
        try validateManifest(manifest, at: directory)
        if let row = try rows("SELECT group_id,path FROM batches WHERE id=?", [manifest.batchID]).first {
            guard row == [manifest.groupID, directory.path] else { throw ArchiveFailure.invalid }; return
        }
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("INSERT OR IGNORE INTO groups(id,name) VALUES(?,?)", [manifest.groupID, manifest.groupName])
            let collectionID = manifest.collectionID ?? manifest.batchID
            if let existing = try rows("SELECT group_id,state FROM collections WHERE id=?",[collectionID]).first {
                guard existing[0] == manifest.groupID, existing[1] == "collecting" else { throw ArchiveFailure.invalid }
            } else {
                try execute("INSERT INTO collections VALUES(?,?,?,?)",[collectionID,manifest.groupID,Self.taskTitle(manifest.receivedAt),"collecting"])
            }
            try execute("INSERT INTO batches VALUES(?,?,?,?,?)", [manifest.batchID, manifest.groupID, directory.path, manifest.receivedAt, "archived"])
            try execute("INSERT INTO collection_batches VALUES(?,?)",[manifest.batchID,collectionID])
            for a in manifest.attachments {
                try execute("INSERT INTO attachments VALUES(?,?,?,?,?,?)", [manifest.batchID, a.id, a.original_name, a.sha256, String(a.byte_count), a.relative_path])
            }
            try execute("INSERT INTO import_events VALUES(?,?,?,?)", [manifest.batchID, manifest.batchID, manifest.receivedAt, "archived"])
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func archive(batchID: String, container: URL, groupID: String, groupName: String, collectionID: String? = nil,
                 afterRename: (() throws -> Void)? = nil, beforeCopy: ((Int) throws -> Void)? = nil) throws {
        guard UUID(uuidString: batchID) != nil, batchID == batchID.lowercased(), UUID(uuidString: groupID) != nil,
              !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ArchiveFailure.invalid }
        if let collectionID {
            guard UUID(uuidString:collectionID) != nil else { throw ArchiveFailure.invalid }
            if let row = try rows("SELECT group_id,state FROM collections WHERE id=?",[collectionID]).first {
                guard row[0] == groupID, row[1] == "collecting" else { throw ArchiveFailure.invalid }
            }
        }
        // Revalidate the immutable ready data at the moment of explicit selection.
        let pending = PendingInbox(container: container)
        let ready = try pending.validatedReady(batchID: batchID)
        let source = pending.root.appendingPathComponent(batchID)
        let month = String(ready.received_at.prefix(7))
        guard month.range(of: "^[0-9]{4}-[0-9]{2}$", options: .regularExpression) != nil else { throw ArchiveFailure.invalid }
        let parent = workspace.raw.appendingPathComponent(month, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: parent.path) { try regular(parent, directory: true) }
        else { try fm.createDirectory(at: parent, withIntermediateDirectories: false) }
        let dest = parent.appendingPathComponent(batchID, isDirectory: true)
        if fm.fileExists(atPath: dest.path) {
            let manifestURL = dest.appendingPathComponent("manifest.json"); try regular(manifestURL)
            let manifest = try JSONDecoder().decode(ArchiveManifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.groupID == groupID else { throw ArchiveFailure.invalid }
            try register(manifest, directory: dest)
            try execute("UPDATE archive_jobs SET state='done' WHERE batch_id=?",[batchID]); return
        }
        try execute("INSERT INTO archive_jobs VALUES(?,?,?,?,?) ON CONFLICT(batch_id) DO UPDATE SET group_id=excluded.group_id,group_name=excluded.group_name,collection_id=excluded.collection_id,state=excluded.state",[batchID,groupID,groupName,collectionID ?? "","archiving"])
        // A failed partial is kept for diagnosis; retry uses a separate staging UUID.
        let staging = parent.appendingPathComponent("." + batchID + ".partial-" + UUID().uuidString)
        try fm.createDirectory(at: staging.appendingPathComponent("attachments"), withIntermediateDirectories: true)
        var archivedAttachments: [InboxAttachment] = []
        for (index,a) in ready.attachments.enumerated() {
            try beforeCopy?(index)
            guard ["text/plain", "application/zip"].contains(a.media_type) else { throw ArchiveFailure.invalid }
            let archivedPath = "attachments/" + a.id + (a.media_type == "text/plain" ? ".txt" : ".zip")
            let input = source.appendingPathComponent(a.relative_path)
            let output = staging.appendingPathComponent(archivedPath)
            try regular(input)
            let existing = try rows("SELECT b.path,a.path FROM attachments a JOIN batches b ON a.batch_id=b.id WHERE a.sha256=? AND a.bytes=? LIMIT 1",[a.sha256,String(a.byte_count)]).first
            if let existing {
                let reused = URL(fileURLWithPath:existing[0]).appendingPathComponent(existing[1]); try regular(reused)
                let fingerprint = try InboxStore.fingerprint(reused)
                guard fingerprint.0 == a.sha256, fingerprint.1 == a.byte_count else { throw ArchiveFailure.mismatch }
                do { try fm.linkItem(at:reused,to:output) } catch { try fm.copyItem(at:input,to:output) }
            } else { try fm.copyItem(at: input, to: output) }
            let h = try FileHandle(forWritingTo: output); try h.synchronize(); try h.close()
            let hash = try InboxStore.fingerprint(output)
            guard hash.0 == a.sha256, hash.1 == a.byte_count else { throw ArchiveFailure.mismatch }
            archivedAttachments.append(InboxAttachment(id: a.id, original_name: a.original_name, relative_path: archivedPath, sha256: a.sha256, byte_count: a.byte_count, media_type: a.media_type))
        }
        let manifest = ArchiveManifest(version: 1, batchID: batchID, groupID: groupID, groupName: groupName,
            receivedAt: ready.received_at, sourceChannel: ready.source_channel, attachments: archivedAttachments, collectionID:collectionID)
        let file = staging.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: file, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: file); try handle.synchronize(); try handle.close()
        try syncDirectory(staging.appendingPathComponent("attachments")); try syncDirectory(staging)
        try fm.moveItem(at: staging, to: dest); try syncDirectory(parent)
        try afterRename?()
        try register(manifest, directory: dest)
        try execute("UPDATE archive_jobs SET state='done' WHERE batch_id=?",[batchID])
        // Inbox is retained; no private batch is silently parsed or assigned.
    }
    func messages(groupID: String) throws -> [ParsedMessage] {
        try rows("SELECT o.payload FROM occurrences o JOIN active_occurrences a ON a.id=o.id JOIN batches b ON o.batch_id=b.id WHERE b.group_id=? AND b.state IN ('collected','review_required') AND o.id=o.canonical_id AND NOT EXISTS(SELECT 1 FROM records r WHERE r.kind='trash_batch' AND r.id=b.id) ORDER BY b.rowid,o.ordinal", [groupID]).map {
            try JSONDecoder().decode(ParsedMessage.self, from: Data($0[0].utf8))
        }
    }
    func batchMessages(_ batchID: String) throws -> [ParsedMessage] {
        if let linked = try rows("SELECT linked_batch_id FROM duplicate_batches WHERE batch_id=?",[batchID]).first?.first { return try batchMessages(linked) }
        return try rows("SELECT o.payload FROM occurrences o JOIN active_occurrences a ON a.id=o.id WHERE o.batch_id=? ORDER BY o.ordinal", [batchID]).map {
            try JSONDecoder().decode(ParsedMessage.self, from: Data($0[0].utf8))
        }
    }
    func parse(batchID: String, force: Bool = false) throws {
        guard let row = try rows("SELECT group_id,path,state FROM batches WHERE id=?", [batchID]).first else { throw ArchiveFailure.invalid }
        if ["collected","review_required"].contains(row[2]) && !force { return }
        let group = row[0], directory = URL(fileURLWithPath: row[1])
        let url = directory.appendingPathComponent("manifest.json"); try regular(url)
        let manifest = try JSONDecoder().decode(ArchiveManifest.self, from: Data(contentsOf: url))
        try validateManifest(manifest, at: directory)
        let identical = try rows("SELECT b.id FROM batches b WHERE b.group_id=? AND b.id<>? AND b.state IN ('collected','review_required') AND NOT EXISTS(SELECT 1 FROM records r WHERE r.kind='trash_batch' AND r.id=b.id) AND b.id NOT IN (SELECT batch_id FROM duplicate_batches) AND (SELECT COUNT(*) FROM attachments WHERE batch_id=b.id)=(SELECT COUNT(*) FROM attachments WHERE batch_id=?) AND NOT EXISTS(SELECT sha256,COUNT(*) FROM attachments WHERE batch_id=? GROUP BY sha256 EXCEPT SELECT sha256,COUNT(*) FROM attachments WHERE batch_id=b.id GROUP BY sha256) ORDER BY b.rowid LIMIT 1", [group,batchID,batchID,batchID]).first?.first
        if let identical {
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("INSERT OR REPLACE INTO duplicate_batches VALUES(?,?)",[batchID,identical])
                try execute("DELETE FROM active_occurrences WHERE batch_id=?",[batchID])
                let sourceState = try rows("SELECT state FROM batches WHERE id=?",[identical]).first![0]
                try execute("UPDATE batches SET state=? WHERE id=?",[sourceState,batchID])
                try execute("INSERT OR REPLACE INTO parse_status SELECT ?,failed,warnings FROM parse_status WHERE batch_id=?",[batchID,identical])
                try execute("DELETE FROM batch_errors WHERE batch_id=?",[batchID])
                try execute("UPDATE import_events SET outcome='duplicate_file' WHERE batch_id=?",[batchID])
                try execute("COMMIT"); return
            } catch { try? execute("ROLLBACK"); throw error }
        }
        var output = ParseResult()
        for a in manifest.attachments {
            let path = directory.appendingPathComponent(a.relative_path)
            let bytes = try Data(contentsOf: path, options: .mappedIfSafe)
            let parsed = try ChatParser.parse(bytes, filename: a.original_name, batch: batchID)
            output.messages += parsed.messages; output.failed += parsed.failed; output.warnings += parsed.warnings
        }
        let previous = try messages(groupID: group).filter{$0.batchID != batchID}
        // Only an exact contiguous overlap of at least three located messages confirms sequence overlap.
        var matched: [Int: String] = [:]
        do {
            let incoming = output.messages
            if incoming.count >= 3 && previous.count >= 3 {
                for start in 0..<previous.count {
                    guard previous[start].precision != "unknown", previous[start].fingerprint == incoming[0].fingerprint else { continue }
                    var length = 0
                    while start+length < previous.count && length < incoming.count && previous[start+length].precision != "unknown" && previous[start+length].fingerprint == incoming[length].fingerprint { length += 1 }
                    if length >= 3 && start+length == previous.count {
                        for i in 0..<length { matched[i] = previous[start+i].id }; break
                    }
                }
            }
        }
        let fingerprints = Set(previous.filter { $0.precision != "unknown" }.map(\.fingerprint))
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM active_occurrences WHERE batch_id=?",[batchID])
            for (i,m) in output.messages.enumerated() {
                let payload = String(data: try JSONEncoder().encode(m), encoding: .utf8)!
                let suspected = matched[i] == nil && m.precision != "unknown" && fingerprints.contains(m.fingerprint)
                try execute("INSERT INTO occurrences VALUES(?,?,?,?,?,?)", [m.id,batchID,String(i+1),payload,matched[i] ?? m.id,suspected ? "1" : "0"])
                try execute("INSERT INTO active_occurrences VALUES(?,?)",[m.id,batchID])
            }
            try execute("INSERT OR REPLACE INTO parse_status VALUES(?,?,?)", [batchID,String(output.failed),String(data: try JSONEncoder().encode(output.warnings),encoding:.utf8)!])
            try execute("UPDATE batches SET state=? WHERE id=?", [output.failed > 0 ? "review_required" : "collected",batchID])
            try execute("DELETE FROM batch_errors WHERE batch_id=?",[batchID])
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func reviews(batchID: String) throws -> [DuplicateReview] {
        if !(try rows("SELECT batch_id FROM duplicate_batches WHERE batch_id=?",[batchID])).isEmpty { return [] }
        guard let group = try rows("SELECT group_id FROM batches WHERE id=?",[batchID]).first?.first else { return [] }
        let others = try messages(groupID:group).filter{$0.batchID != batchID}
        let current = try batchMessages(batchID)
        var output: [DuplicateReview] = []
        for message in current {
            let state = try rows("SELECT canonical_id,suspected FROM occurrences WHERE id=?",[message.id]).first!
            let decision = try rows("SELECT previous_id,decision FROM dedup_overrides WHERE id=?",[message.id]).first
            guard state[1] == "1" || decision != nil else { continue }
            let candidateID = decision?.first ?? state[0]
            let payload = try rows("SELECT payload FROM occurrences WHERE id=?",[candidateID == message.id ? "" : candidateID]).first?.first
            let candidate: ParsedMessage?
            if let payload { candidate = try JSONDecoder().decode(ParsedMessage.self,from:Data(payload.utf8)) }
            else { candidate = others.first{$0.fingerprint == message.fingerprint} }
            if let candidate { output.append(DuplicateReview(id:message.id,message:message,candidate:candidate,merged:state[0] != message.id,reviewed:decision != nil)) }
        }
        return output
    }
    func decide(occurrenceID: String, candidateID: String, decision: String) throws {
        guard ["merge","keep","undo"].contains(decision) else { throw ArchiveFailure.invalid }
        let source = try rows("SELECT b.group_id,o.canonical_id FROM occurrences o JOIN batches b ON o.batch_id=b.id WHERE o.id=?",[occurrenceID]).first
        let target = try rows("SELECT b.group_id,o.canonical_id FROM occurrences o JOIN batches b ON o.batch_id=b.id WHERE o.id=?",[candidateID]).first
        guard let source, let target, source[0] == target[0], occurrenceID != candidateID else { throw ArchiveFailure.invalid }
        try execute("BEGIN IMMEDIATE")
        do {
            if decision == "undo" {
                try execute("UPDATE occurrences SET canonical_id=id,suspected=1 WHERE id=?",[occurrenceID])
                try execute("DELETE FROM dedup_overrides WHERE id=?",[occurrenceID])
            } else {
                try execute("INSERT INTO dedup_overrides VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET decision=excluded.decision",[occurrenceID,candidateID,decision])
                try execute("UPDATE occurrences SET canonical_id=?,suspected=0 WHERE id=?",[decision == "merge" ? target[1] : occurrenceID,occurrenceID])
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func counts(batchID: String) throws -> (Int, Int, Int, Int) {
        if let linked = try rows("SELECT linked_batch_id FROM duplicate_batches WHERE batch_id=?",[batchID]).first?.first {
            let original = try counts(batchID:linked); return (original.0,original.0,0,0)
        }
        let all = try rows("SELECT o.id,o.canonical_id,o.suspected FROM occurrences o JOIN active_occurrences a ON a.id=o.id WHERE o.batch_id=?", [batchID])
        let duplicate = all.filter { $0[0] != $0[1] }.count
        return (all.count,duplicate,all.count-duplicate,all.filter { $0[2] == "1" }.count)
    }
    func recover() throws -> Int {
        let fm = FileManager.default
        var count = 0
        for parent in try fm.contentsOfDirectory(at: workspace.raw, includingPropertiesForKeys: nil) {
            guard parent.lastPathComponent.range(of: "^[0-9]{4}-[0-9]{2}$", options: .regularExpression) != nil else { continue }
            try regular(parent, directory: true)
            for directory in try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
                guard UUID(uuidString: directory.lastPathComponent) != nil else { continue }
                if !(try rows("SELECT id FROM batches WHERE id=?", [directory.lastPathComponent])).isEmpty { continue }
                let url = directory.appendingPathComponent("manifest.json"); try regular(url)
                let manifest = try JSONDecoder().decode(ArchiveManifest.self, from: Data(contentsOf: url))
                try register(manifest, directory: directory)
                try execute("UPDATE archive_jobs SET state='done' WHERE batch_id=?",[manifest.batchID]); count += 1
            }
        }
        return count
    }
}

@MainActor final class ArchiveModel: ObservableObject {
    @Published var batches: [ArchivedBatch] = []
    @Published var deletedBatches: [ArchivedBatch] = []
    @Published var conversationTimes: [String:MessageSpan] = [:]
    @Published var trashedBatchIDs = Set<String>()
    @Published var groups: [ChatGroup] = []
    @Published var collections: [CollectionRecord] = []
    @Published var jobs: [ArchiveJob] = []
    @Published var currentCollectionID: String?
    @Published var focusedSource: ParsedMessage?
    @Published var messages: [ParsedMessage] = []
    @Published var reviews: [DuplicateReview] = []
    @Published var loadingMessages = false
    @Published var parseWarnings: [String] = []
    @Published var unparsedFiles = 0
    @Published var counts: (Int,Int,Int,Int) = (0,0,0,0)
    @Published var error = ""
    @Published var busy = false
    @Published var notice = ""
    private let worker = DispatchQueue(label: "com.rouice.wechatport.archive")
    // Access only inside worker; UI state is main-actor isolated.
    nonisolated(unsafe) private var store: ArchiveStore?
    private var requestedBatchID: String?
    private var attemptedIntakes = Set<String>()
    private var activeWorkspaceID: String?
    func open(_ workspace: WorkspaceStore?) {
        busy = true; error = ""; messages = []; reviews = []; currentCollectionID = nil; attemptedIntakes = []; activeWorkspaceID = workspace?.info.id
        worker.async {
            self.store = nil
            do {
                guard let workspace else {
                    DispatchQueue.main.async { self.batches = []; self.deletedBatches = []; self.trashedBatchIDs = []; self.groups = []; self.busy = false }; return
                }
                self.store = try ArchiveStore(workspace: workspace)
                let recovered = try self.store!.recover()
                let batches = try self.store!.batches(); let deletedIDs = try self.store!.trashIDs("batch"); let deletedBatches = try self.store!.batches(includeDeleted:true).filter { deletedIDs.contains($0.id) }; let groups = try self.store!.groups(); let collections = try self.store!.collections(); let jobs = try self.store!.jobs()
                DispatchQueue.main.async {
                    self.batches = batches; self.deletedBatches = deletedBatches; self.trashedBatchIDs = deletedIDs; self.groups = groups; self.collections = collections; self.jobs = jobs; self.busy = false
                    self.notice = recovered > 0 ? "已恢复 \(recovered) 批已落盘的归档记录。" : ""
                }
            } catch {
                DispatchQueue.main.async { self.error = error.localizedDescription; self.busy = false; self.batches = []; self.groups = [] }
            }
        }
    }
    func refreshTimings() {
        worker.async {
            do { let values = try self.store?.conversationTimings() ?? [:]; DispatchQueue.main.async { self.conversationTimes = values } }
            catch { DispatchQueue.main.async { self.error = "消息时间索引暂不可用。" } }
        }
    }
    func conversationMessages(name: String) async throws -> [ParsedMessage] {
        try await withCheckedThrowingContinuation { continuation in
            worker.async {
                do {
                    guard let store = self.store else { throw ArchiveFailure.invalid }
                    continuation.resume(returning:try store.conversationMessages(name:name))
                } catch { continuation.resume(throwing:error) }
            }
        }
    }
    func retryConfirmed(batchID: String, pending: [PendingBatch]) {
        attemptedIntakes.remove(batchID); receiveConfirmed(pending.filter { $0.id == batchID })
    }
    func receiveConfirmed(_ pending: [PendingBatch]) {
        guard !busy, let identifier = Bundle.main.object(forInfoDictionaryKey:"WeChatPortAppGroup") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:identifier) else { return }
        let saved = Set(batches.filter { $0.state != "archived" }.map(\.id)).union(trashedBatchIDs)
        guard let item = pending.first(where:{ candidate in !saved.contains(candidate.id) && !attemptedIntakes.contains(candidate.id) && {
            guard let intake = try? ShareIntake.read(batchID:candidate.id,container:container), (try? intake.isCommitted(container:container)) == true else { return false }
            return intake.workspaceID == nil || intake.workspaceID == activeWorkspaceID
        }() }) else { return }
        guard let workspaceID = activeWorkspaceID else { return }
        attemptedIntakes.insert(item.id); busy = true
        worker.async {
            do {
                guard let store = self.store, var intake = try ShareIntake.read(batchID:item.id,container:container), intake.workspaceID == nil || intake.workspaceID == workspaceID, try intake.isCommitted(container:container) else { throw ArchiveFailure.invalid }
                if intake.workspaceID == nil {
                    if let id = intake.collectionID { try ShareCollection.bind(id:id,workspaceID:workspaceID,container:container); intake = try ShareIntake.read(batchID:item.id,container:container)! }
                    else { intake.workspaceID = workspaceID; try intake.save(container:container) }
                }
                let name = ShareIntake.normalized(intake.name)
                let groupID = try store.batches().first(where:{$0.id == item.id})?.groupID ?? store.canonicalGroupID(name:name) ?? UUID().uuidString.lowercased()
                try store.archive(batchID:item.id,container:container,groupID:groupID,groupName:name,collectionID:intake.collectionID)
                try store.parse(batchID:item.id)
                if let id = intake.collectionID {
                    let collection = try ShareCollection.read(id:id,container:container)
                    let parsed = Set(try store.batches().filter(\.parsed).map(\.id))
                    if Set(collection.batchIDs).isSubset(of:parsed) { try store.collectionState(id:id,completed:true) }
                }
                var preference = GroupPreference(); preference.templateID = intake.templateID
                let payload = String(data:try JSONEncoder().encode(preference),encoding:.utf8)!
                // Preserve existing identity/interest fields while applying the share's selected type.
                if let old = try store.rows("SELECT payload FROM records WHERE kind='group_preference' AND id=?",[groupID]).first?.first,
                   var existing = try? JSONDecoder().decode(GroupPreference.self,from:Data(old.utf8)) {
                    existing.templateID = intake.templateID
                    try store.execute("INSERT OR REPLACE INTO records VALUES('group_preference',?,?)",[groupID,String(data:try JSONEncoder().encode(existing),encoding:.utf8)!])
                } else { try store.execute("INSERT OR REPLACE INTO records VALUES('group_preference',?,?)",[groupID,payload]) }
                let batches = try store.batches(), groups = try store.groups(), collections = try store.collections()
                DispatchQueue.main.async { self.batches = batches; self.groups = groups; self.collections = collections; self.busy = false; self.error = "" }
            } catch {
                try? self.store?.execute("UPDATE batches SET state='parse_failed' WHERE id=?",[item.id])
                try? self.store?.execute("INSERT OR REPLACE INTO batch_errors VALUES(?,'intake',?)",[item.id,error.localizedDescription])
                let batches = (try? self.store?.batches()) ?? []
                let groups = (try? self.store?.groups()) ?? []
                DispatchQueue.main.async { self.batches = batches; self.groups = groups; self.busy = false; self.error = "接收处理未完成：" + error.localizedDescription }
            }
        }
    }
    func openSource(id: String) {
        worker.async {
            do {
                guard let value = try self.store?.rows("SELECT payload FROM occurrences WHERE id=?",[id]).first?.first else { throw ArchiveFailure.invalid }
                let message = try JSONDecoder().decode(ParsedMessage.self,from:Data(value.utf8))
                DispatchQueue.main.async { self.focusedSource = message }
            } catch { DispatchQueue.main.async { self.error = "无法定位原始消息，未替换为其他消息。" } }
        }
    }
    func preference(groupID: String) async throws -> GroupPreference {
        try await withCheckedThrowingContinuation { continuation in
            worker.async {
                do {
                    if let value = try self.store?.rows("SELECT payload FROM records WHERE kind='group_preference' AND id=?",[groupID]).first?.first {
                        continuation.resume(returning:try JSONDecoder().decode(GroupPreference.self,from:Data(value.utf8)))
                    } else { continuation.resume(returning:GroupPreference()) }
                } catch { continuation.resume(throwing:error) }
            }
        }
    }
    func savePreference(groupID: String,name: String,preference: GroupPreference) async throws {
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            worker.async {
                do {
                    guard let store = self.store, !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                          !(try store.rows("SELECT id FROM groups WHERE id=?",[groupID])).isEmpty else { throw ArchiveFailure.invalid }
                    let payload = String(data:try JSONEncoder().encode(preference),encoding:.utf8)!
                    try store.execute("BEGIN IMMEDIATE")
                    do {
                        try store.execute("UPDATE groups SET name=? WHERE id=?",[name,groupID])
                        try store.execute("INSERT INTO records VALUES('group_preference',?,?) ON CONFLICT(kind,id) DO UPDATE SET payload=excluded.payload",[groupID,payload])
                        try store.execute("COMMIT")
                    } catch { try? store.execute("ROLLBACK"); throw error }
                    let groups = try store.groups(); let batches = try store.batches()
                    DispatchQueue.main.async { self.groups = groups; self.batches = batches }; continuation.resume()
                } catch { continuation.resume(throwing:error) }
            }
        }
    }
    func selectedMessages(groupID: String) async throws -> [ParsedMessage] {
        try await withCheckedThrowingContinuation { continuation in
            worker.async { do { guard let store = self.store else { throw ArchiveFailure.invalid }; continuation.resume(returning:try store.messages(groupID:groupID)) } catch { continuation.resume(throwing:error) } }
        }
    }
    func changeTrash(ids: Set<String>, kind: String, deleted: Bool) async throws {
        guard !busy else { throw ArchiveFailure.busy }; busy = true
        defer { busy = false }
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            worker.async {
                do {
                    guard let store = self.store else { throw ArchiveFailure.invalid }
                    try store.setTrashed(ids,kind:kind,deleted:deleted)
                    let batches = try store.batches(), deletedIDs = try store.trashIDs("batch")
                    let removed = try store.batches(includeDeleted:true).filter { deletedIDs.contains($0.id) }
                    DispatchQueue.main.async { self.batches = batches; self.deletedBatches = removed; self.trashedBatchIDs = deletedIDs; continuation.resume() }
                } catch { continuation.resume(throwing:error) }
            }
        }
    }
    func readRecords(deleted: Bool = false) async throws -> [BriefRecord] {
        try await withCheckedThrowingContinuation { continuation in
            worker.async {
                do {
                    let rows = try self.store?.rows("SELECT payload FROM records b WHERE b.kind='brief' AND EXISTS(SELECT 1 FROM records t WHERE t.kind='trash_brief' AND t.id=b.id)=CAST(? AS INTEGER) ORDER BY rowid DESC",[deleted ? "1" : "0"]) ?? []
                    continuation.resume(returning: try rows.map { try JSONDecoder().decode(BriefRecord.self,from:Data($0[0].utf8)) })
                } catch { continuation.resume(throwing:error) }
            }
        }
    }
    func writeRecord(_ record: BriefRecord) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
            worker.async {
                do {
                    guard let store = self.store else { throw ArchiveFailure.invalid }
                    guard !(try store.rows("SELECT id FROM groups WHERE id=?",[record.groupID])).isEmpty else { throw ArchiveFailure.invalid }
                    let value = String(data:try JSONEncoder().encode(record),encoding:.utf8)!
                    try store.execute("INSERT INTO records VALUES('brief',?,?) ON CONFLICT(kind,id) DO UPDATE SET payload=excluded.payload",[record.id,value]); continuation.resume()
                } catch { continuation.resume(throwing:error) }
            }
        }
    }
    func readTemplates() async throws -> [PromptTemplate] {
        try await withCheckedThrowingContinuation { continuation in
            worker.async {
                do {
                    guard let row = try self.store?.rows("SELECT payload FROM records WHERE kind='templates' AND id='all'").first else { continuation.resume(returning:PromptTemplate.defaults); return }
                    continuation.resume(returning:try JSONDecoder().decode([PromptTemplate].self,from:Data(row[0].utf8)))
                } catch { continuation.resume(throwing:error) }
            }
        }
    }
    func writeTemplates(_ templates: [PromptTemplate]) async throws {
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            worker.async {
                do {
                    guard let store = self.store else { throw ArchiveFailure.invalid }
                    let value = String(data:try JSONEncoder().encode(templates),encoding:.utf8)!
                    try store.execute("INSERT INTO records VALUES('templates','all',?) ON CONFLICT(kind,id) DO UPDATE SET payload=excluded.payload",[value]); continuation.resume()
                } catch { continuation.resume(throwing:error) }
            }
        }
    }
    func loadMessages(batchID: String) {
        requestedBatchID = batchID; loadingMessages = true
        messages = []; reviews = []; parseWarnings = []; unparsedFiles = 0; counts = (0,0,0,0)
        worker.async {
            do {
                let messages = try self.store?.batchMessages(batchID) ?? []
                let counts = try self.store?.counts(batchID: batchID) ?? (0,0,0,0)
                let reviews = try self.store?.reviews(batchID:batchID) ?? []
                let collectionID = try self.store?.collectionID(batchID:batchID)
                let status = try self.store?.rows("SELECT failed,warnings FROM parse_status WHERE batch_id=?",[batchID]).first
                let unparsed = Int(status?.first ?? "0") ?? 0
                let warnings = try status.map { try JSONDecoder().decode([String].self,from:Data($0[1].utf8)) } ?? []
                let failure = try self.store?.rows("SELECT message FROM batch_errors WHERE batch_id=?",[batchID]).first?.first
                DispatchQueue.main.async {
                    guard self.requestedBatchID == batchID else { return }
                    self.loadingMessages = false
                    self.messages = messages; self.counts = counts; self.reviews = reviews; self.currentCollectionID = collectionID; self.parseWarnings = warnings; self.unparsedFiles = unparsed
                    if let failure { self.error = failure } else { self.error = "" }
                }
            } catch { DispatchQueue.main.async { if self.requestedBatchID == batchID { self.loadingMessages = false; self.error = error.localizedDescription } } }
        }
    }
    func setCollection(_ id: String, completed: Bool) {
        worker.async {
            do {
                try self.store?.collectionState(id:id,completed:completed)
                let collections = try self.store?.collections() ?? []
                DispatchQueue.main.async { self.collections = collections }
            } catch { DispatchQueue.main.async { self.error = error.localizedDescription } }
        }
    }
    func decide(_ review: DuplicateReview, decision: String) {
        worker.async {
            do { try self.store?.decide(occurrenceID:review.id,candidateID:review.candidate.id,decision:decision); DispatchQueue.main.async { if self.requestedBatchID == review.message.batchID { self.loadMessages(batchID:review.message.batchID) } } }
            catch { DispatchQueue.main.async { self.error = error.localizedDescription } }
        }
    }
    func parse(batchID: String, force: Bool = false) {
        guard !busy else { return }; busy = true; error = ""
        worker.async {
            do {
                guard let store = self.store else { throw ArchiveFailure.invalid }
                try store.parse(batchID: batchID,force:force)
                let batches = try store.batches(); let messages = try store.batchMessages(batchID); let counts = try store.counts(batchID: batchID)
                let reviews = try store.reviews(batchID:batchID)
                let status = try store.rows("SELECT failed,warnings FROM parse_status WHERE batch_id=?",[batchID]).first
                let unparsed = Int(status?.first ?? "0") ?? 0
                let warnings = try status.map { try JSONDecoder().decode([String].self,from:Data($0[1].utf8)) } ?? []
                DispatchQueue.main.async { self.batches = batches; if self.requestedBatchID == batchID { self.reviews = reviews; self.messages = messages; self.counts = counts; self.parseWarnings = warnings; self.unparsedFiles = unparsed }; self.busy = false; self.notice = "解析完成；请核对原文、未定位内容和疑似重复。" }
                print("event=parse_committed"); fflush(stdout)
            } catch {
                try? self.store?.execute("INSERT OR REPLACE INTO batch_errors VALUES(?,'parse',?)",[batchID,error.localizedDescription])
                try? self.store?.execute("UPDATE batches SET state='parse_failed' WHERE id=?",[batchID])
                let batches = (try? self.store?.batches()) ?? []
                DispatchQueue.main.async { self.error = error.localizedDescription; self.busy = false; self.batches = batches }
                print("event=parse_failed"); fflush(stdout)
            }
        }
    }
    func archive(batchID: String, groupID: String, groupName: String, collectionID: String? = nil) {
        guard !busy else { return }; busy = true; error = ""
        worker.async {
            do {
                guard let store = self.store,
                      let group = Bundle.main.object(forInfoDictionaryKey: "WeChatPortAppGroup") as? String,
                      let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { throw ArchiveFailure.invalid }
                let canonical = try store.canonicalGroupID(name:groupName) ?? groupID
                try store.archive(batchID: batchID, container: container, groupID: canonical, groupName: ShareIntake.normalized(groupName), collectionID:canonical == groupID ? collectionID : nil)
                try store.parse(batchID:batchID)
                let batches = try store.batches(); let groups = try store.groups(); let collections = try store.collections(); let jobs = try store.jobs()
                DispatchQueue.main.async {
                    self.batches = batches; self.groups = groups; self.collections = collections; self.jobs = jobs; self.busy = false
                    self.notice = "已加入收集箱。"
                    self.loadMessages(batchID:batchID)
                }
                print("event=archive_committed"); fflush(stdout)
            } catch {
                let jobs = (try? self.store?.jobs()) ?? []
                DispatchQueue.main.async { self.error = error.localizedDescription; self.busy = false; self.jobs = jobs }
                print("event=archive_failed"); fflush(stdout)
            }
        }
    }
}

enum ConversationOrder {
    static func names(batches: [ArchivedBatch], pins: Set<String>) -> [String] {
        var latest: [String:String] = [:]
        for batch in batches {
            let name = ShareIntake.normalized(batch.groupName)
            latest[name] = max(latest[name] ?? "",batch.receivedAt)
        }
        return latest.keys.sorted {
            if pins.contains($0) != pins.contains($1) { return pins.contains($0) }
            return latest[$0] == latest[$1] ? $0 < $1 : latest[$0]! > latest[$1]!
        }
    }
}

struct MessageSpan: Sendable {
    var dates: [Date] = []
    var hasUnknown = false
    var timezone = TimeZone.current.identifier
    static func parse(_ raw: String, formatter: DateFormatter) -> Date? {
        let iso = ISO8601DateFormatter()
        if let value = iso.date(from:raw) { return value }
        for format in ["yyyy年M月d日 HH:mm","yyyy-MM-dd HH:mm:ss","yyyy-MM-dd HH:mm","yyyy/MM/dd HH:mm:ss","yyyy/MM/dd HH:mm","yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            if let value = formatter.date(from:raw) { return value }
        }
        return nil
    }
    static func formatter(_ timezone: String) -> DateFormatter {
        let value = DateFormatter(); value.locale = Locale(identifier:"en_US_POSIX"); value.timeZone = TimeZone(identifier:timezone) ?? .current; value.isLenient = false; return value
    }
    static func make(_ raw: [String], timezone: String = TimeZone.current.identifier) -> Self {
        let formatter = formatter(timezone); var result = Self(timezone:timezone)
        for text in raw { if let date = parse(text,formatter:formatter) { result.dates.append(date) } else { result.hasUnknown = true } }
        result.dates = Array(Set(result.dates)).sorted(); return result
    }
    var display: String {
        guard let first = dates.first, let last = dates.last else { return "时间未知" }
        let formatter = Self.formatter(timezone); formatter.dateFormat = "yyyy-MM-dd H:mm"
        return formatter.string(from:first) + " 至 " + formatter.string(from:last) + (hasUnknown ? " · 部分时间未知" : "")
    }
    func matches(_ token: String) -> Bool {
        let formatter = Self.formatter(timezone)
        if token.range(of:#"^\d{1,2}:\d{2}$"#,options:.regularExpression) != nil {
            let pieces = token.split(separator:":").compactMap{Int($0)}
            guard pieces.count == 2 else { return false }
            var calendar = Calendar(identifier:.gregorian); calendar.timeZone = formatter.timeZone
            return dates.contains { calendar.component(.hour,from:$0) == pieces[0] && calendar.component(.minute,from:$0) == pieces[1] }
        }
        formatter.dateFormat = "yyyy-MM-dd H:mm"
        return dates.contains { date in formatter.string(from:date).contains(token) }
    }
}
enum RecordSearch {
    static func matches(_ query: String, text: [String], imported: [String], messages: MessageSpan) -> Bool {
        let query = query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let joined = (text+imported).joined(separator:"\n")
        let exactTime = query.range(of:#"^\d{1,2}:\d{2}$"#,options:.regularExpression) != nil
        if !exactTime && joined.localizedCaseInsensitiveContains(query) { return true }
        // A date range checks actual known timestamps, never assumes activity on intervening days.
        let range = query.components(separatedBy:"至").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}
        if range.count == 2 {
            let formatter = MessageSpan.formatter(messages.timezone)
            func bound(_ text: String,end: Bool) -> Date? {
                if text.count == 10 {
                    formatter.dateFormat = "yyyy-MM-dd"
                    guard let day = formatter.date(from:text) else { return nil }
                    var calendar = Calendar(identifier:.gregorian); calendar.timeZone = formatter.timeZone
                    return end ? calendar.date(byAdding:.day,value:1,to:day)?.addingTimeInterval(-0.001) : day
                }
                return MessageSpan.parse(text,formatter:formatter)
            }
            if let start = bound(range[0],end:false), let end = bound(range[1],end:true), start <= end {
                let dates = messages.dates + imported.compactMap { MessageSpan.parse($0,formatter:formatter) }
                return dates.contains{$0 >= start && $0 <= end}
            }
            let tokens = query.split(whereSeparator:{$0.isWhitespace})
            if tokens.count > 1 { return tokens.allSatisfy { matches(String($0),text:text,imported:imported,messages:messages) } }
            return false
        }
        return query.split(whereSeparator:{$0.isWhitespace}).allSatisfy { part in
            let token = String(part)
            if token.range(of:#"^\d{1,2}:\d{2}$"#,options:.regularExpression) != nil { return messages.matches(token) || MessageSpan.make(imported,timezone:messages.timezone).matches(token) }
            return joined.localizedCaseInsensitiveContains(token) || messages.matches(token)
        }
    }
}
