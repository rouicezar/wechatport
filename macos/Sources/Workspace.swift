import Foundation
import AppKit
import Darwin

struct WorkspaceInfo: Codable {
    let schemaVersion: Int
    let id: String
    let timezone: String
}
enum WorkspaceFailure: LocalizedError {
    case directory(String), conflict, unavailable, version
    var errorDescription: String? {
        switch self {
        case .directory(let name): return "\(name)不是可访问的普通文件夹，请重新选择。"
        case .conflict: return "已有同名文件或链接，未覆盖任何内容。请选择其他工作空间。"
        case .unavailable: return "目录不可写或授权已失效。原文件保留，请重新选择或重试。"
        case .version: return "工作空间版本无法识别，未修改原配置。"
        }
    }
}

// No scanning or migration: touches only the directory explicitly selected by the user.
// Immutable paths/info; the transferable writer reservation is protected by reservationLock.
final class WorkspaceStore: @unchecked Sendable {
    let root: URL
    let raw: URL
    let briefs: URL
    let metadata: URL
    let info: WorkspaceInfo
    private let reservationLock = NSLock()
    private var reservedFD: Int32 = -1
    func reserveWriter() throws {
        reservationLock.lock(); defer { reservationLock.unlock() }
        let fd = Darwin.open(metadata.appendingPathComponent("workspace.lock").path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw WorkspaceFailure.unavailable }
        guard flock(fd,LOCK_EX|LOCK_NB) == 0 else { close(fd); throw ArchiveFailure.busy }
        reservedFD = fd
    }
    func takeReservedWriter() -> Int32? {
        reservationLock.lock(); defer { reservationLock.unlock() }
        guard reservedFD >= 0 else { return nil }; let fd = reservedFD; reservedFD = -1; return fd
    }
    deinit { if reservedFD >= 0 { flock(reservedFD,LOCK_UN); close(reservedFD) } }
    static func requireDirectory(_ url: URL) throws {
        var s = stat()
        guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT == S_IFDIR else { throw WorkspaceFailure.directory(url.lastPathComponent) }
    }
    static func checkWritable(_ url: URL) throws {
        try requireDirectory(url)
        let probe = url.appendingPathComponent(".wechatport-probe-" + UUID().uuidString)
        let fd = Darwin.open(probe.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw WorkspaceFailure.unavailable }
        defer { close(fd); unlink(probe.path) }
        let bytes = Array("WeChatPort write probe".utf8)
        guard bytes.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == bytes.count,
              fsync(fd) == 0, try Data(contentsOf: probe) == Data(bytes) else { throw WorkspaceFailure.unavailable }
    }
    init(root: URL) throws {
        self.root = root.standardizedFileURL
        raw = self.root.appendingPathComponent("聊天记录", isDirectory: true)
        briefs = self.root.appendingPathComponent("简报", isDirectory: true)
        metadata = raw.appendingPathComponent(".app", isDirectory: true)
        try Self.checkWritable(self.root)
        let fm = FileManager.default
        // Preflight both names before creating either directory.
        for url in [raw, briefs, metadata] {
            var s = stat()
            if lstat(url.path, &s) == 0 && s.st_mode & S_IFMT != S_IFDIR { throw WorkspaceFailure.conflict }
        }
        for url in [raw, briefs, metadata] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Self.checkWritable(url)
        }
        let config = metadata.appendingPathComponent("workspace.json")
        var s = stat()
        if lstat(config.path, &s) == 0 {
            guard s.st_mode & S_IFMT == S_IFREG else { throw WorkspaceFailure.conflict }
            info = try JSONDecoder().decode(WorkspaceInfo.self, from: Data(contentsOf: config))
            guard info.schemaVersion == 1, UUID(uuidString: info.id) != nil else { throw WorkspaceFailure.version }
        } else {
            info = WorkspaceInfo(schemaVersion: 1, id: UUID().uuidString.lowercased(), timezone: TimeZone.current.identifier)
            let bytes = try JSONEncoder().encode(info)
            let fd = Darwin.open(config.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw WorkspaceFailure.conflict }
            defer { close(fd) }
            guard bytes.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == bytes.count,
                  fsync(fd) == 0 else { throw WorkspaceFailure.unavailable }
        }
    }
}

final class WorkspaceModel: ObservableObject {
    @Published var store: WorkspaceStore?
    @Published var error = ""
    @Published var notice = ""
    @Published var briefURL: URL?
    private var scopedRoot: URL?
    private var scopedBrief: URL?
    init() { restore() }
    private func bookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    private func resolve(_ key: String) throws -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        _ = url.startAccessingSecurityScopedResource()
        if stale { UserDefaults.standard.set(try bookmark(url), forKey: key) }
        return url
    }
    func restore() {
        do {
            guard let url = try resolve("workspaceBookmark") else { return }
            do { store = try WorkspaceStore(root: url); scopedRoot = url }
            catch { url.stopAccessingSecurityScopedResource(); throw error }
            briefURL = store?.briefs
            if let other = try resolve("briefBookmark-" + store!.info.id) {
                do { try WorkspaceStore.checkWritable(other); scopedBrief = other; briefURL = other }
                catch { other.stopAccessingSecurityScopedResource(); throw error }
            }
        } catch { self.error = error.localizedDescription }
    }
    func chooseWorkspace() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "选择本机工作空间，将建立或复用“聊天记录”和“简报”。不会搬迁旧空间，也不会自动解析待处理批次。"
        panel.prompt = "使用此工作空间"
        guard panel.runModal() == .OK, let url = panel.url else { notice = "已取消，原工作空间保持不变。"; return }
        _ = url.startAccessingSecurityScopedResource()
        do {
            let next = try WorkspaceStore(root: url)
            if next.root != store?.root { try next.reserveWriter() }
            let data = try bookmark(url)
            scopedRoot?.stopAccessingSecurityScopedResource(); scopedBrief?.stopAccessingSecurityScopedResource()
            scopedRoot = url; scopedBrief = nil; store = next; briefURL = next.briefs
            UserDefaults.standard.set(data, forKey: "workspaceBookmark")
            error = ""; notice = "工作空间可写；两个业务目录已就绪。待处理批次尚未迁入。"
            // Restore only this workspace's separately granted brief destination.
            if let other = try resolve("briefBookmark-" + next.info.id) {
                do { try WorkspaceStore.checkWritable(other); scopedBrief = other; briefURL = other }
                catch { other.stopAccessingSecurityScopedResource(); throw error }
            }
        } catch { if scopedRoot != url { url.stopAccessingSecurityScopedResource() }; self.error = error.localizedDescription }
    }
    func chooseBriefDirectory() {
        guard let store else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "设为默认简报目录"
        panel.message = "只影响以后保存，不移动或覆盖旧简报。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = url.startAccessingSecurityScopedResource()
        do {
            try WorkspaceStore.checkWritable(url)
            let data = try bookmark(url)
            scopedBrief?.stopAccessingSecurityScopedResource(); scopedBrief = url; briefURL = url
            UserDefaults.standard.set(data, forKey: "briefBookmark-" + store.info.id)
            error = ""; notice = "默认简报目录已更新，旧文件保持原位。"
        } catch { url.stopAccessingSecurityScopedResource(); self.error = error.localizedDescription }
    }
    func retry() {
        do {
            guard let store else { restore(); return }
            try WorkspaceStore.checkWritable(store.root)
            try WorkspaceStore.checkWritable(store.raw)
            if let briefURL { try WorkspaceStore.checkWritable(briefURL) }
            error = ""; notice = "目录访问与写入检查通过。"
        } catch { self.error = error.localizedDescription }
    }
}
