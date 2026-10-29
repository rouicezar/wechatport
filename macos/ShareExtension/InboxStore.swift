import Foundation
import CryptoKit
import Darwin

struct InboxAttachment: Codable {
    let id: String
    let original_name: String
    let relative_path: String
    let sha256: String
    let byte_count: Int64
    let media_type: String
}
struct InboxReady: Codable {
    let schema_version: String
    let batch_id: String
    let received_at: String
    let source_channel: String
    let state: String
    let attachments: [InboxAttachment]
}
private struct ReadyEnvelope: Encodable {
    let kind = "ready"
    let data: InboxReady
}
private struct Journal: Codable {
    var version = 1
    var batch: String
    var received: String
    var expected: Int
    var sourceChannel: String?
    var cancelled = false
    var completed: [Int: InboxAttachment] = [:]
}
enum InboxError: Error { case cancelled, invalidFile, incomplete, corrupt, busy }

// Publication and cancellation have a single ordering, including late UI cancellation.
final class ReceiveControl {
    private let lock = NSLock()
    private var cancelled = false
    private var committed = false
    private var cancellation: (() -> Void)?
    func onCancel(_ action: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        cancellation = action; if cancelled { action() }
    }
    @discardableResult func cancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if committed { return false }
        cancelled = true; cancellation?(); return true
    }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw InboxError.cancelled }
    }
    func publish(_ body: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw InboxError.cancelled }
        try body(); committed = true
    }
}

// One instance belongs to one serial receive operation. Lock spans its entire lifetime.
final class InboxStore {
    let root: URL
    let partial: URL
    let id: String
    private var journal: Journal
    private let lockFD: Int32
    private let fm = FileManager.default

