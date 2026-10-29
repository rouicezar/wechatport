import SwiftUI
import AppKit
import UniformTypeIdentifiers

private func productIcon() -> NSImage {
    guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
          let image = NSImage(contentsOf: url) else { return NSApp.applicationIconImage }
    return image
}

final class InboxModel: ObservableObject {
    static let shared = InboxModel()
    @Published var batches: [PendingBatch] = []
    @Published var deletedBatches: [PendingBatch] = []
    @Published var status = "正在检查已接收批次…"
    @Published var warning = ""
    private let worker = DispatchQueue(label: "com.rouice.wechatport.pending")
    private var timer: Timer?
    func start() {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            InboxModel.shared.refresh()
        }, InboxSignal.name, nil, .deliverImmediately)
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in self.refresh() }
        refresh()
    }
    func importFiles() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true; panel.allowedContentTypes = [.zip, .plainText]
        panel.message = "只导入你选择的 ZIP/TXT，不扫描其他文件。导入后仍需确认群。"; panel.prompt = "导入所选文件"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        for url in urls { _ = url.startAccessingSecurityScopedResource() }
        worker.async {
            defer { for url in urls { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let group = Bundle.main.object(forInfoDictionaryKey: "WeChatPortAppGroup") as? String,
                      let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { throw InboxError.invalidFile }
                let store = try InboxStore(root: InboxStore.inbox(container: container), expected: urls.count, sourceChannel: "manual_import")
                for (i,url) in urls.enumerated() {
                    guard ["txt","zip"].contains(url.pathExtension.lowercased()) else { throw InboxError.invalidFile }
                    try store.copy(url, index: i, originalName: url.lastPathComponent, mediaType: url.pathExtension.lowercased() == "txt" ? "text/plain" : "application/zip", control: ReceiveControl())
                }
                try store.finish(control: ReceiveControl()); self.refresh()
            } catch { DispatchQueue.main.async { self.warning = "导入未完成，未报告成功。原文件保持不变，请重试。" } }
        }
    }
    func changeTrash(_ ids: Set<String>, deleted: Bool) throws {
        guard let group = Bundle.main.object(forInfoDictionaryKey:"WeChatPortAppGroup") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:group) else { throw InboxError.invalidFile }
        try InboxVisibility.set(ids,deleted:deleted,container:container); refresh()
    }
    func refresh() {
        worker.async {
            do {
                guard let group = Bundle.main.object(forInfoDictionaryKey: "WeChatPortAppGroup") as? String,
                      let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { throw InboxError.invalidFile }
                let snapshot = try PendingInbox(container: container).scan()
                let hidden = try InboxVisibility.hidden(container)
                DispatchQueue.main.async {
                    self.deletedBatches = snapshot.batches.filter { hidden.contains($0.id) }
                    self.batches = snapshot.batches.filter { !hidden.contains($0.id) }
                    self.status = snapshot.batches.isEmpty ? "尚无完整的待处理批次" : "已接收 \(snapshot.batches.count) 批 · 等待选择工作空间"
                    self.warning = (snapshot.rejected + snapshot.incomplete) > 0 ? "有 \(snapshot.rejected) 批校验未通过、\(snapshot.incomplete) 批尚未完成；原文件保留，请保留来源并重试或重新分享。" : ""
                }
                print("event=pending_scan ready=\(snapshot.batches.count) rejected=\(snapshot.rejected) incomplete=\(snapshot.incomplete)"); fflush(stdout)
            } catch {
                DispatchQueue.main.async { self.status = "暂时无法读取接收队列"; self.warning = "未报告处理成功，原附件保留。请点击重新检查；持续失败时重新打开 App。" }
                print("event=pending_scan_failed"); fflush(stdout)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = productIcon()
        let appearance = UserDefaults.standard.string(forKey:"appearance") ?? "system"
        NSApp.appearance = appearance == "dark" ? NSAppearance(named:.darkAqua) : appearance == "light" ? NSAppearance(named:.aqua) : nil
        print("event=app_started version=\(AppVersion.current.version) build=\(AppVersion.current.build)"); fflush(stdout)
        if CommandLine.arguments.contains("--probe-group") {
            guard let group = Bundle.main.object(forInfoDictionaryKey: "WeChatPortAppGroup") as? String,
                  let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { exit(20) }
            do {
                let marker = url.appendingPathComponent("p1-02-probe-" + UUID().uuidString)
                let data = Data("WeChatPort synthetic permission probe".utf8)
                try data.write(to: marker, options: .atomic)
                guard try Data(contentsOf: marker) == data else { exit(21) }
                try FileManager.default.removeItem(at: marker)
                print("event=group_probe_pass"); fflush(stdout); exit(0)
            } catch { exit(22) }
        }
        InboxModel.shared.start()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        InboxModel.shared.refresh()
        if !flag {
            guard let window = sender.windows.first(where:{$0.canBecomeKey && $0.styleMask.contains(.titled)}) else { return false }
            window.makeKeyAndOrderFront(nil); sender.activate(ignoringOtherApps:true)
        }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !UserDefaults.standard.bool(forKey:"showMenuBar") }
    func applicationWillTerminate(_ notification: Notification) { print("event=app_terminated"); fflush(stdout) }
}

enum ProductPage: String, CaseIterable {
    case collect = "收集", briefs = "简报", settings = "设置"
    var symbol: String { switch self { case .collect:return "tray"; case .briefs:return "doc.text"; case .settings:return "gearshape" } }
}

@main
struct WeChatPortApp: App {
    init() { UpdateController.runHelperIfNeeded() }
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @AppStorage("showMenuBar") private var showMenuBar = false
    var body: some Scene {
        Window("WeChatPort", id: "main") {
            ProductView().frame(minWidth: 680, minHeight: 500)
        }.defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(after:.appInfo) {
                Button("检查更新…") { UpdateController.shared.show(check:true) }
                Button("版本升级…") { UpdateController.shared.show() }
            }
        }
        MenuBarExtra("WeChatPort",systemImage:"tray",isInserted:$showMenuBar) { MenuBarControls() }
    }
}

