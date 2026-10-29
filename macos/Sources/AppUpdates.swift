import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Darwin

enum UpdateFailure: LocalizedError {
    case invalid, signature, version, channel, permission, process, size
    var errorDescription: String? {
        switch self {
        case .invalid: return "安装包不是有效的 WeChatPort Mac 应用。"
        case .signature: return "安装包签名或开发者身份不匹配，未安装。"
        case .version: return "此安装包不是更新版本，当前版本保持不变。"
        case .channel: return "更新渠道暂不可用，无法确认是否有新版。可稍后重试或选择本地安装包。"
        case .permission: return "无法写入应用所在目录，请重新选择该目录；当前应用保持不变。"
        case .process: return "安装未完成，原版本已保留。"
        case .size: return "安装包超过当前更新通道的大小限制，未安装。"
        }
    }
}
struct AppVersion: Codable, Comparable {
    let version: String
    let build: Int
    var label: String? = nil
    var display: String { (label ?? version) + "（" + String(build) + "）" }
    static var current: Self { Self(version:Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "未知",build:Int(Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "0") ?? 0,label:Bundle.main.object(forInfoDictionaryKey:"WeChatPortReleaseLabel") as? String) }
    static func < (a:Self,b:Self) -> Bool {
        let x = a.version.split(separator:".").map{Int($0) ?? 0}, y = b.version.split(separator:".").map{Int($0) ?? 0}
        for i in 0..<max(x.count,y.count) { let l = i<x.count ? x[i] : 0, r = i<y.count ? y[i] : 0; if l != r { return l<r } }
        return a.build < b.build
    }
    static func == (a:Self,b:Self) -> Bool { !(a<b) && !(b<a) }
}
enum UpdateInstaller {
    static let identifier = "com.rouice.wechatport"
    static let team = "YL56SXR8GN"
    @discardableResult static func command(_ executable: String,_ args: [String]) throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath:executable); process.arguments = args
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateFailure.signature }; return data
    }
    static func inspect(_ app: URL) throws -> AppVersion {
        var info = stat(); guard lstat(app.path,&info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw UpdateFailure.invalid }
        guard let plist = try PropertyListSerialization.propertyList(from:Data(contentsOf:app.appendingPathComponent("Contents/Info.plist")),format:nil) as? [String:Any],
              plist["CFBundleIdentifier"] as? String == identifier,
              plist["WeChatPortAppGroup"] as? String == team+".com.rouice.wechatport",
              let version = plist["CFBundleShortVersionString"] as? String, version.range(of:#"^\d+\.\d+\.\d+$"#,options:.regularExpression) != nil,
              let buildText = plist["CFBundleVersion"] as? String, let build = Int(buildText), build > 0 else { throw UpdateFailure.invalid }
        let requirement = "anchor apple generic and identifier \""+identifier+"\" and certificate leaf[subject.OU] = \""+team+"\""
        try command("/usr/bin/codesign",["--verify","--deep","--strict","-R="+requirement,app.path])
        let ext = app.appendingPathComponent("Contents/PlugIns/WeChatPortShare.appex")
        try command("/usr/bin/codesign",["--verify","--strict","-R="+requirement.replacingOccurrences(of:identifier+"\"",with:identifier+".share\""),ext.path])
        return AppVersion(version:version,build:build,label:plist["WeChatPortReleaseLabel"] as? String)
    }
    // All replacements are on the destination volume. The old signed bundle is retained.
    static func install(source: URL,destination: URL,expected: AppVersion, afterBackup: (() throws -> Void)? = nil) throws -> URL {
        let fm = FileManager.default
        guard destination.lastPathComponent == "WeChatPort.app", source.standardizedFileURL != destination.standardizedFileURL,
              try inspect(destination) == expected, try inspect(source) > expected else { throw UpdateFailure.version }
        let folder = destination.deletingLastPathComponent()
        let staged = folder.appendingPathComponent(".WeChatPort-new-"+UUID().uuidString+".app")
        let backup = folder.appendingPathComponent(".WeChatPort-previous-"+UUID().uuidString+".app")
        try fm.copyItem(at:source,to:staged)
        do { _ = try inspect(staged) } catch { try? fm.removeItem(at:staged); throw error }
        func swap(_ a: URL,_ b: URL) throws {
            guard renameatx_np(AT_FDCWD,a.path,AT_FDCWD,b.path,UInt32(RENAME_SWAP)) == 0 else { throw UpdateFailure.process }
        }
        do {
            // Atomic exchange keeps a launchable app at destination even if the helper is interrupted.
            try swap(staged,destination)
            do {
                try fm.moveItem(at:staged,to:backup)
                try afterBackup?(); _ = try inspect(destination)
                let fd = Darwin.open(folder.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard fd >= 0 else { throw UpdateFailure.process }; defer { close(fd) }
                guard fsync(fd) == 0 else { throw UpdateFailure.process }
            } catch {
                let old = fm.fileExists(atPath:backup.path) ? backup : staged
                try swap(old,destination)
                try? fm.removeItem(at:old)
                throw error
            }
        } catch { try? fm.removeItem(at:staged); throw UpdateFailure.process }
        return backup
    }
}
private struct UpdateJob: Codable { let parent: Int32; let source: String; let directoryBookmark: Data; let expected: AppVersion }
private struct ReleaseAsset: Decodable { let name: String; let browser_download_url: URL; let size: Int }
private struct AppRelease: Decodable { let tag_name: String; let draft: Bool; let prerelease: Bool; let assets: [ReleaseAsset] }
private final class UpdateNetwork: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession,task: URLSessionTask,willPerformHTTPRedirection response: HTTPURLResponse,newRequest request: URLRequest,completionHandler: @escaping (URLRequest?)->Void) {
        guard let url = request.url, Self.allowed(url) else { completionHandler(nil); return }; completionHandler(request)
    }
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil else { return false }
        if url.host == "api.github.com" { return url.path == "/repos/rouicezar/wechatport/releases/latest" }
        if url.host == "github.com" { return url.path.hasPrefix("/rouicezar/wechatport/releases/download/") }
        return url.host == "release-assets.githubusercontent.com"
    }
}
@MainActor final class UpdateController: ObservableObject {
    static let shared = UpdateController()
    @Published var status = ""
    @Published var busy = false
    @Published private var asset: ReleaseAsset?
    @Published var candidate: URL?
    @Published var candidateVersion: AppVersion?
    private var window: NSWindow?
    var canDownload: Bool { asset != nil && candidate == nil }
    func show(check: Bool = false) {
        if window == nil {
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:540,height:330),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title = "WeChatPort 更新"; window.contentView = NSHostingView(rootView:UpdateSettings()); window.isReleasedWhenClosed = false; self.window = window
        }
        window?.center(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        if check { Task { await self.check() } }
    }
    func check() async {
        guard !busy else { return }; busy = true; defer { busy = false }; asset = nil; status = "正在检查更新…"
        do {
            let session = URLSession(configuration:.ephemeral,delegate:UpdateNetwork(),delegateQueue:nil); defer { session.invalidateAndCancel() }
            var request = URLRequest(url:URL(string:"https://api.github.com/repos/rouicezar/wechatport/releases/latest")!,timeoutInterval:20)
            request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept"); request.setValue("WeChatPort",forHTTPHeaderField:"User-Agent")
            let (data,response) = try await session.data(for:request)
            guard let http = response as? HTTPURLResponse else { throw UpdateFailure.channel }
            if http.statusCode == 404 { status = "更新渠道尚无可访问的发布版本，暂时无法检查更新。"; return }
            guard http.statusCode == 200, data.count <= 1024*1024 else { throw UpdateFailure.channel }
            let release = try JSONDecoder().decode(AppRelease.self,from:data)
            guard !release.draft, !release.prerelease else { throw UpdateFailure.channel }
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "x86_64"
            #endif
            asset = release.assets.first { ["WeChatPort-macos-"+architecture+".zip","WeChatPort-macos-universal.zip"].contains($0.name) && $0.size > 0 && $0.size <= BoundedZIP.maxArchive && UpdateNetwork.allowed($0.browser_download_url) }
            status = asset == nil ? "发布版本 "+release.tag_name+" 尚未提供适配此 Mac 的安装包。" : "找到发布版本 "+release.tag_name+"；下载后将校验签名和完整版本号。"
        } catch { status = UpdateFailure.channel.localizedDescription }
    }
    private func directory() throws -> URL {
        let base = try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("WeChatPort/Updates/"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true); return base
    }
    func download() async {
        guard !busy, let asset else { return }; busy = true; defer { busy = false }; status = "正在下载并验证安装包…"
        do {
            let session = URLSession(configuration:.ephemeral,delegate:UpdateNetwork(),delegateQueue:nil); defer { session.invalidateAndCancel() }
            let (temporary,response) = try await session.download(for:URLRequest(url:asset.browser_download_url,timeoutInterval:120))
            defer { try? FileManager.default.removeItem(at:temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateFailure.channel }
            let size = try temporary.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= BoundedZIP.maxArchive, size == asset.size else { throw UpdateFailure.size }
            let base = try directory()
            let bytes = try Data(contentsOf:temporary)
            // Validate all names/CRC/bounds before asking the system extractor to write anything.
            let entries = try BoundedZIP.entries(bytes)
            guard !entries.isEmpty, entries.allSatisfy({$0.0.hasPrefix("WeChatPort.app/")}) else { throw UpdateFailure.invalid }
            try UpdateInstaller.command("/usr/bin/ditto",["-x","-k",temporary.path,base.path])
            try prepare(base.appendingPathComponent("WeChatPort.app"))
        } catch { status = error.localizedDescription }
    }
    func chooseLocal() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.prompt = "选择新版"; panel.message = "选择由同一开发者签名的 WeChatPort.app。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        candidate = nil; candidateVersion = nil
        busy = true; status = "正在验证本地安装包…"
        Task {
            defer { busy = false }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { let target = try directory().appendingPathComponent("WeChatPort.app"); try FileManager.default.copyItem(at:url,to:target); try prepare(target) }
            catch { status = error.localizedDescription }
        }
    }
    private func prepare(_ app: URL) throws {
        let version = try UpdateInstaller.inspect(app)
        guard version > AppVersion.current else { throw UpdateFailure.version }
        candidate = app; candidateVersion = version; status = "签名验证通过，可升级到 "+version.display+"。"
    }
    func install() {
        guard !busy, let candidate, let candidateVersion else { return }
        let alert = NSAlert(); alert.messageText = "升级到 "+candidateVersion.display+"？"; alert.informativeText = "安装后重新启动 WeChatPort。旧版本保留备份，聊天记录、简报和 Key 保持原位。"
        alert.addButton(withTitle:"安装并重新启动"); alert.addButton(withTitle:"取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let current = Bundle.main.bundleURL.standardizedFileURL
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.directoryURL = current.deletingLastPathComponent()
            panel.message = "授权安装到当前应用所在文件夹："+current.deletingLastPathComponent().path; panel.prompt = "授权安装"
            guard panel.runModal() == .OK, let folder = panel.url, folder.standardizedFileURL == current.deletingLastPathComponent() else { return }
            let accessed = folder.startAccessingSecurityScopedResource(); defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
            let bookmark = try folder.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil)
            let manifest = try directory().appendingPathComponent("job.json")
            try ShareIntake.write(UpdateJob(parent:getpid(),source:candidate.path,directoryBookmark:bookmark,expected:AppVersion.current),to:manifest)
            guard let executable = Bundle.main.executableURL else { throw UpdateFailure.invalid }
            let helper = Process(); helper.executableURL = executable; helper.arguments = ["--apply-update",manifest.path]
            helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice; try helper.run()
            NSApp.terminate(nil)
        } catch { status = error.localizedDescription }
    }
    static func runHelperIfNeeded() {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--apply-update" else { return }
        do {
            let job = try JSONDecoder().decode(UpdateJob.self,from:ShareIntake.boundedData(URL(fileURLWithPath:CommandLine.arguments[2])))
            guard job.parent > 1, job.parent != getpid() else { throw UpdateFailure.invalid }
            var stale = false
            let folder = try URL(resolvingBookmarkData:job.directoryBookmark,options:.withSecurityScope,relativeTo:nil,bookmarkDataIsStale:&stale)
            guard !stale, folder.startAccessingSecurityScopedResource() else { throw UpdateFailure.permission }
            defer { folder.stopAccessingSecurityScopedResource() }
            let deadline = Date().addingTimeInterval(30)
            while kill(job.parent,0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval:0.1) }
            guard kill(job.parent,0) != 0 else { throw UpdateFailure.process }
            let app = folder.appendingPathComponent("WeChatPort.app")
            let backup = try UpdateInstaller.install(source:URL(fileURLWithPath:job.source),destination:app,expected:job.expected)
            UserDefaults.standard.set("升级完成；旧版本备份："+backup.path,forKey:"updateResult")
            NSWorkspace.shared.open(app); exit(0)
        } catch {
            UserDefaults.standard.set("升级未完成："+error.localizedDescription,forKey:"updateResult")
            NSWorkspace.shared.open(Bundle.main.bundleURL); exit(1)
        }
    }
}
struct UpdateSettings: View {
    @ObservedObject private var update = UpdateController.shared
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Label("WeChatPort",systemImage:"app.badge").font(.title2.bold())
            Text("版本 "+AppVersion.current.display).foregroundStyle(.secondary)
            HStack {
                Button("检查更新",systemImage:"arrow.clockwise") { Task { await update.check() } }
                if update.canDownload { Button("下载新版",systemImage:"arrow.down.circle") { Task { await update.download() } } }
                Button("安装本地新版…",systemImage:"shippingbox") { update.chooseLocal() }
            }.disabled(update.busy)
            if update.candidate != nil { Button("安装并重新启动",systemImage:"arrow.triangle.2.circlepath") { update.install() }.buttonStyle(.borderedProminent).disabled(update.busy) }
            if update.busy { ProgressView() }
            if !update.status.isEmpty { Text(update.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            if let result = UserDefaults.standard.string(forKey:"updateResult") { Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Spacer(minLength:0)
        }.padding(24).frame(maxWidth:.infinity,alignment:.leading)
    }
}