    static func inbox(container: URL) -> URL {
        container.appendingPathComponent("Library/Application Support/WeChatPort/Inbox", isDirectory: true)
    }
    init(root: URL, expected: Int, sourceChannel: String = "system_share") throws {
        guard expected > 0, ["system_share", "manual_import"].contains(sourceChannel) else { throw InboxError.incomplete }
        self.root = root
        id = UUID().uuidString.lowercased()
        partial = root.appendingPathComponent(id + ".partial", isDirectory: true)
        journal = Journal(batch: id, received: ISO8601DateFormatter().string(from: Date()), expected: expected, sourceChannel: sourceChannel)
        try fm.createDirectory(at: partial.appendingPathComponent("attachments"), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        lockFD = Darwin.open(partial.appendingPathComponent("receive.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD) }; throw InboxError.busy
        }
        try persist()
    }
    private init(root: URL, partial: URL) throws {
        self.root = root; self.partial = partial
        id = String(partial.lastPathComponent.dropLast(8))
        guard UUID(uuidString: id) != nil else { throw InboxError.corrupt }
        lockFD = Darwin.open(partial.appendingPathComponent("receive.lock").path, O_RDWR | O_NOFOLLOW)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD) }; throw InboxError.busy
        }
        do {
            journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: partial.appendingPathComponent("journal.json")))
            guard journal.version == 1, journal.batch == id, journal.expected > 0 else { throw InboxError.corrupt }
        } catch { close(lockFD); throw error }
    }
    deinit { flock(lockFD, LOCK_UN); close(lockFD) }

    private static func syncDirectory(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.synchronize(); try Self.syncDirectory(url.deletingLastPathComponent())
    }
    private func persist() throws { try write(journal, to: partial.appendingPathComponent("journal.json")) }
    static func fingerprint(_ url: URL) throws -> (String, Int64) {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw InboxError.invalidFile }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var statbuf = stat()
        guard fstat(fd, &statbuf) == 0, statbuf.st_mode & S_IFMT == S_IFREG else { throw InboxError.invalidFile }
        var hash = SHA256(); var bytes: Int64 = 0
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
            hash.update(data: data); bytes += Int64(data.count)
        }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), bytes)
    }
    private func valid(_ attachment: InboxAttachment) throws -> Bool {
        var parent = stat()
        guard lstat(partial.appendingPathComponent("attachments").path, &parent) == 0,
              parent.st_mode & S_IFMT == S_IFDIR, parent.st_uid == getuid() else { throw InboxError.corrupt }
        guard UUID(uuidString: attachment.id) != nil,
              attachment.relative_path == "attachments/" + attachment.id else { throw InboxError.corrupt }
        let result = try Self.fingerprint(partial.appendingPathComponent(attachment.relative_path))
        return result.0 == attachment.sha256 && result.1 == attachment.byte_count
    }
    func hasCompleted(_ index: Int) throws -> Bool {
        guard let attachment = journal.completed[index] else { return false }
        guard try valid(attachment) else { throw InboxError.corrupt }
        return true
    }
    // The source must be used synchronously inside the NSItemProvider callback.
    func copy(_ source: URL, index: Int, originalName: String?, mediaType: String,
              control: ReceiveControl, chunkObserved: ((Int64) throws -> Void)? = nil) throws {
        try control.check()
        guard index >= 0, index < journal.expected, source.isFileURL else { throw InboxError.invalidFile }
        if try hasCompleted(index) { return }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let sourceFD = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard sourceFD >= 0 else { throw InboxError.invalidFile }
        let input = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat()
        guard fstat(sourceFD, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw InboxError.invalidFile }
        let attachmentID = UUID().uuidString.lowercased()
        let relative = "attachments/" + attachmentID
        let destination = partial.appendingPathComponent(relative)
        let temporary = destination.appendingPathExtension("partial")
        let fd = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close() }
        var hash = SHA256(); var count: Int64 = 0
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
            try control.check(); try output.write(contentsOf: data)
            hash.update(data: data); count += Int64(data.count)
            try chunkObserved?(count)
        }
        try control.check()
        var after = stat()
        guard fstat(sourceFD, &after) == 0, count == before.st_size, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else { throw InboxError.incomplete }
        try output.synchronize(); try output.close()
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let reread = try Self.fingerprint(temporary)
        guard digest == reread.0, count == reread.1 else { throw InboxError.corrupt }
        try fm.moveItem(at: temporary, to: destination)
        try Self.syncDirectory(destination.deletingLastPathComponent())
        journal.completed[index] = InboxAttachment(id: attachmentID,
            original_name: originalName ?? source.lastPathComponent, relative_path: relative,
            sha256: digest, byte_count: count, media_type: mediaType)
        try persist()
    }
    func cancellationMarker() -> () -> Void {
        let path = partial.appendingPathComponent("cancelled")
        return {
            // Independent marker avoids races with the streaming journal writer.
            try? Data("cancelled".utf8).write(to: path, options: .atomic)
            if let h = try? FileHandle(forWritingTo: path) { try? h.synchronize(); try? h.close() }
            try? Self.syncDirectory(path.deletingLastPathComponent())
        }
    }
    @discardableResult func finish(control: ReceiveControl, beforeRename: (() throws -> Void)? = nil) throws -> URL {
        guard !journal.cancelled, !fm.fileExists(atPath: partial.appendingPathComponent("cancelled").path), journal.completed.count == journal.expected else { throw InboxError.incomplete }
        var attachments: [InboxAttachment] = []
        for index in 0..<journal.expected {
            try control.check()
            guard let attachment = journal.completed[index], try valid(attachment) else { throw InboxError.corrupt }
            attachments.append(attachment)
        }
        let ready = InboxReady(schema_version: "1.0.0", batch_id: id, received_at: journal.received,
                               source_channel: journal.sourceChannel ?? "system_share", state: "ready", attachments: attachments)
        let destination = root.appendingPathComponent(id, isDirectory: true)
        try control.publish {
            try write(ReadyEnvelope(data: ready), to: partial.appendingPathComponent("ready.json"))
            try beforeRename?()
            try fm.moveItem(at: partial, to: destination)
            do { try Self.syncDirectory(root) }
            catch {
                // Fail closed: keep the batch recoverable, never report a durable
                // receive if the parent directory could not be synchronized.
                try? fm.moveItem(at: destination, to: partial)
                throw error
            }
        }
        return destination
    }
    struct Recovery { var recovered = 0; var incomplete = 0; var busy = 0 }
    static func recover(root: URL) throws -> Recovery {
        var result = Recovery()
        guard FileManager.default.fileExists(atPath: root.path) else { return result }
        for path in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
        where path.lastPathComponent.hasSuffix(".partial") {
            do {
                guard try path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw InboxError.corrupt }
                let store = try InboxStore(root: root, partial: path)
                guard FileManager.default.fileExists(atPath: path.appendingPathComponent("ready.json").path) else { throw InboxError.incomplete }
                try store.finish(control: ReceiveControl()); result.recovered += 1
            } catch InboxError.busy { result.busy += 1 }
              catch { result.incomplete += 1 }
        }
        return result
    }
}

