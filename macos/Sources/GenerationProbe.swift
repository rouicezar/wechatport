import Foundation

final class GenerationFixture: URLProtocol {
    static var calls = 0
    static var ids: [String] = []
    static var hanging = false
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "api.deepseek.com", request.value(forHTTPHeaderField:"Authorization") == "Bearer synthetic-not-a-key" else { fatalError("unexpected destination") }
        Self.calls += 1
        if Self.hanging {
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"text/event-stream"])!,cacheStoragePolicy:.notAllowed)
            return
        }
        let status = Self.calls == 2 ? 503 : 200
        let text: String
        if Self.calls == 1 { text = "第一段事实 [["+Self.ids[0]+"]]" }
        else if Self.calls == 3 { text = "第二段事实 [["+Self.ids[1]+"]]" }
        else { text = "# 汇总\n- 事实一 [["+Self.ids[0]+"]]\n- 事实二 [["+Self.ids[1]+"]]" }
        let chunk: [String:Any] = ["choices":[["delta":["content":text],"finish_reason":NSNull()]]]
        let data = try! JSONSerialization.data(withJSONObject:chunk)
        let body = "data: " + String(data:data,encoding:.utf8)! + "\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"text/event-stream"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
@main struct GenerationProbe {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1]); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let workspace = try WorkspaceStore(root:root)
        let group = UUID().uuidString.lowercased()
        func seed() throws { let store = try ArchiveStore(workspace:workspace); try store.execute("INSERT INTO groups VALUES(?,?)",[group,"合成恢复群"]) }
        try seed()
        let archive = ArchiveModel(); archive.open(workspace)
        func wait(_ condition:@MainActor ()->Bool) async throws {
            for _ in 0..<1000 { if !condition() { return }; try await Task.sleep(nanoseconds:10_000_000) }
            fatalError("timed out")
        }
        try await wait { archive.busy }
        guard archive.error.isEmpty else { fatalError("archive open") }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [GenerationFixture.self]
        let first = ParsedMessage(id:UUID().uuidString.lowercased(),batchID:UUID().uuidString.lowercased(),entry:"synthetic.txt",ordinal:1,sender:"合成甲",timeRaw:"2026-10-29 08:00",precision:"minute",text:String(repeating:"a",count:10000),warning:"")
        let second = ParsedMessage(id:UUID().uuidString.lowercased(),batchID:first.batchID,entry:"synthetic.txt",ordinal:2,sender:"合成乙",timeRaw:"2026-10-29 08:01",precision:"minute",text:String(repeating:"b",count:10000),warning:"")
        let video = ParsedMessage(id:UUID().uuidString.lowercased(),batchID:first.batchID,entry:"synthetic.txt",ordinal:3,sender:"合成乙",timeRaw:"2026-10-29 08:02",precision:"minute",text:"[视频] media/synthetic.mp4",warning:"")
        let transfer = ParsedMessage(id:UUID().uuidString.lowercased(),batchID:first.batchID,entry:"synthetic.txt",ordinal:4,sender:"合成甲",timeRaw:"2026-10-29 08:03",precision:"minute",text:"[转账]",warning:"")
        GenerationFixture.ids = [first.id,second.id]
        let model = BriefModel(client:DeepSeekClient(configuration:configuration),credential:{"synthetic-not-a-key"})
        await model.create(groupID:group,groupName:"合成恢复群",messages:[first,second,video,transfer],template:"synthetic",model:"deepseek-flash",archive:archive)
        try await wait { model.busy }
        guard let failed = model.records.first, failed.state == "failed", failed.segments.count == 2,
              failed.segments[0].output != nil, failed.segments[1].output == nil, GenerationFixture.calls == 2 else { fatalError("failed segment persistence") }
        let restored = BriefModel(client:DeepSeekClient(configuration:configuration),credential:{"synthetic-not-a-key"})
        await restored.load(archive)
        restored.run(id:failed.id,archive:archive); try await wait { restored.busy }
        guard let complete = restored.records.first, complete.state == "draft", complete.segments.allSatisfy({$0.output != nil}),GenerationFixture.calls == 4, complete.messages.map(\.id) == [first.id,second.id,video.id,transfer.id], complete.markdown.contains(first.id),complete.markdown.contains(second.id) else { fatalError("successful segment rerun or incomplete snapshot") }
        guard complete.markdown.contains("聊天记录中包含 1 条视频，已忽略视频内容。"), GenerationRules.readingMarkdown(complete).contains("聊天记录中包含 1 条视频") else { fatalError("video count missing from rendered draft") }
        guard complete.markdown.contains("1 条转账相关记录"), complete.markdown.contains("具体金额、实际笔数、资金方向及收款状态，请从微信聊天记录中查看。"), complete.markdown.contains(transfer.id) else { fatalError("transaction warning missing") }
        restored.save(id:complete.id,directory:workspace.briefs,choose:false,archive:archive)
        try await wait { restored.records.first(where:{$0.id == complete.id})?.state != "saved" }
        guard let saved = restored.records.first(where:{$0.id == complete.id}), let path = saved.savedPath,
              try String(contentsOfFile:path,encoding:.utf8).contains("聊天记录中包含 1 条视频，已忽略视频内容。"),
              try String(contentsOfFile:path,encoding:.utf8).contains("具体金额、实际笔数、资金方向及收款状态，请从微信聊天记录中查看。") else { fatalError("saved video notice missing") }
        // A cancelled network stream must never become a complete draft.
        GenerationFixture.hanging = true
        let cancelled = BriefModel(client:DeepSeekClient(configuration:configuration),credential:{"synthetic-not-a-key"})
        await cancelled.create(groupID:group,groupName:"合成恢复群",messages:[first],template:"synthetic",model:"deepseek-flash",archive:archive)
        try await Task.sleep(nanoseconds:100_000_000); cancelled.cancel(); try await wait { cancelled.busy }
        guard cancelled.records.first?.state == "cancelled",cancelled.records.first?.markdown.isEmpty == true else { fatalError("cancelled stream marked success") }
        print("PASS production generation/SQLite: segment 1 retained on segment 2 HTTP failure; new model instance restores and only requests failed segment plus merge; fixed snapshot/ref validation; cancelled stream never draft. URLProtocol/dummy key only; not a real-provider long run.")
    }
}
