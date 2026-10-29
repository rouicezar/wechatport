import SwiftUI

private enum MarkdownBlock {
    case line(String), heading(String,Int), code(String), table([[String]])
}
struct MarkdownReader: View {
    let markdown: String
    var sourceIDs: [String] = []
    var onSource: ((String)->Void)?
    private let sourceIndex: [String:Int]
    init(markdown:String,sourceIDs:[String] = [],onSource:((String)->Void)? = nil) {
        self.markdown = markdown; self.sourceIDs = sourceIDs; self.onSource = onSource
        sourceIndex = sourceIDs.enumerated().reduce(into:[:]) { $0[$1.element] = $1.offset+1 }
    }
    private static let reference = try! NSRegularExpression(pattern:#"\[\[([^\]]+)\]\]"#)
    private var blocks: [MarkdownBlock] {
        let lines = markdown.components(separatedBy:"\n")
        var result: [MarkdownBlock] = [], index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("```") {
                index += 1; var code: [String] = []
                while index < lines.count && !lines[index].hasPrefix("```") { code.append(lines[index]); index += 1 }
                result.append(.code(code.joined(separator:"\n")))
            } else if line.contains("|"), index+1 < lines.count, lines[index+1].contains("---"), lines[index+1].contains("|") {
                var rows: [[String]] = []
                func cells(_ value: String) -> [String] {
                    var parts = value.components(separatedBy:"|")
                    if parts.first?.trimmingCharacters(in:.whitespaces).isEmpty == true { parts.removeFirst() }
                    if parts.last?.trimmingCharacters(in:.whitespaces).isEmpty == true { parts.removeLast() }
                    return parts.map{$0.trimmingCharacters(in:.whitespaces)}
                }
                rows.append(cells(line)); index += 2
                while index < lines.count && lines[index].contains("|") { rows.append(cells(lines[index])); index += 1 }
                result.append(.table(rows)); continue
            } else if line.hasPrefix("#") {
                let level = line.prefix(while:{$0 == "#"}).count
                result.append(.heading(String(line.dropFirst(level)).trimmingCharacters(in:.whitespaces),level))
            } else { result.append(.line(line)) }
            index += 1
        }
        return result
    }
    private func inline(_ line: String) -> AttributedString {
        var value = line
        let original = line as NSString
        for match in Self.reference.matches(in:line,range:NSRange(location:0,length:original.length)).reversed() {
            let id = original.substring(with:match.range(at:1))
            if let number = sourceIndex[id], let range = Range(match.range,in:value) { value.replaceSubrange(range,with:"[\(number)](wechatport-source://"+id+")") }
        }
        return (try? AttributedString(markdown:value,options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            ForEach(Array(blocks.enumerated()),id:\.offset) { _,block in
                switch block {
                case .heading(let title,let level): Text(title).font(level == 1 ? .title.bold() : level == 2 ? .title2.bold() : .headline).padding(.top,level == 1 ? 0 : 12)
                case .code(let text): ScrollView(.horizontal) { Text(text).font(.system(.body,design:.monospaced)).padding(14) }.background(Color(nsColor:.controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:6))
                case .table(let rows):
                    ScrollView(.horizontal) {
                        Grid(alignment:.leading,horizontalSpacing:0,verticalSpacing:0) {
                            ForEach(Array(rows.enumerated()),id:\.offset) { row,cells in
                                GridRow {
                                    ForEach(Array(cells.enumerated()),id:\.offset) { _,cell in
                                        Text(inline(cell)).fontWeight(row == 0 ? .semibold : .regular).padding(10).frame(minWidth:100,maxWidth:260,alignment:.leading)
                                    }
                                }.background(row == 0 ? Color.secondary.opacity(0.10) : Color.clear)
                                Divider().gridCellUnsizedAxes(.horizontal)
                            }
                        }.overlay(RoundedRectangle(cornerRadius:5).stroke(Color.secondary.opacity(0.2)))
                    }
                case .line(let line):
                    if line == "---" { Divider() }
                    else if line.hasPrefix("- ") || line.hasPrefix("* ") { HStack(alignment:.top,spacing:8) { Text("•"); Text(inline(String(line.dropFirst(2)))).frame(maxWidth:.infinity,alignment:.leading) } }
                    else if line.hasPrefix("> ") { Text(inline(String(line.dropFirst(2)))).padding(.leading,12).overlay(alignment:.leading){ Rectangle().fill(Color.secondary.opacity(0.3)).frame(width:3) } }
                    else if !line.isEmpty { Text(inline(line)).lineSpacing(4) }
                }
            }
        }.textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
        .environment(\.openURL,OpenURLAction { url in
            if url.scheme == "wechatport-source", let id = url.host, sourceIDs.contains(id) { onSource?(id); return .handled }
            return ["https","http"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
    }
}
struct BriefPane: View {
    @ObservedObject var archive: ArchiveModel
    @ObservedObject var brief: BriefModel
    @ObservedObject var model: ModelSettings
    let directory: URL?
    let navigateSource: (ParsedMessage)->Void
    @State private var groupID = ""
    @State private var input: [ParsedMessage] = []
    @State private var templateID = "focus"
    @State private var prompt = PromptTemplate.defaults[0].body
    @State private var batchID = "all"
    @State private var from = Calendar.current.startOfDay(for:Date())
    @State private var to = Date()
    @State private var dateFilter = false
    @State private var includeUnknown = false
    @State private var pendingRequest: GenerationRequest?
    @State private var showComposer = false
    @State private var showMarkdown = false
    @State private var search = ""
    @State private var picked = RecordSelection()
    @State private var selecting = false
    @State private var deleting = Set<String>()
    @State private var showDelete = false
    @State private var showTrash = false
    @State private var removed: [BriefRecord] = []
    @State private var undoIDs = Set<String>()
    @AppStorage("pinnedBriefIDs") private var pinnedJSON = "[]"
    @State private var messageTimes: [String:MessageSpan] = [:]
    private var pins: Set<String> { Set((try? JSONDecoder().decode([String].self,from:Data(pinnedJSON.utf8))) ?? []) }
    private var visible: [BriefRecord] {
        brief.records.filter { record in
            RecordSearch.matches(search,text:[record.groupName,record.markdown],imported:imported(record),messages:messageTimes[record.id] ?? MessageSpan())
        }.sorted {
            if pins.contains($0.id) != pins.contains($1.id) { return pins.contains($0.id) }
            return $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
        }
    }
    private func imported(_ record: BriefRecord) -> [String] {
        if let values = record.sourceReceivedAt { return values }
        let ids = Set(record.messages.map(\.batchID))
        return (archive.batches+archive.deletedBatches).filter { ids.contains($0.id) }.map(\.receivedAt)
    }
    private func importDisplay(_ record: BriefRecord) -> String {
        let span = MessageSpan.make(imported(record),timezone:record.timezone ?? TimeZone.current.identifier)
        guard let last = span.dates.last else { return "时间未知" }
        let formatter = MessageSpan.formatter(span.timezone); formatter.dateFormat = "yyyy-MM-dd H:mm"; return formatter.string(from:last)
    }
    private func togglePin(_ id: String) {
        var value = pins; if value.contains(id) { value.remove(id) } else { value.insert(id) }
        if let data = try? JSONEncoder().encode(value.sorted()) { pinnedJSON = String(data:data,encoding:.utf8) ?? "[]" }
    }
    @State private var preference = GroupPreference()
    @State private var loadedGroupID = ""
    private var record: BriefRecord? { brief.records.first { $0.id == brief.selected } }
    private func date(_ message: ParsedMessage) -> Date? {
        guard !message.timeRaw.isEmpty else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.timeZone = .current; formatter.isLenient = false
        for format in ["yyyy年M月d日 HH:mm","yyyy-MM-dd HH:mm:ss","yyyy-MM-dd HH:mm","yyyy/MM/dd HH:mm:ss","yyyy/MM/dd HH:mm","yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format; if let date = formatter.date(from:message.timeRaw) { return date }
        }
        return nil
    }
    private var chosen: [ParsedMessage] {
        input.filter { message in
            guard batchID == "all" || batchID == message.batchID else { return false }
            guard let date = date(message) else { return includeUnknown }
            if !dateFilter { return true }
            let calendar = Calendar.current
            return date >= calendar.startOfDay(for:from) && date < calendar.date(byAdding:.day,value:1,to:calendar.startOfDay(for:to))!
        }
    }
    var body: some View {
        GeometryReader { geo in
            HStack(spacing:0) {
                if geo.size.width >= 850 || (brief.selected == nil && !showComposer) {
                    VStack(alignment:.leading,spacing:14) {
                        HStack { Text("简报").font(.title2.bold()); Spacer()
                            Menu {
                                Button(selecting ? "完成多选" : "多选",systemImage:"checkmark.circle") { selecting.toggle(); if !selecting { picked.ids = [] } }
                                Button("已删除",systemImage:"trash") { showTrash = true }
                                if !undoIDs.isEmpty { Button("撤销删除",systemImage:"arrow.uturn.backward") { restoreBriefs(undoIDs) } }
                            } label: { Image(systemName:"ellipsis").frame(width:18,height:18) }.menuStyle(.borderlessButton).fixedSize().help("简报管理").accessibilityLabel("简报管理")
                        }
                        TextField("搜索群名、内容、导入或消息时间",text:$search).textFieldStyle(.roundedBorder)
                        ScrollView {
                            LazyVStack(alignment:.leading,spacing:0) {
                                ForEach(visible) { record in
                                    HStack(spacing:10) {
                                        if selecting { Image(systemName:picked.ids.contains(record.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(.secondary) }
                                        Image(systemName:"doc.text").font(.system(size:17)).foregroundStyle(.secondary).frame(width:24)
                                        VStack(alignment:.leading,spacing:4) {
                                            Text(record.groupName).font(.system(size:13,weight:.semibold)).lineLimit(1)
                                            Text("导入 " + importDisplay(record) + " · " + (record.state == "draft" ? "未保存" : state(record.state))).font(.caption).foregroundStyle(.secondary)
                                            Text("消息 " + (messageTimes[record.id]?.listDisplay ?? "时间未知")).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                        Spacer(minLength:0)
                                        Button { togglePin(record.id) } label: { Image(systemName:pins.contains(record.id) ? "pin.fill" : "pin").font(.system(size:12)).foregroundStyle(.secondary).frame(width:24,height:28) }.buttonStyle(.plain).help(pins.contains(record.id) ? "取消置顶" : "置顶").accessibilityLabel((pins.contains(record.id) ? "取消置顶简报 " : "置顶简报 ") + record.groupName)
                                    }.padding(.horizontal,10).padding(.vertical,10).frame(maxWidth:.infinity,alignment:.leading)
                                    .background((picked.ids.contains(record.id) || (!selecting && picked.ids.isEmpty && brief.selected == record.id)) ? Color.primary.opacity(0.09) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius:8)).contentShape(Rectangle())
                                    .onTapGesture {
                                        let flags = NSApp.currentEvent?.modifierFlags ?? []
                                        picked.choose(record.id,ordered:visible.map(\.id),toggle:selecting || flags.contains(.command),range:flags.contains(.shift))
                                        if picked.ids.count == 1 { brief.selected = record.id }
                                    }.accessibilityElement(children:.contain).accessibilityAddTraits(.isButton)
                                    .accessibilityValue(picked.ids.contains(record.id) ? "已选中" : "未选中")
                                    .overlay(alignment:.bottom) { Divider().opacity(0.45).padding(.leading,44).padding(.trailing,10) }
                                    .contextMenu {
                                        Button(pins.contains(record.id) ? "取消置顶" : "置顶",systemImage:pins.contains(record.id) ? "pin.slash" : "pin") { togglePin(record.id) }
                                        Button("多选",systemImage:"checkmark.circle") { selecting = true; picked.ids.insert(record.id) }
                                        Button(picked.ids.contains(record.id) && picked.ids.count > 1 ? "删除选中的 \(picked.ids.count) 篇…" : "删除…",systemImage:"trash",role:.destructive) {
                                            deleting = picked.ids.contains(record.id) ? picked.ids : [record.id]; showDelete = true
                                        }.disabled(brief.busy || archive.busy)
                                    }
                                }
                            }
                        }
                        if selecting || picked.ids.count > 1 {
                            HStack {
                                Text("已选 \(picked.ids.count) 篇").foregroundStyle(.secondary); Spacer()
                                Button("全选") { picked.ids = Set(visible.map(\.id)) }
                                Button("删除",systemImage:"trash",role:.destructive) { deleting = picked.ids; showDelete = true }.disabled(picked.ids.isEmpty || brief.busy || archive.busy)
                            }
                        }
                        if brief.records.isEmpty { Text("尚无简报").foregroundStyle(.secondary) }
                    }.padding(14).frame(width:geo.size.width >= 850 ? 304 : nil)
                    Divider()
                }
                if geo.size.width >= 850 || brief.selected != nil || showComposer {
                    ScrollView {
                        VStack(alignment:.leading,spacing:14) {
                            if geo.size.width < 850 { Button("简报",systemImage:"chevron.left") { brief.selected = nil; showComposer = false } }
                            if let record { reader(record) } else { Label("在收集箱选择群或联系人，生成简报",systemImage:"tray").foregroundStyle(.secondary) }
                            if brief.busy { Text(brief.progress).foregroundStyle(.secondary) }
                            if !brief.error.isEmpty { Text(brief.error).foregroundStyle(.red) }
                        }.padding(24).frame(maxWidth:900,alignment:.leading)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }
            }
        }
        .onAppear { showComposer = false }
        .onChange(of:search) { _, _ in picked.ids = [] }
        .task(id:brief.records.map{$0.id+$0.snapshotHash}.joined()) {
            let records = brief.records
            let values = await Task.detached {
                Dictionary(uniqueKeysWithValues:records.map { ($0.id,MessageSpan.make($0.messages.map(\.timeRaw),timezone:$0.timezone ?? TimeZone.current.identifier)) })
            }.value
            guard records.map(\.id) == brief.records.map(\.id) else { return }; messageTimes = values
        }
        .alert("删除选中的 \(deleting.count) 篇简报？",isPresented:$showDelete) {
            Button("取消",role:.cancel) { }
            Button("删除记录",role:.destructive) {
                Task {
                    do {
                        try await archive.changeTrash(ids:deleting,kind:"brief",deleted:true)
                        undoIDs = deleting; picked.ids = []; brief.selected = nil; selecting = false; await brief.load(archive)
                    } catch { brief.error = "删除未完成：" + error.localizedDescription }
                }
            }
        } message: { Text(brief.records.filter { deleting.contains($0.id) }.prefix(5).map { $0.groupName + " · " + $0.displayDate }.joined(separator:"\n") + "\n\n可在“已删除”中恢复。已经保存或另存的 Markdown 文件不会删除。") }
        .sheet(isPresented:$showTrash) {
            VStack(alignment:.leading,spacing:18) {
                HStack { Text("已删除的简报").font(.title2.bold()); Spacer(); Button("完成") { showTrash = false } }
                ScrollView {
                    VStack(alignment:.leading,spacing:14) {
                        ForEach(removed) { record in
                            HStack { VStack(alignment:.leading) { Text(record.groupName); Text(record.displayDate).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("恢复") { restoreBriefs([record.id]) }.disabled(archive.busy || brief.busy) }
                        }
                        if removed.isEmpty { Text("没有已删除的简报").foregroundStyle(.secondary) }
                    }
                }
            }.padding(26).frame(width:540,height:400)
            .task { do { removed = try await archive.readRecords(deleted:true) } catch { brief.error = error.localizedDescription } }
        }
        .onChange(of: brief.records.count) { _, count in if count > 0 && brief.selected == nil && groupID.isEmpty { showComposer = false } }
        .onChange(of: brief.selected) { _,value in if value != nil { showComposer = false } }
        .onChange(of: groupID) { _, value in
            loadedGroupID = ""; input = []; batchID = "all"
            Task {
                do {
                    let messages = try await archive.selectedMessages(groupID:value)
                    let settings = try await archive.preference(groupID:value)
                    guard groupID == value else { return }
                    input = messages; preference = settings; loadedGroupID = value
                    if let template = brief.templates.first(where:{$0.id == settings.templateID}) { templateID = template.id; prompt = template.body }
                } catch { brief.error = error.localizedDescription }
            }
        }
        .onChange(of: templateID) { _,value in if let template = brief.templates.first(where:{$0.id == value}) { prompt = template.body } }
        .sheet(item:$pendingRequest) { request in
            VStack(alignment:.leading,spacing:18) {
                Text("确认发送本次范围").font(.title2.bold())
                Text("服务：DeepSeek · " + request.model)
                Text("群：" + request.groupName)
                Text("预计 \(request.requestCount) 次模型请求，失败重试另计。")
                Text("选定 \(request.messages.count) 条 · \(Set(request.messages.map(\.batchID)).count) 批 · 时区 " + request.timezone)
                Text("将发送选定消息的正文、发送人、原始时间、来源定位及本次提示词到 api.deepseek.com。媒体未解析，链接正文未读取；API可能计费。新收到消息不会加入当前快照。")
                    .foregroundStyle(.secondary)
                if !request.warnings.isEmpty { Text(request.warnings.joined(separator:"\n")).foregroundStyle(.orange) }
                HStack {
                    Button("取消") { pendingRequest = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("授权并生成简报") {
                        pendingRequest = nil
                        Task { await brief.create(groupID:request.groupID,groupName:request.groupName,messages:request.messages,template:request.prompt,model:request.model,archive:archive,warnings:request.warnings,timezone:request.timezone) }
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(28).frame(width:540)
        }
    }
    @ViewBuilder private func reader(_ record: BriefRecord) -> some View {
        Text(record.groupName).font(.title.bold())
        Text(state(record.state) + " · " + (ModelChoice.catalog.first(where:{$0.id == record.model})?.name ?? record.model) + " · " + record.displayDate).foregroundStyle(.secondary)
        HStack {
            if brief.busy { Button("取消生成") { brief.cancel() } }
            else if ["failed","cancelled","interrupted","queued"].contains(record.state) {
                Button("继续失败部分（可能计费）") { brief.run(id:record.id,archive:archive) }.disabled(!model.verified.contains(record.model))
            }
            if ["draft","saved"].contains(record.state) {
                Button("重新生成",systemImage:"arrow.clockwise") {
                    do { pendingRequest = try GenerationRequest(groupID:record.groupID,groupName:record.groupName,messages:record.messages,prompt:record.template,model:record.model,warnings:record.coverageWarnings ?? [],timezone:record.timezone ?? TimeZone.current.identifier) }
                    catch { brief.error = error.localizedDescription }
                }.disabled(brief.busy || !model.verified.contains(record.model))
                Button("保存",systemImage:"square.and.arrow.down") { brief.save(id:record.id,directory:directory,choose:false,archive:archive) }
                Button("另存为…",systemImage:"folder") { brief.save(id:record.id,directory:directory,choose:true,archive:archive) }
                Button("复制",systemImage:"doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(record.markdown,forType:.string) }
            }
        }
        if !record.error.isEmpty { Text(record.error).foregroundStyle(.red) }
        let proposed = directory?.appendingPathComponent(MarkdownWriter.filename(record)).path
        if let path = record.savedPath ?? proposed { Label(path,systemImage:"folder").font(.caption).lineLimit(1).truncationMode(.middle).help(path).textSelection(.enabled) }
        if record.savedPath != nil && MarkdownWriter.status(record) != "磁盘文件与保存版本一致" { Text(MarkdownWriter.status(record)).font(.caption).foregroundStyle(.orange) }
        if MarkdownWriter.status(record).contains("外部修改") {
            Button("加载磁盘版本",systemImage:"arrow.down.doc") { brief.reload(id:record.id,archive:archive) }
        }
        if !record.markdown.isEmpty {
            Divider().opacity(0.5)
            Toggle("查看 Markdown 源文",isOn:$showMarkdown).toggleStyle(.checkbox).font(.caption).foregroundStyle(.secondary)
            if showMarkdown { Text(record.markdown).font(.system(.body,design:.monospaced)).textSelection(.enabled) }
            else {
                MarkdownReader(markdown:GenerationRules.readingMarkdown(record),sourceIDs:record.messages.map(\.id)) { id in
                    if let message = record.messages.first(where:{$0.id == id}) { navigateSource(message) }
                }
                DisclosureGroup("覆盖与来源") {
                    Text("\(record.messages.count) 条消息 · \(record.segments.count) 段全部处理 · " + TimeZone.current.identifier).font(.callout)
                    Text("快照 " + record.snapshotHash).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("回到原始消息") {
                VStack(alignment:.leading,spacing:5) {
                    ForEach(record.messages) { message in
                        Button { navigateSource(message) } label: {
                            Text(message.sender + " · " + message.timeRaw + " · " + String(message.text.split(whereSeparator:{$0.isWhitespace}).joined(separator:" ").prefix(45)))
                                .multilineTextAlignment(.leading).frame(maxWidth:.infinity,alignment:.leading)
                        }.buttonStyle(.link).controlSize(.small)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(.top,6)
            }
        }
    }
    private func restoreBriefs(_ ids: Set<String>) {
        Task {
            do {
                try await archive.changeTrash(ids:ids,kind:"brief",deleted:false)
                undoIDs.subtract(ids); await brief.load(archive); removed = try await archive.readRecords(deleted:true)
            } catch { brief.error = "恢复未完成：" + error.localizedDescription }
        }
    }
    private func state(_ value: String) -> String {
        ["draft":"草稿 · 未保存","saved":"已保存","queued":"待生成","generating":"生成中","merging":"汇总中","failed":"生成失败","cancelled":"已取消","interrupted":"上次中断"][value] ?? value
    }
}