// Optional user-confirmed metadata lives beside ready.json; the v1 transport stays unchanged.
struct ShareIntake: Codable {
    let version: Int
    let batchID: String
    let name: String
    let templateID: String
    var workspaceID: String? = nil
    var collectionID: String? = nil
    static func normalized(_ name: String) -> String { name.trimmingCharacters(in:.whitespacesAndNewlines).precomposedStringWithCanonicalMapping }
    func validate() throws {
        guard version == 1, UUID(uuidString:batchID) != nil, batchID == batchID.lowercased(),
              !Self.normalized(name).isEmpty, name.count <= 200, !name.unicodeScalars.contains(where:{$0.value < 32}),
              !templateID.isEmpty, templateID.count <= 100, workspaceID == nil || UUID(uuidString:workspaceID!) != nil,
              collectionID == nil || UUID(uuidString:collectionID!)?.uuidString.lowercased() == collectionID else { throw InboxError.corrupt }
    }
    func save(container: URL) throws {
        try validate()
        let folder = InboxStore.inbox(container:container).appendingPathComponent(batchID)
        guard FileManager.default.fileExists(atPath:folder.appendingPathComponent("ready.json").path) else { throw InboxError.incomplete }
        try Self.write(self,to:folder.appendingPathComponent("intake.json"))
    }
    static func read(batchID: String, container: URL) throws -> ShareIntake? {
        guard UUID(uuidString:batchID) != nil else { throw InboxError.corrupt }
        let path = InboxStore.inbox(container:container).appendingPathComponent(batchID).appendingPathComponent("intake.json")
        guard FileManager.default.fileExists(atPath:path.path) else { return nil }
        let value = try JSONDecoder().decode(Self.self,from:boundedData(path)); try value.validate()
        guard value.batchID == batchID else { throw InboxError.corrupt }; return value
    }
    func isCommitted(container: URL) throws -> Bool {
        guard let collectionID else { return true } // Existing single-batch confirmations.
        let collection = try ShareCollection.read(id:collectionID,container:container)
        return collection.completed && collection.batchIDs.contains(batchID) && collection.name == name && collection.templateID == templateID && collection.workspaceID == workspaceID
    }
    static func boundedData(_ path: URL) throws -> Data {
        var info = stat()
        guard lstat(path.path,&info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size <= 1024*1024 else { throw InboxError.corrupt }
        return try Data(contentsOf:path)
    }
    static func write<T:Encodable>(_ value: T,to path: URL) throws {
        try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let data = try JSONEncoder().encode(value)
        try data.write(to:path,options:.atomic)
        let fd = Darwin.open(path.path,O_RDONLY | O_NOFOLLOW); guard fd >= 0 else { throw InboxError.corrupt }; defer { close(fd) }
        guard fsync(fd) == 0, try Data(contentsOf:path) == data else { throw InboxError.corrupt }
        let directory = Darwin.open(path.deletingLastPathComponent().path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw InboxError.corrupt }; defer { close(directory) }
        guard fsync(directory) == 0 else { throw InboxError.corrupt }
    }
}
struct ShareChoice: Codable { let id: String; let name: String }
struct ShareCatalog: Codable {
    let types: [ShareChoice]
    let suggestedName: String
    let suggestedType: String
    let expiresAt: Date?
    var workspaceID: String? = nil
    static func url(_ container: URL) -> URL { container.appendingPathComponent("Library/Application Support/WeChatPort/share-catalog.json") }
    static func load(_ container: URL) -> Self? { try? JSONDecoder().decode(Self.self,from:ShareIntake.boundedData(url(container))) }
}

// Reversible list deletion; original receipt files are never removed.
enum InboxVisibility {
    static func path(_ container: URL) -> URL { container.appendingPathComponent("Library/Application Support/WeChatPort/hidden-receipts.json") }
    static func hidden(_ container: URL) throws -> Set<String> {
        let file = path(container)
        guard FileManager.default.fileExists(atPath:file.path) else { return [] }
        let ids = try JSONDecoder().decode(Set<String>.self,from:ShareIntake.boundedData(file))
        guard ids.allSatisfy({UUID(uuidString:$0) != nil}) else { throw InboxError.corrupt }; return ids
    }
    static func set(_ ids: Set<String>, deleted: Bool, container: URL) throws {
        guard ids.allSatisfy({UUID(uuidString:$0) != nil}) else { throw InboxError.corrupt }
        let folder = path(container).deletingLastPathComponent()
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let fd = Darwin.open(folder.appendingPathComponent("visibility.lock").path,O_CREAT | O_RDWR | O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw InboxError.corrupt }; defer { close(fd) }
        guard flock(fd,LOCK_EX) == 0 else { throw InboxError.busy }; defer { flock(fd,LOCK_UN) }
        var value = try hidden(container)
        if deleted { value.formUnion(ids) } else { value.subtract(ids) }
        try ShareIntake.write(value,to:path(container))
    }
}

struct RecordSelection {
    var ids = Set<String>()
    var anchor: String?
    mutating func choose(_ id: String, ordered: [String], toggle: Bool, range: Bool) {
        if range, let anchor, let a = ordered.firstIndex(of:anchor), let b = ordered.firstIndex(of:id) {
            ids.formUnion(ordered[min(a,b)...max(a,b)])
        } else if toggle {
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            anchor = id
        } else { ids = [id]; anchor = id }
    }
}

// A collection commit is the final gate. All bytes and metadata precede it;
// a crash before the commit leaves a recoverable draft, never a partial submission.
struct ShareCollection: Codable, Identifiable {
    let id: String
    var name: String
    var templateID: String
    var workspaceID: String?
    var batchIDs: [String]
    var completed: Bool
    static func root(_ container: URL) -> URL { container.appendingPathComponent("Library/Application Support/WeChatPort/Collections") }
    static func read(id: String, container: URL) throws -> Self {
        guard UUID(uuidString:id)?.uuidString.lowercased() == id else { throw InboxError.corrupt }
        let value = try JSONDecoder().decode(Self.self,from:ShareIntake.boundedData(root(container).appendingPathComponent(id+".json")))
        guard value.id == id, Set(value.batchIDs).count == value.batchIDs.count, !value.batchIDs.isEmpty, value.batchIDs.count <= 1000 else { throw InboxError.corrupt }
        for batch in value.batchIDs { try ShareIntake(version:1,batchID:batch,name:value.name,templateID:value.templateID,workspaceID:value.workspaceID,collectionID:id).validate() }
        return value
    }
    static func active(container: URL) throws -> Self? {
        let path = root(container).appendingPathComponent("active.json")
        guard FileManager.default.fileExists(atPath:path.path) else { return nil }
        let id = try JSONDecoder().decode(String.self,from:ShareIntake.boundedData(path))
        let value = try read(id:id,container:container)
        return value.completed ? nil : value
    }
    static func bind(id: String, workspaceID: String, container: URL) throws {
        guard UUID(uuidString:workspaceID) != nil else { throw InboxError.corrupt }
        let folder = root(container)
        let fd = Darwin.open(folder.appendingPathComponent("collection.lock").path,O_CREAT | O_RDWR | O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw InboxError.corrupt }; defer { close(fd) }
        guard flock(fd,LOCK_EX) == 0 else { throw InboxError.busy }; defer { flock(fd,LOCK_UN) }
        var value = try read(id:id,container:container)
        guard value.completed, value.workspaceID == nil || value.workspaceID == workspaceID else { throw InboxError.corrupt }
        if value.workspaceID == workspaceID { return }
        value.completed = false
        try ShareIntake.write(value,to:folder.appendingPathComponent(id+".json"))
        value.workspaceID = workspaceID
        // A failed binding remains a draft and can be finished again in the UI.
        try ShareIntake.write(value,to:folder.appendingPathComponent(id+".json"))
        for batch in value.batchIDs { try ShareIntake(version:1,batchID:batch,name:value.name,templateID:value.templateID,workspaceID:workspaceID,collectionID:id).save(container:container) }
        value.completed = true; try ShareIntake.write(value,to:folder.appendingPathComponent(id+".json"))
    }
    @discardableResult static func update(id: String?, batchID: String?, name: String, templateID: String, workspaceID: String?, complete: Bool, container: URL, beforeCommit: (() throws -> Void)? = nil) throws -> Self {
        let folder = root(container)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let fd = Darwin.open(folder.appendingPathComponent("collection.lock").path,O_CREAT | O_RDWR | O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw InboxError.corrupt }; defer { close(fd) }
        guard flock(fd,LOCK_EX) == 0 else { throw InboxError.busy }; defer { flock(fd,LOCK_UN) }
        var value: Self
        if let id { value = try read(id:id,container:container); guard !value.completed, value.workspaceID == workspaceID else { throw InboxError.corrupt } }
        else {
            // Do not silently overwrite another simultaneously opened share's draft.
            guard try active(container:container) == nil else { throw InboxError.busy }
            value = Self(id:UUID().uuidString.lowercased(),name:name,templateID:templateID,workspaceID:workspaceID,batchIDs:[],completed:false)
        }
        if let batchID, !value.batchIDs.contains(batchID) { value.batchIDs.append(batchID) }
        guard !value.batchIDs.isEmpty, value.batchIDs.count <= 1000 else { throw InboxError.corrupt }
        value.name = ShareIntake.normalized(name); value.templateID = templateID
        // Reject missing ready receipts before altering the recoverable draft.
        for batch in value.batchIDs {
            guard FileManager.default.fileExists(atPath:InboxStore.inbox(container:container).appendingPathComponent(batch).appendingPathComponent("ready.json").path) else { throw InboxError.incomplete }
        }
        // Publish a recoverable draft before changing any batch metadata.
        for batch in value.batchIDs { try ShareIntake(version:1,batchID:batch,name:value.name,templateID:templateID,workspaceID:workspaceID,collectionID:value.id).validate() }
        try ShareIntake.write(value,to:folder.appendingPathComponent(value.id+".json"))
        try ShareIntake.write(value.id,to:folder.appendingPathComponent("active.json"))
        for batch in value.batchIDs {
            try ShareIntake(version:1,batchID:batch,name:value.name,templateID:templateID,workspaceID:workspaceID,collectionID:value.id).save(container:container)
        }
        if complete { try beforeCommit?(); value.completed = true; try ShareIntake.write(value,to:folder.appendingPathComponent(value.id+".json")) }
        return value
    }
}
