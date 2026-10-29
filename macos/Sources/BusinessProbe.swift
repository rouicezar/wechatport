import Foundation

@main struct BusinessProbe {
    static func main() throws {
        let base = URL(fileURLWithPath:CommandLine.arguments[1]); let fm = FileManager.default
        let cases = base.appendingPathComponent("fixtures")
        let span = MessageSpan.make(["2026年10月20日 08:07","2026年10月29日 18:07","无时间"],timezone:"Asia/Shanghai")
        guard span.display == "2026-10-20 8:07 至 2026-10-29 18:07 · 部分时间未知",
              RecordSearch.matches("验收 2026-10-20",text:["验收群"],imported:["2026-10-29T09:00:00Z"],messages:span),
              RecordSearch.matches("验收 2026-10-19至2026-10-21",text:["验收群"],imported:[],messages:span),
              RecordSearch.matches("17:00",text:["验收群"],imported:["2026-10-29T09:00:00Z"],messages:span),
              RecordSearch.matches("08:07",text:[],imported:[],messages:span),
              !RecordSearch.matches("2026-10-25",text:["验收群"],imported:[],messages:span),
              !RecordSearch.matches("8:07",text:[],imported:["2026-10-29T10:07:00Z"],messages:MessageSpan.make(["2026年10月29日 18:07"],timezone:"Asia/Shanghai")),
              MessageSpan.make(["无时间"],timezone:"Asia/Shanghai").display == "时间未知" else { fatalError("message range/comprehensive search/unknown time") }
        let batch = UUID().uuidString.lowercased()
        let zip = try ChatParser.parse(Data(contentsOf:cases.appendingPathComponent("valid.zip")),filename:"valid.zip",batch:batch)
        guard zip.messages.count == 3, zip.messages[0].sender == "甲", zip.messages[0].text == "第一条\n续行", zip.messages[1].precision == "minute" else { fatalError("parse semantic mismatch") }
        let media = try ChatParser.parse(Data(contentsOf:cases.appendingPathComponent("large-media.zip")),filename:"large-media.zip",batch:batch)
        guard media.messages.count == 3, VideoCoverage.count(media.messages) == 2,
              GenerationRules.videoNotice(media.messages).contains("2 条视频"), media.warnings.contains(where:{$0.contains("2 条视频")}) else { fatalError("large ignored video/repeated video-message count") }
        let transactionMessages = try ChatParser.text("2026-10-29 08:00 甲: [转账]\n2026-10-29 08:01 乙: [转账]\n2026-10-29 08:02 甲: [红包]",batch:batch,entry:"transactions.txt")
        let transactionNotice = TransactionCoverage.notice(transactionMessages)
        guard TransactionCoverage.transfers(transactionMessages).count == 2, TransactionCoverage.redPackets(transactionMessages).count == 1,
              transactionNotice.contains("2 条转账相关记录"), transactionNotice.contains("1 条红包相关记录"), transactionNotice.contains("具体金额、实际笔数、资金方向及收款状态"), !transactionNotice.contains("2笔"), !transactionNotice.contains("2 笔") else { fatalError("transaction markers inflated into settled payments") }
        let ordinaryTransactionTalk = try ChatParser.text("2026-10-29 09:00 甲: 明天再讨论转账和红包功能\n2026-10-29 09:01 乙: [转账]这个词只是举例，不是交易\n2026-10-29 09:02 甲: 例如：[红包]\n2026-10-29 09:03 乙: ‘[转账]’",batch:batch,entry:"ordinary.txt")
        guard TransactionCoverage.transfers(ordinaryTransactionTalk).isEmpty,
              TransactionCoverage.redPackets(ordinaryTransactionTalk).isEmpty,
              TransactionCoverage.notice(ordinaryTransactionTalk).isEmpty,
              TransactionCoverage.previewNotice(ordinaryTransactionTalk).isEmpty,
              TransactionCoverage.modelContext(ordinaryTransactionTalk).contains("未识别到任何") else { fatalError("ordinary discussion triggered transaction warning") }
        guard TransactionCoverage.previewNotice(transactionMessages).contains("2 条转账标识消息"),
              TransactionCoverage.previewNotice(transactionMessages).contains("1 条红包标识消息") else { fatalError("evidence-specific transaction warning") }
        let unknown = try ChatParser.text("无时间原文\n保留换行",batch:batch,entry:"unknown.txt")
        guard unknown.count == 1, unknown[0].precision == "unknown", unknown[0].text == "无时间原文\n保留换行" else { fatalError("unknown time") }
        for name in ["traversal.zip","absolute.zip","link.zip","ratio.zip","corrupt.zip"] {
            do { _ = try BoundedZIP.entries(Data(contentsOf:cases.appendingPathComponent(name))); fatalError("unsafe zip accepted: " + name) } catch is ParseFailure { }
        }
        let root = base.appendingPathComponent("workspace"); try fm.createDirectory(at:root,withIntermediateDirectories:true)
        let workspace = try WorkspaceStore(root:root); let store = try ArchiveStore(workspace:workspace)
        let container = base.appendingPathComponent("container")
        let group = UUID().uuidString.lowercased()
        func receive(_ filename: String, groupID: String) throws -> String {
            let source = cases.appendingPathComponent(filename)
            let inbox = try InboxStore(root:InboxStore.inbox(container:container),expected:1,sourceChannel:"manual_import")
            try inbox.copy(source,index:0,originalName:filename,mediaType:filename.hasSuffix(".zip") ? "application/zip" : "text/plain",control:ReceiveControl()); try inbox.finish(control:ReceiveControl())
            try store.archive(batchID:inbox.id,container:container,groupID:groupID,groupName:"同名群")
            try store.parse(batchID:inbox.id)
            return inbox.id
        }
        let a = try receive("a.txt",groupID:group)
        let b = try receive("b.txt",groupID:group)
        let countA = try store.counts(batchID:a), countB = try store.counts(batchID:b)
        guard countA.0 == 100, countA.2 == 100, countB.0 == 100, countB.1 == 20, countB.2 == 80 else { fatalError("overlap counts") }
        let merged = try store.messages(groupID:group)
        guard merged.count == 180, merged.map(\.text) == (0..<180).map({"消息\($0)"}) else { fatalError("overlap order/content") }
        let repeatBatch = try receive("repeat.txt",groupID:group)
        let repeatCount = try store.counts(batchID:repeatBatch)
        guard repeatCount.0 == 2, repeatCount.1 == 0, repeatCount.2 == 2, repeatCount.3 == 2 else { fatalError("minute repeat lost") }
        let reviews = try store.reviews(batchID:repeatBatch)
        guard reviews.count == 2 else { fatalError("review missing") }
        try store.decide(occurrenceID:reviews[0].id,candidateID:reviews[0].candidate.id,decision:"merge")
        guard try store.counts(batchID:repeatBatch).1 == 1 else { fatalError("merge failed") }
        try store.decide(occurrenceID:reviews[0].id,candidateID:reviews[0].candidate.id,decision:"undo")
        guard try store.counts(batchID:repeatBatch).1 == 0 else { fatalError("undo failed") }
        let duplicate = try receive("a.txt",groupID:group)
        guard try store.counts(batchID:duplicate).2 == 0 else { fatalError("same file repeated") }
        let other = UUID().uuidString.lowercased()
        _ = try receive("a.txt",groupID:other)
        guard try store.messages(groupID:other).count == 100, try store.groups().count == 2 else { fatalError("cross-group dedup") }
        guard try store.canonicalGroupID(name:"  同名群  ") != nil,
              try store.conversationMessages(name:"同名群").count == 282 else { fatalError("same-name conversation aggregation lost batches") }
        func row(_ name: String,_ date: String) -> ArchivedBatch { ArchivedBatch(id:UUID().uuidString.lowercased(),groupID:group,groupName:name,path:"",receivedAt:date,state:"collected",filenames:"",byteCount:0) }
        let sorting = [row("甲","2026-10-29T03:00:00Z"),row("乙","2026-10-29T02:00:00Z"),row("丙","2026-10-29T01:00:00Z"),row("甲","2026-10-28T01:00:00Z")]
        guard ConversationOrder.names(batches:sorting,pins:[]) == ["甲","乙","丙"],
              ConversationOrder.names(batches:sorting,pins:["乙","丙"]) == ["乙","丙","甲"] else { fatalError("pin/newest order") }
        let intake = ShareIntake(version:1,batchID:a,name:"同名群",templateID:"actions")
        try intake.save(container:container)
        guard try ShareIntake.read(batchID:a,container:container)?.templateID == "actions" else { fatalError("confirmed intake lost") }
        guard try ShareIntake.read(batchID:b,container:container) == nil else { fatalError("unconfirmed batch auto classified") }
        do { try ShareIntake(version:1,batchID:UUID().uuidString.lowercased(),name:"同名群",templateID:"focus").save(container:container); fatalError("intake without ready") } catch is InboxError { }
        do { try ShareIntake(version:1,batchID:a,name:" ",templateID:"focus").validate(); fatalError("empty name") } catch is InboxError { }
        let staged = try ShareCollection.update(id:nil,batchID:b,name:"连续收集",templateID:"actions",workspaceID:workspace.info.id,complete:false,container:container)
        guard try ShareIntake.read(batchID:b,container:container)?.isCommitted(container:container) == false,
              try ShareCollection.active(container:container)?.batchIDs == [b] else { fatalError("staged receipt consumed before finish") }
        // Simulate a new extension process reading only durable state.
        let resumed = try ShareCollection.active(container:container)!
        let nextCollection = try ShareCollection.update(id:resumed.id,batchID:repeatBatch,name:resumed.name,templateID:resumed.templateID,workspaceID:resumed.workspaceID,complete:false,container:container)
        guard nextCollection.batchIDs == [b,repeatBatch], try ShareIntake.read(batchID:repeatBatch,container:container)?.isCommitted(container:container) == false else { fatalError("second batch lost or early commit") }
        let completed = try ShareCollection.update(id:nextCollection.id,batchID:duplicate,name:nextCollection.name,templateID:nextCollection.templateID,workspaceID:nextCollection.workspaceID,complete:true,container:container)
        guard completed.batchIDs == [b,repeatBatch,duplicate], try ShareCollection.active(container:container) == nil else { fatalError("collection finish") }
        for id in completed.batchIDs {
            guard let metadata = try ShareIntake.read(batchID:id,container:container), try metadata.isCommitted(container:container), metadata.collectionID == staged.id, metadata.workspaceID == workspace.info.id else { fatalError("batch lost collection identity") }
        }
        do { _ = try ShareCollection.update(id:staged.id,batchID:a,name:"迟到",templateID:"focus",workspaceID:workspace.info.id,complete:false,container:container); fatalError("late append accepted") } catch is InboxError { }
        // Failed final write must not unlock any subset. A missing receipt is recoverable, not success.
        let failure = try ShareCollection.update(id:nil,batchID:a,name:"恢复",templateID:"focus",workspaceID:nil,complete:false,container:container)
        do { _ = try ShareCollection.update(id:failure.id,batchID:UUID().uuidString.lowercased(),name:"恢复",templateID:"focus",workspaceID:nil,complete:true,container:container); fatalError("missing receipt accepted") } catch is InboxError { }
        guard try ShareIntake.read(batchID:a,container:container)?.isCommitted(container:container) == false else { fatalError("partial collection committed") }
        do { _ = try ShareCollection.update(id:failure.id,batchID:nil,name:"恢复",templateID:"focus",workspaceID:nil,complete:true,container:container,beforeCommit:{ throw InboxError.incomplete }); fatalError("fault ignored") } catch is InboxError { }
        guard try ShareIntake.read(batchID:a,container:container)?.isCommitted(container:container) == false else { fatalError("crash gate") }
        _ = try ShareCollection.update(id:failure.id,batchID:nil,name:"恢复",templateID:"focus",workspaceID:nil,complete:true,container:container)
        try ShareCollection.bind(id:failure.id,workspaceID:workspace.info.id,container:container)
        guard try ShareIntake.read(batchID:a,container:container)?.workspaceID == workspace.info.id, try ShareIntake.read(batchID:a,container:container)?.isCommitted(container:container) == true else { fatalError("workspace binding") }
        do { try ShareCollection.bind(id:failure.id,workspaceID:UUID().uuidString.lowercased(),container:container); fatalError("cross workspace binding") } catch is InboxError { }
        let partialGroup = UUID().uuidString.lowercased()
        let partial = try receive("partial.zip",groupID:partialGroup)
        guard try store.batches().first(where:{$0.id == partial})?.state == "review_required", try store.batchMessages(partial).count == 3 else { fatalError("partial falsely complete") }
        let partialDuplicate = try receive("partial.zip",groupID:partialGroup)
        guard try store.counts(batchID:partialDuplicate).2 == 0, try store.batches().first(where:{$0.id == partialDuplicate})?.state == "review_required" else { fatalError("partial duplicate imported again") }
        let minuteGroup = UUID().uuidString.lowercased()
        _ = try receive("minute-a.txt",groupID:minuteGroup)
        let minuteB = try receive("minute-b.txt",groupID:minuteGroup)
        let minuteCounts = try store.counts(batchID:minuteB)
        guard minuteCounts.0 == 2, minuteCounts.1 == 0, minuteCounts.2 == 2, minuteCounts.3 == 2 else { fatalError("minute precision repeat lost") }
        let nativeGroup = UUID().uuidString.lowercased()
        _ = try receive("native-a.txt",groupID:nativeGroup)
        let nativeB = try receive("native-b.txt",groupID:nativeGroup)
        guard try store.counts(batchID:nativeB).1 == 20, try store.messages(groupID:nativeGroup).count == 180 else { fatalError("native overlap") }
        guard let history = try store.batches().first(where:{$0.id == a}), history.rawCount == 100, history.failedFiles == 0, history.byteCount > 0,
              let partialHistory = try store.batches().first(where:{$0.id == partial}), partialHistory.failedFiles == 1 else { fatalError("history metadata counts/capacity/partial status") }
        let obsidian = base.appendingPathComponent("Obsidian测试库/简报",isDirectory:true)
        try fm.createDirectory(at:obsidian,withIntermediateDirectories:true)
        let note = try MarkdownWriter.write("# 合成笔记\n中文路径保存",to:obsidian.appendingPathComponent("群聊.md"))
        guard try String(contentsOf:note,encoding:.utf8) == "# 合成笔记\n中文路径保存" else { fatalError("external Chinese vault directory save") }
        let blocked = base.appendingPathComponent("denied",isDirectory:true)
        try fm.createDirectory(at:blocked,withIntermediateDirectories:true)
        try fm.setAttributes([.posixPermissions:0o500],ofItemAtPath:blocked.path)
        defer { try? fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:blocked.path) }
        do { _ = try MarkdownWriter.write("draft",to:blocked.appendingPathComponent("out.md")); fatalError("write to denied folder accepted") } catch is WorkspaceFailure { }
        let taskID = try store.collectionID(batchID:a)!
        try store.collectionState(id:taskID,completed:true)
        guard try store.collections().first(where:{$0.id == taskID})?.state == "completed" else { fatalError("complete task") }
        try store.collectionState(id:taskID,completed:false)
        guard try store.collections().first(where:{$0.id == taskID})?.state == "collecting" else { fatalError("reopen task") }
        let native = try ChatParser.text("·甲\n2026年10月29日 08:05\n第一行\n第二行\n\n·乙\n2026年10月29日 08:06\n再见\n",batch:batch,entry:"聊天记录.txt")
        guard native.count == 2, native[0].sender == "甲", native[0].text.contains("第一行\n第二行"), native[1].precision == "minute" else { fatalError("native format") }
        let segments = try GenerationRules.segments(merged)
        guard segments.flatMap(\.messageIDs) == merged.map(\.id) else { fatalError("coverage") }
        let tenThousand = (0..<10001).map { index in ParsedMessage(id:UUID().uuidString.lowercased(),batchID:batch,entry:"synthetic.txt",ordinal:index+1,sender:"合成",timeRaw:"2026-10-29 08:00",precision:"minute",text:"唯一合成记录\(index)",warning:"") }
        let largeSegments = try GenerationRules.segments(tenThousand)
        guard largeSegments.flatMap(\.messageIDs) == tenThousand.map(\.id), Set(largeSegments.flatMap(\.messageIDs)).count == 10001 else { fatalError("long coverage truncated") }
        let oversized = ParsedMessage(id:UUID().uuidString.lowercased(),batchID:batch,entry:"synthetic.txt",ordinal:1,sender:"合成",timeRaw:"",precision:"unknown",text:String(repeating:"x",count:17000),warning:"")
        do { _ = try GenerationRules.segments([oversized]); fatalError("oversize silently accepted") } catch is ModelFailure { }
        try GenerationRules.validateReferences("事实 [["+merged[0].id+"]]",ids:Set(merged.map(\.id)))
        do { try GenerationRules.validateReferences("伪造 [[outside]]",ids:Set(merged.map(\.id))); fatalError("reference accepted") } catch is ModelFailure { }
        let target = workspace.briefs.appendingPathComponent("same.md")
        let first = try MarkdownWriter.write("# 第一个\n",to:target)
        let second = try MarkdownWriter.write("# 第二个\n",to:target)
        guard first != second, try String(contentsOf:first,encoding:.utf8) == "# 第一个\n", try String(contentsOf:second,encoding:.utf8) == "# 第二个\n" else { fatalError("overwrite") }
        let missing = base.appendingPathComponent("offline/out.md")
        do { _ = try MarkdownWriter.write("draft",to:missing); fatalError("missing destination accepted") } catch { }
        let golden = try JSONSerialization.jsonObject(with:Data(contentsOf:cases.appendingPathComponent("golden.json"))) as! [String:Any]
        var reading = BriefRecord(id:UUID().uuidString.lowercased(),groupID:group,groupName:"合成群",createdAt:"2026-10-29T00:00:00Z",model:"deepseek-flash",catalogVersion:ModelChoice.version,template:"synthetic",messages:Array(merged.prefix(3)),snapshotHash:"synthetic",segments:[GenerationSegment(messageIDs:Array(merged.prefix(3)).map(\.id),output:"synthetic")],state:"saved",markdown:"",error:"")
        reading.markdown = "# 原文\n" + GenerationRules.footer(reading) + "\n**外部新增**\n"
        guard GenerationRules.readingMarkdown(reading) == "# 原文\n\n**外部新增**\n" else { fatalError("external addition hidden") }
        reading.markdown = reading.markdown.replacingOccurrences(of:"快照：synthetic",with:"用户修改的来源说明")
        guard GenerationRules.readingMarkdown(reading) == reading.markdown else { fatalError("edited footer hidden") }
        let sharedURL = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("shared/contracts/v1/examples/golden-snapshot.json")
        let shared = try JSONSerialization.jsonObject(with:Data(contentsOf:sharedURL)) as! [String:Any]
        var sharedData = shared["data"] as! [String:Any]
        let sharedHash = sharedData.removeValue(forKey:"snapshot_hash") as! String
        guard MarkdownWriter.hash(try StableJSON.encode(sharedData)) == sharedHash else { fatalError("shared golden snapshot mismatch") }
        let input = golden["input"] as! [String:Any]
        let stable = try StableJSON.encode(input)
        guard MarkdownWriter.hash(stable) == golden["hash"] as! String else { fatalError("stable hash mismatch") }
        let migrateRoot = base.appendingPathComponent("migration")
        try fm.createDirectory(at:migrateRoot,withIntermediateDirectories:true)
        let migrate = try WorkspaceStore(root:migrateRoot)
        func seedOldVersion() throws {
            let database = try ArchiveStore(workspace:migrate)
            try database.execute("INSERT INTO groups VALUES('retained','retained')")
            try database.execute("PRAGMA user_version=1")
        }
        try seedOldVersion()
        let upgraded = try ArchiveStore(workspace:migrate)
        guard try upgraded.groups().count == 1, (try fm.contentsOfDirectory(atPath:migrate.metadata.appendingPathComponent("backups").path)).count == 1 else { fatalError("migration backup") }
        print("PASS parser ZIP boundaries/CRC/deflate, text provenance/unknown; 200 imported/20 duplicate/180 ordered messages; minute repeats retained, same file idempotent, historical same-name batches aggregated, canonical name lookup, multi-pin newest order, confirmed intake durability/empty rejection; generation coverage/reference rejection; Markdown no-overwrite/error; independent stable hash")
    }
}
