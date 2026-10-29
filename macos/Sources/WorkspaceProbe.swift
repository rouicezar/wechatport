import Foundation
import Darwin

@main struct WorkspaceProbe {
    static func main() throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1])
        let fm = FileManager.default
        let root = base.appendingPathComponent("workspace")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let w = try WorkspaceStore(root: root)
        let originalID = w.info.id
        guard try WorkspaceStore(root: root).info.id == originalID else { fatalError("identity") }
        let sentinel = w.raw.appendingPathComponent("user.txt")
        try Data("retained user data".utf8).write(to: sentinel)
        _ = try WorkspaceStore(root: root)
        guard try String(contentsOf: sentinel, encoding: .utf8) == "retained user data" else { fatalError("overwrite") }
        guard Set(try fm.contentsOfDirectory(atPath: root.path)) == ["聊天记录", "简报"] else { fatalError("two directories") }
        let conflict = base.appendingPathComponent("conflict")
        try fm.createDirectory(at: conflict, withIntermediateDirectories: true)
        try Data("do not overwrite".utf8).write(to: conflict.appendingPathComponent("简报"))
        do { _ = try WorkspaceStore(root: conflict); fatalError("conflict accepted") } catch is WorkspaceFailure { }
        guard !fm.fileExists(atPath: conflict.appendingPathComponent("聊天记录").path) else { fatalError("partial preflight") }
        let linked = base.appendingPathComponent("linked")
        try fm.createSymbolicLink(at: linked, withDestinationURL: root)
        do { _ = try WorkspaceStore(root: linked); fatalError("symlink accepted") } catch is WorkspaceFailure { }
        do { try WorkspaceStore.checkWritable(base.appendingPathComponent("offline")); fatalError("missing accepted") } catch is WorkspaceFailure { }
        let archive = try ArchiveStore(workspace: w)
        do { _ = try ArchiveStore(workspace: w); fatalError("second writer accepted") } catch is ArchiveFailure { }
        do {
            try archive.execute("BEGIN IMMEDIATE")
            try archive.execute("INSERT INTO groups VALUES('rollback','rollback')")
            try archive.execute("INSERT INTO batches VALUES('invalid','missing','p','date','archived')")
            fatalError("foreign key accepted")
        } catch { try archive.execute("ROLLBACK") }
        guard try archive.groups().isEmpty else { fatalError("transaction not rolled back") }
        let container = base.appendingPathComponent("synthetic-container")
        let pending = PendingInbox(container: container)
        let source = base.appendingPathComponent("synthetic.txt")
        let bytes = Data("synthetic only\r\n\u{0}".utf8); try bytes.write(to: source)
        let receiver = try InboxStore(root: pending.root, expected: 1)
        try receiver.copy(source, index: 0, originalName: "sample.txt", mediaType: "text/plain", control: ReceiveControl())
        try receiver.finish(control: ReceiveControl())
        let groupID = UUID().uuidString.lowercased()
        do {
            try archive.archive(batchID: receiver.id, container: container, groupID: groupID, groupName: "合成测试群", afterRename: { throw ArchiveFailure.database })
            fatalError("fault not injected")
        } catch is ArchiveFailure { }
        guard try archive.batches().isEmpty else { fatalError("early DB commit") }
        guard try archive.recover() == 1, try archive.recover() == 0 else { fatalError("recovery not idempotent") }
        try archive.archive(batchID: receiver.id, container: container, groupID: groupID, groupName: "合成测试群")
        let batches = try archive.batches()
        guard batches.count == 1 else { fatalError("duplicate archive") }
        let attachments = try archive.rows("SELECT path FROM attachments")
        let archived = URL(fileURLWithPath: batches[0].path).appendingPathComponent(attachments[0][0])
        guard archived.pathExtension == "txt", try Data(contentsOf: archived) == bytes,
              try Data(contentsOf: source) == bytes,
              try pending.validatedReady(batchID: receiver.id).attachments.count == 1 else { fatalError("source preservation") }
        let secondReceiver = try InboxStore(root:pending.root,expected:2)
        try secondReceiver.copy(source,index:0,originalName:"first.txt",mediaType:"text/plain",control:ReceiveControl())
        try secondReceiver.copy(source,index:1,originalName:"second.txt",mediaType:"text/plain",control:ReceiveControl())
        try secondReceiver.finish(control:ReceiveControl())
        do {
            try archive.archive(batchID:secondReceiver.id,container:container,groupID:groupID,groupName:"合成测试群",beforeCopy:{index in if index == 1 { throw ArchiveFailure.database }})
            fatalError("mid copy fault not injected")
        } catch is ArchiveFailure { }
        guard let job = try archive.jobs().first, job.id == secondReceiver.id, job.groupID == groupID else { fatalError("confirmed assignment lost") }
        guard try archive.recover() == 0 else { fatalError("partial falsely registered") }
        try archive.archive(batchID:job.id,container:container,groupID:job.groupID,groupName:job.groupName,collectionID:job.collectionID)
        guard try archive.jobs().isEmpty, try archive.batches().count == 2, try pending.validatedReady(batchID:secondReceiver.id).attachments.count == 2 else { fatalError("mid copy retry lost batch") }
        let invalidGroup = UUID().uuidString.lowercased()
        do { try archive.archive(batchID: receiver.id, container: container, groupID: invalidGroup, groupName: "别的群"); fatalError("silent regroup") } catch is ArchiveFailure { }
        print("PASS workspace: identity/reopen/two directories/preserve/conflict/link/missing; SQLite: single writer/FK rollback; archive: rename fault/recovery/idempotence/TXT bytes/source retained/group isolation")
    }
}
