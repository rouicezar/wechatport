import Foundation
import Darwin
import CryptoKit
import AppKit
import UniformTypeIdentifiers

enum MarkdownWriter {
    static func hash(_ data: Data) -> String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
    static func filename(_ name: String) -> String {
        let clean = name.map { "/\\:\n\r\t".contains($0) ? "_" : String($0) }.joined()
        return String(clean.prefix(80)) + "_简报.md"
    }
    static func filename(_ record: BriefRecord) -> String {
        let regex = try! NSRegularExpression(pattern:#"(\d{4})[年/-](\d{1,2})[月/-](\d{1,2})"#)
        let dates = record.messages.compactMap { message -> String? in
            let ns = message.timeRaw as NSString
            guard let match = regex.firstMatch(in:message.timeRaw,range:NSRange(location:0,length:ns.length)),
                  let y = Int(ns.substring(with:match.range(at:1))),let m = Int(ns.substring(with:match.range(at:2))),let d = Int(ns.substring(with:match.range(at:3))) else { return nil }
            return String(format:"%04d-%02d-%02d",y,m,d)
        }.sorted()
        let range = dates.first.map { $0 + "至" + dates.last! } ?? "未定位"
        return filename(record.groupName + "_" + range)
    }
    static func write(_ text: String, to proposed: URL) throws -> URL {
        let parent = proposed.deletingLastPathComponent(); try WorkspaceStore.checkWritable(parent)
        let name = proposed.deletingPathExtension().lastPathComponent
        let temp = parent.appendingPathComponent(".wechatport-"+UUID().uuidString+".partial")
        let bytes = Data(text.utf8)
        let fd = Darwin.open(temp.path,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw WorkspaceFailure.unavailable }
        defer { close(fd); unlink(temp.path) }
        var written = 0
        try bytes.withUnsafeBytes { buffer in
            while written < bytes.count {
                let count = Darwin.write(fd,buffer.baseAddress!.advanced(by:written),bytes.count-written)
                guard count > 0 else { throw WorkspaceFailure.unavailable }; written += count
            }
        }
        guard fsync(fd) == 0, try Data(contentsOf:temp) == bytes else { throw WorkspaceFailure.unavailable }
        for index in 0..<10000 {
            let target = parent.appendingPathComponent(name + (index == 0 ? "" : "_\(index)") + ".md")
            // Same-volume link publishes a complete file without replacing any existing path.
            if link(temp.path,target.path) == 0 {
                let directory = Darwin.open(parent.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
                guard directory >= 0 else { throw WorkspaceFailure.unavailable }; defer { close(directory) }
                guard fsync(directory) == 0, try Data(contentsOf:target) == bytes else { throw WorkspaceFailure.unavailable }
                return target
            }
            guard errno == EEXIST else { throw WorkspaceFailure.unavailable }
        }
        throw WorkspaceFailure.unavailable
    }
    static func status(_ record: BriefRecord) -> String {
        guard let path = record.savedPath, let hash = record.savedHash else { return "未保存到简报目录" }
        guard let bytes = try? Data(contentsOf:URL(fileURLWithPath:path)) else { return "已保存文件失联或授权失效，草稿仍保留" }
        return Self.hash(bytes) == hash ? "磁盘文件与保存版本一致" : "磁盘文件已被外部修改；不会用旧草稿覆盖"
    }
}
