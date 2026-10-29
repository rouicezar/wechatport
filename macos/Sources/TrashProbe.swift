import Foundation
@main struct TrashProbe {
    @MainActor static func main() async throws {
        let base = URL(fileURLWithPath:CommandLine.arguments[1]); let fm = FileManager.default
        try fm.createDirectory(at:base,withIntermediateDirectories:true)
        try fm.createDirectory(at:base.appendingPathComponent("workspace"),withIntermediateDirectories:true)
        let workspace = try WorkspaceStore(root:base.appendingPathComponent("workspace"))
        let container = base.appendingPathComponent("container"), source = base.appendingPathComponent("synthetic.txt")
        let bytes = Data("·测试甲\n2026年10月29日 10:00\n仅用于删除恢复测试。".utf8); try bytes.write(to:source)
        let groupID = UUID().uuidString.lowercased(), briefID = UUID().uuidString.lowercased()
        var batchID = "", saved: URL!, savedHash = ""
        do {
            let store = try ArchiveStore(workspace:workspace)
            let inbox = try InboxStore(root:InboxStore.inbox(container:container),expected:1)
            try inbox.copy(source,index:0,originalName:"synthetic.txt",mediaType:"text/plain",control:ReceiveControl());try inbox.finish(control:ReceiveControl());batchID = inbox.id
            try store.archive(batchID:batchID,container:container,groupID:groupID,groupName:"删除恢复验收");try store.parse(batchID:batchID)
            let messages = try store.messages(groupID:groupID)
            saved = try MarkdownWriter.write("# 保留的简报",to:workspace.briefs.appendingPathComponent("keep.md"));savedHash = MarkdownWriter.hash(try Data(contentsOf:saved))
            let record = BriefRecord(id:briefID,groupID:groupID,groupName:"删除恢复验收",createdAt:"2026-10-29T02:00:00Z",model:"deepseek-flash",catalogVersion:ModelChoice.version,template:"脱敏测试",messages:messages,snapshotHash:"synthetic",segments:[GenerationSegment(messageIDs:messages.map(\.id),output:"synthetic")],state:"saved",markdown:"# 保留的简报",error:"",savedPath:saved.path,savedHash:savedHash)
            try store.execute("INSERT INTO records VALUES('brief',?,?)",[briefID,String(data:try JSONEncoder().encode(record),encoding:.utf8)!])
            do { try store.setTrashed([batchID,UUID().uuidString.lowercased()],kind:"batch",deleted:true);fatalError("missing batch accepted") } catch is ArchiveFailure { }
            guard try store.trashIDs("batch").isEmpty else { fatalError("transaction partial deletion") }
        }
        func wait(_ model: ArchiveModel) async throws {
            for _ in 0..<300 { if !model.busy { guard model.error.isEmpty else { fatalError(model.error) }; return }; try await Task.sleep(nanoseconds:10_000_000) }; fatalError("open timeout")
        }
        func deletePhase() async throws {
            let model = ArchiveModel(); model.open(workspace); try await wait(model)
            guard model.batches.count == 1, try await model.readRecords().count == 1 else { fatalError("initial records") }
            try await model.changeTrash(ids:[batchID],kind:"batch",deleted:true)
            try await model.changeTrash(ids:[briefID],kind:"brief",deleted:true)
            guard model.batches.isEmpty, model.deletedBatches.count == 1, model.trashedBatchIDs.contains(batchID), try await model.readRecords().isEmpty,
                  try await model.readRecords(deleted:true).count == 1, try await model.conversationMessages(name:"删除恢复验收").isEmpty else { fatalError("trash leaks into active list/source") }
        }
        try await deletePhase()
        let restored = ArchiveModel(); restored.open(workspace); try await wait(restored)
        guard restored.batches.isEmpty, restored.deletedBatches.count == 1, try await restored.readRecords(deleted:true).count == 1 else { fatalError("trash not persistent") }
        try await restored.changeTrash(ids:[batchID],kind:"batch",deleted:false)
        try await restored.changeTrash(ids:[briefID],kind:"brief",deleted:false)
        guard restored.batches.count == 1, restored.deletedBatches.isEmpty, try await restored.readRecords().count == 1,
              try await restored.conversationMessages(name:"删除恢复验收").count == 1,
              try Data(contentsOf:source) == bytes, MarkdownWriter.hash(try Data(contentsOf:saved)) == savedHash else { fatalError("restore changed content") }
        try InboxVisibility.set([batchID],deleted:true,container:container)
        guard try InboxVisibility.hidden(container) == [batchID], try PendingInbox(container:container).scan().batches.count == 1 else { fatalError("pending trash removed original") }
        try InboxVisibility.set([batchID],deleted:false,container:container)
        guard try InboxVisibility.hidden(container).isEmpty else { fatalError("pending restore") }
        var selection = RecordSelection();selection.choose("a",ordered:["a","b","c","d"],toggle:false,range:false);selection.choose("b",ordered:["a","b","c","d"],toggle:true,range:false)
        guard selection.ids == ["a","b"] else { fatalError("multi selection") }
        selection.choose("d",ordered:["a","b","c","d"],toggle:false,range:true)
        guard selection.ids == ["a","b","c","d"] else { fatalError("range selection") }
        selection.choose("b",ordered:["a","b","c","d"],toggle:true,range:false)
        guard selection.ids == ["a","c","d"] else { fatalError("toggle selection") }
        print("PASS real ArchiveModel: transactional reversible batch/brief deletion, restart persistence, source exclusion, complete restore, originals/saved files unchanged; durable pending visibility; command/shift selection vectors")
    }
}