struct ProductView: View {
    @ObservedObject private var inbox = InboxModel.shared
    @StateObject private var workspace = WorkspaceModel()
    @StateObject private var archive = ArchiveModel()
    @StateObject private var model = ModelSettings()
    @StateObject private var brief = BriefModel()
    @State private var confirmArchive = false
    @State private var picked = RecordSelection()
    @State private var selecting = false
    @State private var deleting = Set<String>()
    @State private var showDelete = false
    @State private var showTrash = false
    @State private var undoArchived = Set<String>()
    @State private var undoPending = Set<String>()
    @State private var groupID = "new"
    @State private var groupName = ""
    @State private var collectionID = "new"
    @AppStorage("processingPaused") private var processingPaused = false
    @State private var page: ProductPage = .collect
    @State private var selected: String?
    @State private var query = ""
    @State private var stateFilter = "all"
    @State private var timeFilter = "all"
    @Environment(\.colorScheme) private var colorScheme
    @State private var editingTemplate = "focus"
    @State private var settingsTab = "通用"
    @State private var showBatchReview = false
    @State private var conversationInput: [ParsedMessage] = []
    @State private var conversationType = "focus"
    @State private var loadedName = ""
    @State private var collectingDraft: ShareCollection?
    @State private var pendingRequest: GenerationRequest?
    @AppStorage("pinnedConversationNames") private var pinnedJSON = "[]"
    private var pins: Set<String> { Set((try? JSONDecoder().decode([String].self,from:Data(pinnedJSON.utf8))) ?? []) }
    private var names: [String] {
        ConversationOrder.names(batches:archive.batches,pins:pins).filter { name in
            let batches = conversationBatches(name)
            return RecordSearch.matches(query,text:[name]+batches.map(\.filenames),imported:batches.flatMap{[$0.receivedAt,$0.displayDate]},messages:archive.conversationTimes[name] ?? MessageSpan())
        }
    }
    private func conversationBatches(_ name: String) -> [ArchivedBatch] { archive.batches.filter { ShareIntake.normalized($0.groupName) == name } }
    private var pending: [PendingBatch] { inbox.batches.filter { item in
        guard !archive.batches.contains(where:{$0.id == item.id}), !archive.trashedBatchIDs.contains(item.id) else { return false }
        if let container = sharedContainer(), let metadata = try? ShareIntake.read(batchID:item.id,container:container) {
            if metadata.collectionID != nil && (try? metadata.isCommitted(container:container)) != true { return false }
            if let bound = metadata.workspaceID, bound != workspace.store?.info.id { return false }
        }
        return RecordSearch.matches(query,text:item.originalNames+["待补充信息"],imported:[item.receivedAt,item.displayDate],messages:MessageSpan())
    } }
    private func togglePin(_ name: String) {
        var value = pins; if value.contains(name) { value.remove(name) } else { value.insert(name) }
        if let data = try? JSONEncoder().encode(value.sorted()), let text = String(data:data,encoding:.utf8) { pinnedJSON = text }
    }
    private func sharedContainer() -> URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey:"WeChatPortAppGroup") as? String else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:group)
    }
    private func publishShareOptions(name: String = "") {
        guard let container = sharedContainer() else { return }
        let catalog = ShareCatalog(types:brief.templates.map { ShareChoice(id:$0.id,name:$0.name) },suggestedName:name,suggestedType:conversationType,expiresAt:name.isEmpty ? nil : Date().addingTimeInterval(600),workspaceID:workspace.store?.info.id)
        do { try ShareIntake.write(catalog,to:ShareCatalog.url(container)) } catch { archive.error = "暂时无法更新分享选项。" }
    }
    private func refreshConversation() {
        loadedName = ""; conversationInput = []
        guard let name = selected, names.contains(name) else { return }
        Task {
            do {
                let messages = try await archive.conversationMessages(name:name)
                guard selected == name else { return }
                conversationInput = messages
                if let id = archive.groups.first(where:{ShareIntake.normalized($0.name) == name})?.id {
                    let preference = try await archive.preference(groupID:id)
                    guard selected == name else { return }; conversationType = preference.templateID
                }
                loadedName = name
            } catch { brief.error = error.localizedDescription }
        }
    }
    private var green: Color { colorScheme == .dark ? Color(red:0.51,green:0.83,blue:0.63) : Color(red:0.08,green:0.49,blue:0.27) }
    private func timeMatches(_ raw: String) -> Bool {
        guard timeFilter != "all" else { return true }
        guard let date = ISO8601DateFormatter().date(from:raw) else { return false }
        if timeFilter == "today" { return Calendar.current.isDateInToday(date) }
        return date >= Calendar.current.date(byAdding:.day,value:-7,to:Date())!
    }
    private func matches(_ batch: PendingBatch) -> Bool {
        let saved = archive.batches.first(where:{$0.id == batch.id})
        if stateFilter == "pending" && saved != nil { return false }
        if stateFilter == "archived" && saved == nil { return false }
        if stateFilter == "parsed" && saved?.parsed != true { return false }
        return timeMatches(batch.receivedAt) && (query.isEmpty || batch.id.localizedCaseInsensitiveContains(query) || batch.originalNames.contains(where:{$0.localizedCaseInsensitiveContains(query)}) || (saved?.groupName.localizedCaseInsensitiveContains(query) ?? false))
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: productIcon()).resizable().frame(width: 36, height: 36).padding(.bottom, 10)
                ForEach(ProductPage.allCases, id: \.self) { item in
                    Button { page = item } label: {
                        VStack(spacing: 6) {
                            Image(systemName:item.symbol).font(.system(size:22,weight:page == item ? .semibold : .regular))
                            Text(item.rawValue).font(.system(size:11,weight:page == item ? .medium : .regular))
                        }.foregroundStyle(page == item ? green : Color.secondary)
                            .frame(width: 50, height: 54)
                            .background(page == item ? green.opacity(0.14) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).help(item.rawValue).accessibilityLabel(item.rawValue)
                }
                Spacer()
            }.padding(.vertical, 18).frame(width: 68).background(Color(nsColor: .windowBackgroundColor))
            Divider()
            Group {
                switch page {
                case .collect: collection
                case .briefs: BriefPane(archive:archive,brief:brief,model:model,directory:workspace.briefURL) { message in
                    archive.openSource(id:message.id)
                }
                case .settings: settings
                }
            }
        }.tint(Color.gray).buttonStyle(.bordered).controlSize(.regular)
        .onAppear { archive.open(workspace.store) }
        .onChange(of:archive.busy) { _, busy in
            if !busy { if !brief.busy { Task { await brief.load(archive); publishShareOptions() } }; if !processingPaused { archive.receiveConfirmed(inbox.batches) } }
        }
        .onChange(of:selected) { _, _ in refreshConversation() }
        .onChange(of:query) { _, _ in picked.ids = [] }
        .onReceive(inbox.$batches) { value in
            if let container = sharedContainer() { collectingDraft = try? ShareCollection.active(container:container) }
            if !processingPaused { archive.receiveConfirmed(value) }
        }
        .onChange(of:archive.batches.map { $0.id + $0.state + $0.groupName }) { _, _ in refreshConversation(); archive.refreshTimings() }
        .onChange(of:processingPaused) { _, paused in if !paused { archive.receiveConfirmed(inbox.batches) } }
        .onChange(of:brief.templates) { _, _ in publishShareOptions() }
        .onChange(of: workspace.store?.root.path) { _, _ in selected = nil; brief.records = []; brief.selected = nil; archive.open(workspace.store) }
        .sheet(item:$pendingRequest) { request in
            VStack(alignment:.leading,spacing:18) {
                Label("生成简报",systemImage:"sparkles").font(.title2.bold())
                Text(request.groupName).font(.headline)
                Text("\(request.messages.count) 条消息 · \(Set(request.messages.map(\.batchID)).count) 批次")
                Text("将把这些消息的昵称、时间和正文发送至 DeepSeek，预计 \(request.requestCount) 次请求，API 可能计费。").foregroundStyle(.secondary)
                if !request.warnings.isEmpty { Text(request.warnings.joined(separator:"\n")).foregroundStyle(.orange) }
                HStack {
                    Button("取消") { pendingRequest = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("确认生成",systemImage:"sparkles") {
                        pendingRequest = nil; page = .briefs
                        Task { await brief.create(groupID:request.groupID,groupName:request.groupName,messages:request.messages,template:request.prompt,model:request.model,archive:archive,warnings:request.warnings,timezone:request.timezone) }
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(28).frame(width:480)
        }
        .alert("删除选中的 \(deleting.count) 项记录？",isPresented:$showDelete) {
            Button("取消",role:.cancel) { }
            Button("删除记录",role:.destructive) { deleteInbox() }
        } message: { Text(deleting.sorted().prefix(5).map { id in
                id.hasPrefix("g:") ? String(id.dropFirst(2)) : (inbox.batches.first{$0.id == String(id.dropFirst(2))}?.originalNames.first ?? "聊天记录")
            }.joined(separator:"\n") + "\n\n可在“已删除”中恢复。聊天原件和已生成简报保留。") }
        .sheet(isPresented:$showTrash) { inboxTrash }
        .sheet(isPresented:$showBatchReview,onDismiss:{ refreshConversation() }) {
            VStack(alignment:.leading,spacing:18) {
                HStack { Text("批次核对").font(.title2.bold()); Spacer(); Button("完成") { showBatchReview = false } }
                if archive.loadingMessages { ProgressView("正在读取批次…") }
                Text("输入项 \(archive.counts.0) · 确认重复 \(archive.counts.1) · 新增 \(archive.counts.2) · 疑似 \(archive.counts.3)").font(.callout)
                if archive.unparsedFiles > 0 { Text("\(archive.unparsedFiles) 个文本文件未解析，缺失消息数量未知。").foregroundStyle(.orange) }
                ScrollView {
                    VStack(alignment:.leading,spacing:18) {
                        ForEach(archive.parseWarnings,id:\.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        ForEach(archive.reviews) { review in
                            VStack(alignment:.leading,spacing:10) {
                                Text("本批次：" + review.message.sender + " · " + review.message.timeRaw).fontWeight(.medium)
                                Text(review.message.text).textSelection(.enabled)
                                Text("已有记录：" + review.candidate.sender + " · " + review.candidate.timeRaw).fontWeight(.medium)
                                Text(review.candidate.text).textSelection(.enabled)
                                HStack {
                                    if review.reviewed {
                                        Label(review.merged ? "已合并" : "已保留",systemImage:"checkmark.circle")
                                        Button("撤销",systemImage:"arrow.uturn.backward") { archive.decide(review,decision:"undo") }
                                    } else {
                                        Button("保留两条",systemImage:"doc.on.doc") { archive.decide(review,decision:"keep") }
                                        Button("合并重复",systemImage:"arrow.triangle.merge") { archive.decide(review,decision:"merge") }
                                    }
                                }
                            }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(Color(nsColor:.controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:8))
                        }
                        ForEach(archive.messages) { message in
                            VStack(alignment:.leading,spacing:7) {
                                HStack { Text(message.sender).fontWeight(.medium); Text(message.timeRaw).foregroundStyle(.secondary) }
                                Text(message.text).textSelection(.enabled)
                            }
                        }
                    }
                }
            }.padding(26).frame(width:650,height:520)
        }
        .sheet(isPresented: $confirmArchive) { archiveConfirmation }
        .sheet(item:$archive.focusedSource) { message in
            VStack(alignment:.leading,spacing:18) {
                HStack { Text(message.sender.isEmpty ? "原始文本" : message.sender).font(.title2.bold()); Spacer(); Button("完成") { archive.focusedSource = nil } }
                Text(message.timeRaw.isEmpty ? "时间未知" : message.timeRaw).foregroundStyle(.secondary)
                ScrollView { Text(message.text).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
                Text(message.entry + " · 序号 \(message.ordinal) · 批次 " + message.batchID.prefix(8)).font(.caption).foregroundStyle(.secondary)
                if let batch = archive.batches.first(where:{$0.id == message.batchID}) { Button("显示原文件",systemImage:"folder") { NSWorkspace.shared.open(URL(fileURLWithPath:batch.path)) } }
            }.padding(28).frame(width:620,height:440)
        }
    }
    private var collection: some View {
        GeometryReader { geo in
            HStack(spacing:0) {
                if geo.size.width >= 850 || selected == nil {
                    VStack(alignment:.leading,spacing:12) {
                        HStack {
                            Text("收集箱").font(.title2.bold()); Spacer()
                            Button { inbox.importFiles() } label: { Image(systemName:"square.and.arrow.down").frame(width:18,height:18) }.help("导入文件…").accessibilityLabel("导入文件…")
                            Menu {
                                Button(selecting ? "完成多选" : "多选",systemImage:"checkmark.circle") { selecting.toggle(); if !selecting { picked.ids = [] } }
                                Button("已删除",systemImage:"trash") { showTrash = true }
                                if !undoArchived.isEmpty || !undoPending.isEmpty { Button("撤销删除",systemImage:"arrow.uturn.backward") { undoInboxDelete() } }
                            } label: { Image(systemName:"ellipsis").frame(width:18,height:18) }.menuStyle(.borderlessButton).fixedSize().help("收集箱管理").accessibilityLabel("收集箱管理")
                        }
                        TextField("搜索群名、导入或消息时间",text:$query).textFieldStyle(.roundedBorder)
                        if workspace.store == nil { Button("选择工作空间…",systemImage:"folder") { workspace.chooseWorkspace() } }
                        ScrollView {
                            LazyVStack(alignment:.leading,spacing:0) {
                                if let draft = collectingDraft, draft.workspaceID == nil || draft.workspaceID == workspace.store?.info.id {
                                    VStack(alignment:.leading,spacing:8) {
                                        Label("收集中 · " + draft.name,systemImage:"tray.and.arrow.down")
                                        Text("已暂存 \(draft.batchIDs.count) 批 · 尚未加入收集箱").font(.caption).foregroundStyle(.secondary)
                                        Text("自行分享下一批可继续追加，也可完成现有批次。").font(.caption).foregroundStyle(.secondary)
                                        Button("完成本次收集") {
                                            guard let container = sharedContainer() else { return }
                                            do {
                                                _ = try ShareCollection.update(id:draft.id,batchID:nil,name:draft.name,templateID:draft.templateID,workspaceID:draft.workspaceID,complete:true,container:container)
                                                collectingDraft = nil; InboxSignal.post(); archive.receiveConfirmed(inbox.batches)
                                            } catch { archive.error = "暂存收集未完成，原件保留，请重试。" }
                                        }
                                    }.padding(12).background(Color.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius:8))
                                }
                                ForEach(names,id:\.self) { name in
                                    HStack(spacing:12) {
                                        if selecting { Image(systemName:picked.ids.contains("g:"+name) ? "checkmark.circle.fill" : "circle").foregroundStyle(.secondary) }
                                        Image(systemName:"bubble.left.and.bubble.right").font(.system(size:17)).foregroundStyle(.secondary).frame(width:24)
                                        VStack(alignment:.leading,spacing:4) {
                                            Text(name).font(.system(size:13,weight:.semibold)).lineLimit(1)
                                            if let latest = conversationBatches(name).first { Text("导入 " + shortReceiptDate(latest.receivedAt) + " · \(conversationBatches(name).count) 批").font(.caption).foregroundStyle(.secondary) }
                                            Text("消息 " + (archive.conversationTimes[name]?.listDisplay ?? "时间未知")).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                        Spacer(minLength:0)
                                        Button { togglePin(name) } label: { Image(systemName:pins.contains(name) ? "pin.fill" : "pin").font(.system(size:12)).foregroundStyle(pins.contains(name) ? green : Color.secondary).frame(width:24,height:28) }.buttonStyle(.plain).help(pins.contains(name) ? "取消置顶" : "置顶").accessibilityLabel(pins.contains(name) ? "取消置顶 " + name : "置顶 " + name)
                                    }.padding(.horizontal,10).padding(.vertical,10).frame(maxWidth:.infinity,alignment:.leading)
                                    .background((picked.ids.contains("g:"+name) || (!selecting && picked.ids.isEmpty && selected == name)) ? Color.primary.opacity(0.09) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius:8)).contentShape(Rectangle())
                                    .onTapGesture { chooseInbox("g:"+name,detail:name) }
                                    .accessibilityElement(children:.contain).accessibilityLabel(name).accessibilityAddTraits(.isButton)
                                    .accessibilityValue(picked.ids.contains("g:"+name) ? "已选中" : "未选中")
                                    .overlay(alignment:.bottom) { Divider().opacity(0.45).padding(.leading,44).padding(.trailing,10) }
                                    .contextMenu {
                                        Button(pins.contains(name) ? "取消置顶" : "置顶",systemImage:pins.contains(name) ? "pin.slash" : "pin") { togglePin(name) }
                                        Button("多选",systemImage:"checkmark.circle") { selecting = true; picked.ids.insert("g:"+name) }
                                        Button(deleteLabel("g:"+name),systemImage:"trash",role:.destructive) { requestInboxDelete("g:"+name) }.disabled(archive.busy || brief.busy)
                                    }
                                }
                                if !pending.isEmpty {
                                    Text("待补充信息").font(.caption).foregroundStyle(.secondary).padding(.top,14).padding(.horizontal,12)
                                    ForEach(pending) { batch in
                                        HStack(alignment:.top,spacing:10) {
                                            if selecting { Image(systemName:picked.ids.contains("p:"+batch.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(.secondary) }
                                            Image(systemName:"doc.zipper").foregroundStyle(green)
                                            VStack(alignment:.leading,spacing:5) {
                                                Text(batch.originalNames.first ?? "聊天记录").lineLimit(2).frame(maxWidth:.infinity,alignment:.leading)
                                                Text("导入 " + shortReceiptDate(batch.receivedAt)).font(.caption).foregroundStyle(.secondary)
                                                Text("消息 尚未解析").font(.caption).foregroundStyle(.secondary)
                                            }
                                        }.padding(.horizontal,12).padding(.vertical,13).frame(maxWidth:.infinity,alignment:.leading)
                                        .background((picked.ids.contains("p:"+batch.id) || (!selecting && picked.ids.isEmpty && selected == batch.id)) ? Color.primary.opacity(0.09) : Color.clear)
                                        .clipShape(RoundedRectangle(cornerRadius:8)).contentShape(Rectangle())
                                        .onTapGesture { chooseInbox("p:"+batch.id,detail:batch.id) }
                                        .accessibilityElement(children:.combine).accessibilityAddTraits(.isButton)
                                        .accessibilityValue(picked.ids.contains("p:"+batch.id) ? "已选中" : "未选中")
                                        .contextMenu {
                                            Button("多选",systemImage:"checkmark.circle") { selecting = true; picked.ids.insert("p:"+batch.id) }
                                            Button(deleteLabel("p:"+batch.id),systemImage:"trash",role:.destructive) { requestInboxDelete("p:"+batch.id) }.disabled(archive.busy || brief.busy)
                                        }
                                    }
                                }
                            }
                        }
                        if selecting || picked.ids.count > 1 {
                            HStack {
                                Text("已选 \(picked.ids.count) 项").foregroundStyle(.secondary)
                                Spacer()
                                Button("全选") { picked.ids = Set(inboxOrder) }
                                Button("删除",systemImage:"trash",role:.destructive) { deleting = picked.ids; showDelete = true }.disabled(picked.ids.isEmpty || archive.busy || brief.busy)
                            }
                        }
                    }.padding(14).frame(width:geo.size.width >= 850 ? 304 : nil)
                    Divider()
                }
                if geo.size.width >= 850 || selected != nil {
                    VStack(alignment:.leading,spacing:0) {
                        if let name = selected, names.contains(name) {
                            VStack(alignment:.leading,spacing:12) {
                                HStack {
                                    if geo.size.width < 850 { Button("返回",systemImage:"chevron.left") { selected = nil } }
                                    Text(name).font(.title2.bold()).lineLimit(1); Spacer()
                                    Button { togglePin(name) } label: {
                                        Image(systemName:pins.contains(name) ? "pin.fill" : "pin").font(.system(size:13)).frame(width:28,height:28)
                                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                                    .help(pins.contains(name) ? "取消置顶" : "置顶").accessibilityLabel(pins.contains(name) ? "取消置顶" : "置顶")
                                }
                                ViewThatFits(in:.horizontal) {
                                    HStack(spacing:12) {
                                        collectionTypePicker
                                        Spacer(minLength:8)
                                        collectionActions(name)
                                    }
                                    VStack(alignment:.leading,spacing:10) {
                                        collectionTypePicker
                                        HStack { Spacer(); collectionActions(name) }
                                    }
                                }
                                Text("\(loadedName == name ? conversationInput.count : 0) 条消息 · \(Set(conversationBatches(name).map { $0.collectionID ?? $0.id }).count) 次收集 · \(conversationBatches(name).count) 批次" + (loadedName == name && VideoCoverage.count(conversationInput) > 0 ? " · \(VideoCoverage.count(conversationInput)) 条视频已忽略" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                                DisclosureGroup("本次与历史收集") {
                                    let batches = conversationBatches(name)
                                    ForEach(Array(Set(batches.map { $0.collectionID ?? $0.id })).sorted(),id:\.self) { id in
                                        let members = batches.filter { ($0.collectionID ?? $0.id) == id }
                                        VStack(alignment:.leading,spacing:4) {
                                            Text("收集 " + id.prefix(8) + " · \(members.count) 批").font(.callout)
                                            ForEach(members) { batch in Text(batch.filenames + " · " + shortReceiptDate(batch.receivedAt)).font(.caption).foregroundStyle(.secondary) }
                                        }.frame(maxWidth:.infinity,alignment:.leading)
                                    }
                                }
                                if loadedName == name, !TransactionCoverage.previewNotice(conversationInput).isEmpty {
                                    Label(TransactionCoverage.previewNotice(conversationInput),systemImage:"exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                                }
                                if !model.verified.contains(model.selected) { Button("设置 DeepSeek",systemImage:"key") { settingsTab = "模型"; page = .settings } }
                            }.padding(20)
                            Divider()
                            ScrollView {
                                LazyVStack(alignment:.leading,spacing:0) {
                                    ForEach(loadedName == name ? conversationInput : []) { message in
                                        VStack(alignment:.leading,spacing:6) {
                                            HStack { Text(message.sender.isEmpty ? "发送人未知" : message.sender).fontWeight(.semibold); Text(message.timeRaw.isEmpty ? "时间未知" : message.timeRaw).font(.caption).foregroundStyle(.secondary); Spacer() }
                                            Text(message.text).textSelection(.enabled)
                                        }.padding(.vertical,12).frame(maxWidth:.infinity,alignment:.leading).overlay(alignment:.bottom) { Divider().opacity(0.4) }
                                        .contextMenu { Button("查看来源",systemImage:"doc.text.magnifyingglass") { archive.openSource(id:message.id) } }
                                    }
                                    DisclosureGroup("批次") {
                                        ForEach(conversationBatches(name)) { batch in
                                            HStack {
                                                Label(batch.displayDate,systemImage:"doc.zipper"); Spacer()
                                                if !batch.parsed { Button("重试处理",systemImage:"arrow.clockwise") { archive.parse(batchID:batch.id) }.disabled(archive.busy) }
                                                else if batch.state == "review_required" { Text("部分内容未解析").foregroundStyle(.orange) }
                                                Button("核对",systemImage:"checkmark.bubble") { archive.loadMessages(batchID:batch.id); showBatchReview = true }
                                                Button("原文件",systemImage:"folder") { NSWorkspace.shared.open(URL(fileURLWithPath:batch.path)) }
                                            }.padding(.vertical,5)
                                        }
                                    }
                                }.padding(.horizontal,20).padding(.vertical,4)
                            }
                        } else if let id = selected, let batch = pending.first(where:{$0.id == id}) {
                            VStack(alignment:.leading,spacing:20) {
                                Text("补充收集信息").font(.title.bold())
                                Text(batch.originalNames.joined(separator:"\n")).foregroundStyle(.secondary)
                                Button("填写名称和简报类型",systemImage:"pencil") { groupName = ""; groupID = "new"; collectionID = "new"; confirmArchive = true }.buttonStyle(.borderedProminent)
                            }.padding(32)
                            Spacer()
                        } else {
                            VStack(spacing:20) {
                                Image(systemName:"tray.and.arrow.down").font(.system(size:44,weight:.light)).foregroundStyle(green)
                                Text(workspace.store == nil ? "选择工作空间，开始收集" : "从微信分享聊天记录").font(.title2.bold())
                                if workspace.store == nil { Button("选择工作空间…",systemImage:"folder") { workspace.chooseWorkspace() }.buttonStyle(.borderedProminent) }
                                else { Text("其他应用 → 选择电脑中的应用 → WeChatPort").foregroundStyle(.secondary) }
                            }.frame(maxWidth:.infinity,maxHeight:.infinity)
                        }
                        if archive.busy { ProgressView("正在整理聊天记录…").padding() }
                        if !archive.notice.isEmpty { Text(archive.notice).font(.callout).foregroundStyle(.secondary).padding(.horizontal,26).padding(.bottom,12) }
                        if !archive.error.isEmpty { Text(archive.error).foregroundStyle(.red).padding() }
                        if !inbox.warning.isEmpty { DisclosureGroup("接收提示") { Text(inbox.warning).foregroundStyle(.orange) }.padding() }
                    }.frame(maxWidth:.infinity,maxHeight:.infinity)
                }
            }
        }
    }
    private var collectionTypePicker: some View {
        Picker("简报类型",selection:$conversationType) {
            ForEach(brief.templates) { Text($0.name).tag($0.id) }
        }.frame(width:230)
    }
    private func collectionActions(_ name: String) -> some View {
        HStack(spacing:8) {
            Button("添加批次",systemImage:"plus") {
                publishShareOptions(name:name)
                archive.notice = "请在微信中手动分享下一批，弹窗会预填此名称和简报类型。"
            }
            Button("生成简报",systemImage:"sparkles") { prepareBrief(name) }
                .buttonStyle(.borderedProminent).tint(Color(red:0.08,green:0.49,blue:0.27))
                .disabled(loadedName != name || conversationInput.isEmpty || brief.busy || archive.busy || !model.verified.contains(model.selected))
        }.controlSize(.regular).font(.system(size:12,weight:.medium)).fixedSize()
    }
    private func shortReceiptDate(_ raw: String) -> String {
        let formatter = MessageSpan.formatter(TimeZone.current.identifier)
        guard let date = MessageSpan.parse(raw,formatter:formatter) else { return "时间未知" }
        formatter.dateFormat = "yyyy-MM-dd H:mm"; return formatter.string(from:date)
    }
    private var inboxOrder: [String] { names.map { "g:"+$0 } + pending.map { "p:"+$0.id } }
    private func chooseInbox(_ id: String,detail: String) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        picked.choose(id,ordered:inboxOrder,toggle:selecting || flags.contains(.command),range:flags.contains(.shift))
        if picked.ids.count == 1 { selected = detail }
    }
    private func deleteLabel(_ id: String) -> String { picked.ids.contains(id) && picked.ids.count > 1 ? "删除选中的 \(picked.ids.count) 项…" : "删除…" }
    private func requestInboxDelete(_ id: String) { deleting = picked.ids.contains(id) ? picked.ids : [id]; showDelete = true }
    private func deleteInbox() {
        let names = Set(deleting.filter{$0.hasPrefix("g:")}.map{String($0.dropFirst(2))})
        let archived = Set(archive.batches.filter { names.contains(ShareIntake.normalized($0.groupName)) }.map(\.id))
        let receipts = Set(deleting.filter{$0.hasPrefix("p:")}.map{String($0.dropFirst(2))})
        Task {
            do {
                if !archived.isEmpty { try await archive.changeTrash(ids:archived,kind:"batch",deleted:true) }
                do { if !receipts.isEmpty { try inbox.changeTrash(receipts,deleted:true) } }
                catch { if !archived.isEmpty { try await archive.changeTrash(ids:archived,kind:"batch",deleted:false) }; throw error }
                undoArchived = archived; undoPending = receipts; picked.ids = []; selected = nil; selecting = false
            } catch { archive.error = "删除未完成：" + error.localizedDescription }
        }
    }
    private func undoInboxDelete() {
        Task {
            do {
                if !undoArchived.isEmpty { try await archive.changeTrash(ids:undoArchived,kind:"batch",deleted:false) }
                if !undoPending.isEmpty { try inbox.changeTrash(undoPending,deleted:false) }
                undoArchived = []; undoPending = []
            } catch { archive.error = "恢复未完成：" + error.localizedDescription }
        }
    }
    private var inboxTrash: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { Text("已删除的收集记录").font(.title2.bold()); Spacer(); Button("完成") { showTrash = false } }
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    ForEach(Array(Set(archive.deletedBatches.map { ShareIntake.normalized($0.groupName) })).sorted(),id:\.self) { name in
                        HStack { Label(name,systemImage:"bubble.left.and.bubble.right"); Spacer(); Button("恢复") {
                            let ids = Set(archive.deletedBatches.filter { ShareIntake.normalized($0.groupName) == name }.map(\.id))
                            Task { do { try await archive.changeTrash(ids:ids,kind:"batch",deleted:false) } catch { archive.error = error.localizedDescription } }
                        }.disabled(archive.busy) }
                    }
                    ForEach(inbox.deletedBatches) { batch in
                        HStack { Label(batch.originalNames.first ?? "聊天记录",systemImage:"doc.zipper"); Spacer(); Button("恢复") { do { try inbox.changeTrash([batch.id],deleted:false) } catch { archive.error = error.localizedDescription } } }
                    }
                    if archive.deletedBatches.isEmpty && inbox.deletedBatches.isEmpty { Text("没有已删除的记录").foregroundStyle(.secondary) }
                }
            }
        }.padding(26).frame(width:540,height:400)
    }
    private func prepareBrief(_ name: String) {
        guard let group = archive.groups.first(where:{ShareIntake.normalized($0.name) == name}), let template = brief.templates.first(where:{$0.id == conversationType}) else { return }
        let batches = conversationBatches(name)
        var warnings: [String] = []
        if batches.contains(where:{!$0.parsed}) { warnings.append("有批次处理未完成，尚未进入本次简报。") }
        if batches.contains(where:{$0.state == "review_required"}) { warnings.append("部分文本未解析，缺失消息数量未知；原文件保留。") }
        Task {
            do {
                var preference = try await archive.preference(groupID:group.id); preference.templateID = conversationType
                try await archive.savePreference(groupID:group.id,name:name,preference:preference)
                let content = template.body + (preference.aliases.isEmpty ? "" : "\n本人别名："+preference.aliases) + (preference.focus.isEmpty ? "" : "\n关注点："+preference.focus)
                pendingRequest = try GenerationRequest(groupID:group.id,groupName:name,messages:conversationInput,prompt:content,model:model.selected,warnings:warnings)
            } catch { brief.error = error.localizedDescription }
        }
    }
    private var settings: some View {
        HStack(alignment:.top,spacing:0) {
            VStack(alignment:.leading,spacing:10) {
                Text("设置").font(.title2.bold()).padding(.bottom,16)
                ForEach(["通用","工作空间","模型","简报类型","群与联系人","记录与状态","隐私与关于"],id:\.self) { tab in
                    Button { settingsTab = tab } label: {
                        Label(tab,systemImage:["通用":"slider.horizontal.3","工作空间":"folder","模型":"cpu","简报类型":"doc.text","群与联系人":"person.2","记录与状态":"list.bullet.rectangle","隐私与关于":"hand.raised"][tab]!).frame(maxWidth:.infinity,alignment:.leading).padding(10).background(settingsTab == tab ? green.opacity(0.14) : Color.clear).clipShape(RoundedRectangle(cornerRadius:8))
                    }.buttonStyle(.plain)
                }
                Spacer()
            }.padding(20).frame(width:190)
            Divider()
            ScrollView {
            VStack(alignment:.leading,spacing:24) {
                Text(settingsTab).font(.title.bold())
                if settingsTab == "通用" { BehaviorSettings() }
                if settingsTab == "工作空间" {
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(workspace.store?.root.path ?? "尚未选择工作空间").textSelection(.enabled)
                        HStack {
                            Button(workspace.store == nil ? "选择工作空间…" : "切换工作空间…") { workspace.chooseWorkspace() }.disabled(brief.busy || archive.busy)
                            Button("检查",systemImage:"arrow.clockwise") { workspace.retry() }
                            if let root = workspace.store?.root { Button("打开",systemImage:"folder") { NSWorkspace.shared.open(root) } }
                        }
                        Divider()
                        Text("默认简报目录").font(.headline)
                        Text(workspace.briefURL?.path ?? "工作空间选择后可设置").textSelection(.enabled)
                        Button("更改目录…",systemImage:"folder.badge.gearshape") { workspace.chooseBriefDirectory() }.disabled(workspace.store == nil)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                if !workspace.error.isEmpty { Text(workspace.error).foregroundStyle(.red) }
                if !workspace.notice.isEmpty { Text(workspace.notice).foregroundStyle(.secondary) }
                }
                if settingsTab == "模型" { GroupBox("DeepSeek") {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("预置型号", selection: $model.selected) {
                            ForEach(ModelChoice.catalog) { choice in Text(choice.name + (model.verified.contains(choice.id) ? " · 本机已验证" : " · 待验证")).tag(choice.id) }
                        }
                        SecureField(model.hasKey ? "输入新 Key 以替换已保存凭据" : "填写 DeepSeek API Key", text: $model.keyInput).textFieldStyle(.roundedBorder)
                        HStack {
                            Button("安全保存 Key") { model.save() }.disabled(model.keyInput.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || model.busy)
                            Button(model.busy ? "验证中…" : "验证连接（少量费用）") { model.validate() }.disabled(!model.hasKey || model.busy || Date() < model.retryAt)
                            Button("删除已保存 Key") { model.remove() }.disabled(!model.hasKey || model.busy)
                        }
                        Text(model.status).foregroundStyle(.secondary)
                        Text("Key 存于本机钥匙串。验证仅发送测试文本。").font(.caption).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }.disabled(brief.busy)
                }
                if settingsTab == "简报类型" { GroupBox {
                    VStack(alignment:.leading,spacing:14) {
                        Picker("模板",selection:$editingTemplate) { ForEach(brief.templates) { Text($0.name).tag($0.id) } }
                        if let index = brief.templates.firstIndex(where:{$0.id == editingTemplate}) {
                            TextField("模板名称",text:$brief.templates[index].name).textFieldStyle(.roundedBorder)
                            TemplateBodyEditor(text:$brief.templates[index].body).frame(minHeight:160).overlay(RoundedRectangle(cornerRadius:5).stroke(Color.secondary.opacity(0.25)))
                        }
                        HStack {
                            Button("新建",systemImage:"plus") {
                                let item = PromptTemplate(id:UUID().uuidString.lowercased(),name:"新模板",body:"")
                                brief.templates.append(item); editingTemplate = item.id
                            }
                            Button("复制",systemImage:"doc.on.doc") {
                                if let original = brief.templates.first(where:{$0.id == editingTemplate}) {
                                    let item = PromptTemplate(id:UUID().uuidString.lowercased(),name:original.name+" 副本",body:original.body)
                                    brief.templates.append(item); editingTemplate = item.id
                                }
                            }
                            Button("删除",systemImage:"trash") {
                                brief.templates.removeAll{$0.id == editingTemplate}; editingTemplate = brief.templates.first?.id ?? ""
                                Task { await brief.saveTemplates(archive) }
                            }.disabled(brief.templates.count <= 1)
                            Spacer()
                            Button("保存",systemImage:"checkmark") { Task { await brief.saveTemplates(archive) } }.buttonStyle(.borderedProminent)
                        }
                    }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
                }.disabled(workspace.store == nil || brief.busy)
                }
                if settingsTab == "群与联系人" { GroupPreferencesPanel(archive:archive,brief:brief).disabled(workspace.store == nil || brief.busy) }
                if settingsTab == "记录与状态" { ProductStatusPanel(workspace:workspace,archive:archive,inbox:inbox,model:model) }
                if settingsTab == "隐私与关于" {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("仅处理主动分享的文件",systemImage:"hand.raised")
                        Label("原件长期保留",systemImage:"archivebox")
                        UpdateSettings().frame(minHeight:220)
                        DisclosureGroup("许可与诊断") {
                            Text("仅限个人非商业使用，未经书面许可不得商用或再分发。")
                            if let license = Bundle.main.url(forResource:"LICENSE",withExtension:"txt") { Button("查看使用许可") { NSWorkspace.shared.open(license) } }
                            Text("界面图标：Apple SF Symbols，仅用于本Mac应用界面；品牌图形为本项目独立设计。系统组件：SwiftUI/AppKit、SQLite、zlib。")
                            Text("系统接收 \(inbox.batches.count) 批；微信图标已确认，完整冷/热验收待补；Windows待实机。")
                        }.font(.caption).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                }
            }.padding(24).frame(maxWidth:860,alignment:.leading)
            }.frame(maxWidth:.infinity,alignment:.leading)
        }
    }
    private var archiveConfirmation: some View {
        VStack(alignment:.leading,spacing:20) {
            Label("收集聊天记录",systemImage:"tray.and.arrow.down").font(.title2.bold())
            TextField("群或联系人名称",text:$groupName).textFieldStyle(.roundedBorder)
            Picker("简报类型",selection:$conversationType) { ForEach(brief.templates) { Text($0.name).tag($0.id) } }
            HStack {
                Button("取消") { confirmArchive = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("完成") {
                    guard let selected, let container = sharedContainer() else { return }
                    do {
                        try ShareIntake(version:1,batchID:selected,name:ShareIntake.normalized(groupName),templateID:conversationType,workspaceID:workspace.store?.info.id).save(container:container)
                        confirmArchive = false; archive.retryConfirmed(batchID:selected,pending:inbox.batches)
                    } catch { archive.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(ShareIntake.normalized(groupName).isEmpty)
            }
        }.padding(28).frame(width:460)
    }
    private func panel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(detail).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// Compact list metadata keeps exact dates available while avoiding a repeated day.
extension MessageSpan {
    var listDisplay: String {
        guard let first = dates.first, let last = dates.last else { return "时间未知" }
        let format = Self.formatter(timezone)
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = format.timeZone
        format.dateFormat = "yyyy-MM-dd HH:mm"
        let start = format.string(from:first)
        format.dateFormat = calendar.isDate(first,inSameDayAs:last) ? "HH:mm" : "yyyy-MM-dd HH:mm"
        return start + " – " + format.string(from:last) + (hasUnknown ? " · 部分未知" : "")
    }
}


// Use a native text-container inset so glyphs and the caret remain inside the
// scrollable document, including its first line and after scrolling to the top.
struct TemplateBodyEditor: NSViewRepresentable {
    @Binding var text: String
    final class Coordinator: NSObject, NSTextViewDelegate {
        var owner: TemplateBodyEditor
        init(_ owner: TemplateBodyEditor) { self.owner = owner }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            owner.text = view.string
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = NSTextView(frame:scroll.contentView.bounds)
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.font = NSFont.systemFont(ofSize:13)
        view.textColor = .labelColor
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width:8,height:10)
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width:scroll.contentSize.width,height:CGFloat.greatestFiniteMagnitude)
        view.setAccessibilityLabel("模板正文")
        view.delegate = context.coordinator
        view.string = text
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView,context: Context) {
        context.coordinator.owner = self
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        view.setSelectedRange(NSRange(location:0,length:0))
        view.scrollRangeToVisible(NSRange(location:0,length:0))
        view.undoManager?.removeAllActions()
    }
}


struct ProductStatusPanel: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var archive: ArchiveModel
    @ObservedObject var inbox: InboxModel
    @ObservedObject var model: ModelSettings
    @State private var query = ""
    @State private var filter = "all"
    @State private var directoryStatus = "尚未检查"
    @State private var sharingStatus = "尚未检查系统分享注册"
    @State private var checkedAt: Date?
    private var all: [ArchivedBatch] { (archive.batches + archive.deletedBatches).sorted { $0.receivedAt > $1.receivedAt } }
    private var visible: [ArchivedBatch] {
        all.filter { item in
            let deleted = archive.trashedBatchIDs.contains(item.id)
            let statusMatch = filter == "all" || (filter == "deleted" ? deleted : !deleted && (filter == "parsed" ? item.parsed : !item.parsed || item.failedFiles > 0))
            return statusMatch && RecordSearch.matches(query,text:[item.groupName,item.filenames],imported:[item.receivedAt,item.displayDate],messages:MessageSpan())
        }
    }
    private func state(_ item: ArchivedBatch) -> String {
        if archive.trashedBatchIDs.contains(item.id) { return "已删除记录 · 原件保留" }
        switch item.state {
        case "collected": return "已解析"
        case "review_required": return "部分解析 · 请核对缺失"
        case "parse_failed": return "解析失败 · 可重试"
        default: return "已接收 · 待解析"
        }
    }
    private func check() {
        do {
            if let store = workspace.store {
                for url in [store.root,store.raw,store.metadata] { try WorkspaceStore.checkWritable(url) }
                if let url = workspace.briefURL { try WorkspaceStore.checkWritable(url) }
                directoryStatus = "工作空间、索引与简报目录可写"
            } else { directoryStatus = "未选择工作空间" }
        } catch { directoryStatus = error.localizedDescription }
        // Ask the system to enumerate services for our own synthetic file only.
        let probe = FileManager.default.temporaryDirectory.appendingPathComponent("wechatport-registration-"+UUID().uuidString+".txt")
        do {
            try Data("WeChatPort registration check".utf8).write(to:probe,options:.withoutOverwriting)
            defer { try? FileManager.default.removeItem(at:probe) }
            let found = NSSharingService.sharingServices(forItems:[probe]).contains { $0.title == "收集到 WeChatPort" }
            sharingStatus = found ? "系统已枚举分享入口" : "系统尚未枚举入口，请在系统分享扩展设置中检查"
        } catch { sharingStatus = "未能检查系统分享注册，请重试" }
        checkedAt = Date(); inbox.refresh()
    }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            GroupBox("分项状态") {
                VStack(alignment:.leading,spacing:10) {
                    Text("目录："+directoryStatus)
                    Text("系统分享："+sharingStatus)
                    Text("微信实际分享：完整冷启动、已启动及连续分享仍待验；系统枚举不代表微信验证。")
                    Text("模型："+(model.hasKey ? (model.verified.contains(model.selected) ? "所选型号有本机验证记录；当前网络状态未探测" : "Key已保存，所选型号待验证") : "未配置；仍可收集和查看原文"))
                    Text("接收队列：\(inbox.batches.count) 个完整批次（含其他工作空间）")
                    if !inbox.warning.isEmpty { Text(inbox.warning).foregroundStyle(.orange) }
                    if !archive.error.isEmpty { Text("处理状态："+archive.error).foregroundStyle(.orange) }
                    Button("重新检查目录与分享注册",systemImage:"arrow.clockwise",action:check).disabled(archive.busy)
                    if let date = checkedAt { Text("本次检查："+date.formatted()).font(.caption).foregroundStyle(.secondary) }
                }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
            }
            GroupBox("批次历史") {
                VStack(alignment:.leading,spacing:12) {
                    Text("共 \(all.count) 批 · \(all.reduce(0){$0+$1.rawCount}) 条已解析原始记录 · 附件登记 \(ByteCountFormatter.string(fromByteCount:all.reduce(Int64(0)){$0+$1.byteCount},countStyle:.file))")
                    Text("含已删除记录；条数包含重复来源，不等于去重后消息数。简报生成与保存状态请在简报页查看。").font(.caption).foregroundStyle(.secondary)
                    TextField("搜索群名、文件名或导入时间",text:$query).textFieldStyle(.roundedBorder)
                    Picker("状态",selection:$filter) { Text("全部").tag("all"); Text("已解析").tag("parsed"); Text("待处理/异常").tag("pending"); Text("已删除").tag("deleted") }
                    ForEach(visible) { item in
                        VStack(alignment:.leading,spacing:6) {
                            Text(item.groupName).font(.headline)
                            Text(item.filenames).lineLimit(3).textSelection(.enabled)
                            Text(item.displayDate + " · " + state(item)).font(.caption).foregroundStyle(.secondary)
                            Text("\(item.rawCount) 条 · \(item.failedFiles) 个未解析文件 · " + ByteCountFormatter.string(fromByteCount:item.byteCount,countStyle:.file)).font(.caption)
                            HStack {
                                Button("定位原件",systemImage:"folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:item.path)]) }
                                if !item.parsed && !archive.trashedBatchIDs.contains(item.id) { Button("重试解析",systemImage:"arrow.clockwise") { archive.parse(batchID:item.id) }.disabled(archive.busy) }
                            }
                        }.padding(.vertical,8)
                        Divider()
                    }
                    if visible.isEmpty { Text("没有匹配的批次").foregroundStyle(.secondary) }
                    Text("接收队列跨工作空间保留；当前可补充的批次请在收集页查看。校验未通过的原件保留并显示警告。")
                }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
            }
            GroupBox("存储与保留") {
                Text("聊天解析在内存完成，不产生持久解压缓存；无需清理。原ZIP、暂存批次、工作空间索引、生成恢复数据和已保存Markdown均保留，不作为缓存删除。记录删除可从已删除列表恢复。").padding(12).frame(maxWidth:.infinity,alignment:.leading)
            }
        }
    }
}
