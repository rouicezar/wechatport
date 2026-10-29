import Foundation
import CoreFoundation
import Darwin

// Notification carries no paths, batch IDs or chat content. It is only a hint.
// Darwin notifications are system-wide: correctness/trust comes solely from
// the sandboxed per-user App Group and validated disk records, never the sender.
enum InboxSignal {
    static let name = "com.rouice.wechatport.inbox.changed" as CFString
    static func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name), nil, nil, true)
    }
}

struct PendingBatch: Codable, Identifiable {
    let id: String
    let receivedAt: String
    let attachmentCount: Int
    let state: String
    var originalNames: [String] = []
    var displayDate: String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = iso.date(from: receivedAt) ?? ISO8601DateFormatter().date(from: receivedAt) else { return receivedAt }
        let display = DateFormatter(); display.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return display.string(from: date)
    }
}
struct PendingSnapshot {
    var batches: [PendingBatch] = []
    var rejected = 0
    var incomplete = 0
}
private struct PendingLedger: Codable {
    let version: Int
    let batches: [PendingBatch]
}
private struct DecodedReady: Decodable { let kind: String; let data: InboxReady }

// Serial across threads AND processes. Immutable ready files remain authoritative;
// ledger is a rebuildable, durable receipt index, not an archive or group mapping.
final class PendingInbox {
    let root: URL
    let queue: URL
    init(container: URL) {
        root = InboxStore.inbox(container: container)
        queue = root.deletingLastPathComponent().appendingPathComponent("Pending", isDirectory: true)
    }
    private func regular(_ url: URL, directory: Bool = false) throws {
        var s = stat()
        guard lstat(url.path, &s) == 0, s.st_uid == getuid(),
              s.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else { throw InboxError.corrupt }
    }
    private func keys(_ object: Any?, _ expected: Set<String>) throws -> [String: Any] {
        guard let d = object as? [String: Any], Set(d.keys) == expected else { throw InboxError.corrupt }
        return d
    }
    private func validate(_ directory: URL) throws -> InboxReady {
        try regular(directory, directory: true)
        try regular(directory.appendingPathComponent("attachments"), directory: true)
        let file = directory.appendingPathComponent("ready.json")
        try regular(file)
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancelled").path) else { throw InboxError.cancelled }
        let bytes = try Data(contentsOf: file)
        let top = try keys(JSONSerialization.jsonObject(with: bytes), ["kind", "data"])
        let data = try keys(top["data"], ["schema_version", "batch_id", "received_at", "source_channel", "state", "attachments"])
        guard let list = data["attachments"] as? [Any] else { throw InboxError.corrupt }
        for item in list { _ = try keys(item, ["id", "original_name", "relative_path", "sha256", "byte_count", "media_type"]) }
        let envelope = try JSONDecoder().decode(DecodedReady.self, from: bytes)
        let ready = envelope.data
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let validDate = formatter.date(from: ready.received_at) ?? ISO8601DateFormatter().date(from: ready.received_at)
        guard envelope.kind == "ready", ready.schema_version == "1.0.0", ready.state == "ready",
              ["system_share", "manual_import"].contains(ready.source_channel), validDate != nil,
              UUID(uuidString: ready.batch_id) != nil, ready.batch_id == directory.lastPathComponent,
              !ready.attachments.isEmpty else { throw InboxError.corrupt }
        var ids = Set<String>()
        for a in ready.attachments {
            guard UUID(uuidString: a.id) != nil, ids.insert(a.id.lowercased()).inserted,
                  a.relative_path == "attachments/" + a.id, a.byte_count >= 0,
                  a.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw InboxError.corrupt }
            let path = directory.appendingPathComponent(a.relative_path)
            try regular(path)
            let fingerprint = try InboxStore.fingerprint(path)
            guard fingerprint.0 == a.sha256, fingerprint.1 == a.byte_count else { throw InboxError.corrupt }
        }
        return ready
    }
    func validatedReady(batchID: String) throws -> InboxReady {
        guard UUID(uuidString: batchID) != nil, batchID == batchID.lowercased() else { throw InboxError.corrupt }
        try regular(root, directory: true)
        return try validate(root.appendingPathComponent(batchID))
    }
    func scan(beforeCommit: (() throws -> Void)? = nil) throws -> PendingSnapshot {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try regular(root, directory: true)
        try fm.createDirectory(at: queue, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try regular(queue, directory: true)
        let fd = Darwin.open(queue.appendingPathComponent("queue.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw InboxError.busy }
        defer { close(fd) }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_uid == getuid(), s.st_mode & S_IFMT == S_IFREG,
              flock(fd, LOCK_EX) == 0 else { throw InboxError.busy }
        defer { flock(fd, LOCK_UN) }
        let recovery = try InboxStore.recover(root: root)
        var result = PendingSnapshot(); result.incomplete = recovery.incomplete + recovery.busy
        for path in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard UUID(uuidString: path.lastPathComponent) != nil else { continue }
            do {
                let ready = try validate(path)
                result.batches.append(PendingBatch(id: ready.batch_id, receivedAt: ready.received_at,
                    attachmentCount: ready.attachments.count, state: "waiting_workspace", originalNames:ready.attachments.map(\.original_name)))
            } catch { result.rejected += 1 }
        }
        result.batches.sort { ($0.receivedAt, $0.id) < ($1.receivedAt, $1.id) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(PendingLedger(version: 1, batches: result.batches))
        try beforeCommit?()
        let ledger = queue.appendingPathComponent("queue.json")
        // Reject redirected destination; atomic write replaces only our own index.
        if fm.fileExists(atPath: ledger.path) { try regular(ledger) }
        try encoded.write(to: ledger, options: .atomic)
        let handle = try FileHandle(forWritingTo: ledger); defer { try? handle.close() }
        try handle.synchronize()
        let dir = Darwin.open(queue.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard dir >= 0 else { throw InboxError.corrupt }; defer { close(dir) }
        guard fsync(dir) == 0 else { throw InboxError.corrupt }
        return result
    }
}
