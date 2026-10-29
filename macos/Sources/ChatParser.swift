import Foundation
import CoreFoundation
import zlib

struct ParsedMessage: Codable, Identifiable {
    let id: String
    let batchID: String
    let entry: String
    let ordinal: Int
    let sender: String
    let timeRaw: String
    let precision: String
    let text: String
    let warning: String
    var fingerprint: String { [sender, timeRaw, text.replacingOccurrences(of:"\r\n",with:"\n").trimmingCharacters(in:.newlines).precomposedStringWithCanonicalMapping].joined(separator: "\u{0}") }
}
struct ParseResult { var messages: [ParsedMessage] = []; var warnings: [String] = []; var failed = 0 }
enum ParseFailure: LocalizedError {
    case zip, limit, encoding, format
    var errorDescription: String? {
        switch self {
        case .zip: return "压缩包的结构或校验未通过，原包保留。"
        case .limit: return "文件超过安全解析上限，原包保留；请分批导入。"
        case .encoding: return "文本编码无法识别，原件保留。"
        case .format: return "当前格式尚不能可靠识别消息，原文可查看，未伪造消息条数。"
        }
    }
}

// Reads central directory and inflates bounded entries into memory; never extracts paths to disk.
enum BoundedZIP {
    static let maxArchive = 64 * 1024 * 1024
    static let maxExpanded = 128 * 1024 * 1024
    static func entries(_ data: Data, textOnly: Bool = false) throws -> [(String, Data)] {
        guard data.count <= maxArchive, data.count >= 22 else { throw ParseFailure.limit }
        let bytes = [UInt8](data)
        func u16(_ p: Int) throws -> Int { guard p >= 0, p + 2 <= bytes.count else { throw ParseFailure.zip }; return Int(bytes[p]) | Int(bytes[p+1]) << 8 }
        func u32(_ p: Int) throws -> Int { try u16(p) | u16(p+2) << 16 }
        var end: Int?
        for p in stride(from: bytes.count-22, through: max(0, bytes.count-65557), by: -1) {
            if try u32(p) == 0x06054b50, p + 22 + (try u16(p+20)) == bytes.count { end = p; break }
        }
        guard let end, try u16(end+4) == 0, try u16(end+6) == 0,
              try u16(end+8) == u16(end+10) else { throw ParseFailure.zip }
        let count = try u16(end+10), centralSize = try u32(end+12), central = try u32(end+16)
        guard count <= 2000, central >= 0, central + centralSize == end else { throw ParseFailure.limit }
        var offset = central, total = 0, result: [(String, Data)] = [], names = Set<String>()
        for _ in 0..<count {
            guard try u32(offset) == 0x02014b50 else { throw ParseFailure.zip }
            let flags = try u16(offset+8), method = try u16(offset+10), crc = try u32(offset+16)
            let compressed = try u32(offset+20), expanded = try u32(offset+24)
            let nameLength = try u16(offset+28), extra = try u16(offset+30), comment = try u16(offset+32)
            let attributes = try u32(offset+38), local = try u32(offset+42)
            let nameStart = offset+46
            guard nameStart + nameLength + extra + comment <= end,
                  let name = String(bytes: bytes[nameStart..<nameStart+nameLength], encoding: .utf8),
                  !name.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}), !name.contains("\\"), !name.hasPrefix("/"), !name.contains(":"),
                  !name.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
                  !name.split(separator: "/").contains("."), names.insert(name).inserted,
                  ((attributes >> 16) & 0xf000) != 0xa000,
                  flags & 1 == 0, [0,8].contains(method), compressed != 0xffffffff, expanded != 0xffffffff else { throw ParseFailure.zip }
            let readContent = !textOnly || name.lowercased().hasSuffix(".txt")
            guard (!readContent || expanded <= 32*1024*1024), expanded <= max(1024*1024, compressed*200) else { throw ParseFailure.limit }
            total += expanded; guard total <= maxExpanded else { throw ParseFailure.limit }
            guard try u32(local) == 0x04034b50, try u16(local+6) == flags, try u16(local+8) == method else { throw ParseFailure.zip }
            let localName = try u16(local+26), localExtra = try u16(local+28)
            let payload = local+30+localName+localExtra
            guard local+30+localName <= central, payload + compressed <= central,
                  Array(bytes[local+30..<local+30+localName]) == Array(bytes[nameStart..<nameStart+nameLength]) else { throw ParseFailure.zip }
            if !readContent {
                // Media is inventory only. Validate the container/path/bounds without inflating media bytes.
                if !name.hasSuffix("/") { result.append((name,Data())) }
                offset = nameStart+nameLength+extra+comment; continue
            }
            let input = Array(bytes[payload..<payload+compressed])
            let output: Data
            if method == 0 {
                guard compressed == expanded else { throw ParseFailure.zip }; output = Data(input)
            } else {
                var stream = z_stream()
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw ParseFailure.zip }
                defer { inflateEnd(&stream) }
                var destination = [UInt8](repeating: 0, count: max(expanded,1))
                let status = input.withUnsafeBytes { source in
                    destination.withUnsafeMutableBytes { target in
                        stream.next_in = UnsafeMutablePointer<Bytef>(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                        stream.avail_in = uInt(compressed); stream.next_out = target.bindMemory(to: Bytef.self).baseAddress
                        stream.avail_out = uInt(max(expanded,1)); return inflate(&stream, Z_FINISH)
                    }
                }
                guard status == Z_STREAM_END, stream.total_out == expanded, stream.total_in == compressed else { throw ParseFailure.zip }
                output = Data(destination.prefix(expanded))
            }
            let actualCRC = output.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(output.count)) }
            guard actualCRC == crc else { throw ParseFailure.zip }
            if !name.hasSuffix("/") { result.append((name,output)) }
            offset = nameStart+nameLength+extra+comment
        }
        guard offset == end else { throw ParseFailure.zip }
        return result
    }
}

enum ChatParser {
    static func decode(_ data: Data) throws -> String {
        guard data.count <= 32*1024*1024 else { throw ParseFailure.limit }
        if data.starts(with: [0xff,0xfe]) || data.starts(with: [0xfe,0xff]), let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .utf8) { return s.replacingOccurrences(of: "\u{feff}", with: "") }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { return s }
        throw ParseFailure.encoding
    }
    static func text(_ text: String, batch: String, entry: String) throws -> [ParsedMessage] {
        let normalized = text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n")
        let native = try NSRegularExpression(pattern:#"^·([^\n]+)\n(\d{4}年\d{1,2}月\d{1,2}日 \d{2}:\d{2})\n"#,options:[.anchorsMatchLines])
        let source = normalized as NSString
        let headers = native.matches(in:normalized,range:NSRange(location:0,length:source.length))
        if let first = headers.first, first.range.location == 0 {
            return headers.enumerated().map { index,match in
                let start = match.range.location+match.range.length
                let end = index+1 < headers.count ? headers[index+1].range.location : source.length
                return ParsedMessage(id:UUID().uuidString.lowercased(),batchID:batch,entry:entry,ordinal:index+1,
                    sender:source.substring(with:match.range(at:1)),timeRaw:source.substring(with:match.range(at:2)),precision:"minute",
                    text:source.substring(with:NSRange(location:start,length:end-start)),warning:"来源未含时区；以工作空间时区解释。")
            }
        }
        // Explicit timestamp formats only. Headerless text remains one unlocated item.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        let pattern = #"^\[?(\d{4}[-/]\d{1,2}[-/]\d{1,2}[ T]\d{1,2}:\d{2}(?::\d{2})?)\]?\s+([^\n]+?)(?:\s*[:：]\s*(.*))?$"#
        let expression = try NSRegularExpression(pattern: pattern)
        var output: [ParsedMessage] = []
        var sender = "", time = "", body: [String] = []
        func flush() {
            guard !body.isEmpty || !time.isEmpty else { return }
            let content = body.joined(separator: "\n")
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            output.append(ParsedMessage(id: UUID().uuidString.lowercased(), batchID: batch, entry: entry, ordinal: output.count+1,
                sender: sender, timeRaw: time, precision: time.isEmpty ? "unknown" : (time.split(separator: ":").count == 3 ? "second" : "minute"),
                text: content, warning: time.isEmpty ? "未识别发送人和时间；作为未定位文本保留，不推算原消息条数。" : "来源未含时区，按当前工作空间时区解释；请核对。"))
        }
        for line in lines {
            let ns = line as NSString
            if let match = expression.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                flush(); time = ns.substring(with: match.range(at: 1)); sender = ns.substring(with: match.range(at: 2)); body = []
                if match.range(at: 3).location != NSNotFound { body.append(ns.substring(with: match.range(at: 3))) }
            } else { body.append(line) }
        }
        flush()
        guard !output.isEmpty else { throw ParseFailure.format }
        return output
    }
    static func parse(_ data: Data, filename: String, batch: String) throws -> ParseResult {
        var result = ParseResult()
        if filename.lowercased().hasSuffix(".zip") {
            let files = try BoundedZIP.entries(data,textOnly:true)
            for (name, bytes) in files {
                if name.lowercased().hasSuffix(".txt") {
                    do { result.messages += try text(decode(bytes), batch: batch, entry: name) }
                    catch { result.failed += 1; result.warnings.append("一个文本附件无法解析，原件保留。") }
                } else { result.warnings.append("附件未解析：" + name + "；未读取媒体或链接正文。") }
            }
        } else { result.messages = try text(decode(data), batch: batch, entry: filename) }
        let videos = VideoCoverage.count(result.messages)
        if videos > 0 { result.warnings.append("聊天记录中包含 \(videos) 条视频，已忽略视频内容。") }
        guard !result.messages.isEmpty else { throw ParseFailure.format }
        return result
    }
}

// Count exported video-message markers, not distinct files: the same file may be sent repeatedly.
enum VideoCoverage {
    static func count(_ messages: [ParsedMessage]) -> Int {
        let regex = try! NSRegularExpression(pattern:#"^\s*\[(?:视频|视频消息)\]\s+[^\r\n]+\.(?:mp4|mov|m4v|webm|mkv|avi|3gp)\s*$"#,options:[.caseInsensitive])
        return messages.reduce(0) { total,message in
            let body = message.text.trimmingCharacters(in:.whitespacesAndNewlines)
            return total + (regex.firstMatch(in:body,range:NSRange(body.startIndex...,in:body)) == nil ? 0 : 1)
        }
    }
}

// An export marker is evidence of a related message, not a unique settled transaction.
enum TransactionCoverage {
    static func transfers(_ messages: [ParsedMessage]) -> [ParsedMessage] {
        messages.filter { hasMarker($0.text,markers:["[转账]"]) }
    }
    static func redPackets(_ messages: [ParsedMessage]) -> [ParsedMessage] {
        messages.filter { hasMarker($0.text,markers:["[红包]","[微信红包]","[专属红包]"]) }
    }
    private static func hasMarker(_ text: String, markers: [String]) -> Bool {
        // Known text exports use a standalone first-line marker. Ordinary discussion,
        // quoted examples and a marker prefix followed by prose are not evidence.
        let first = text.trimmingCharacters(in:.whitespacesAndNewlines).components(separatedBy:.newlines).first ?? ""
        return markers.contains(first.trimmingCharacters(in:.whitespaces))
    }
    static func previewNotice(_ messages: [ParsedMessage]) -> String {
        let t = transfers(messages).count, r = redPackets(messages).count
        guard t > 0 || r > 0 else { return "" }
        var parts: [String] = []
        if t > 0 { parts.append("\(t) 条转账标识消息") }
        if r > 0 { parts.append("\(r) 条红包标识消息") }
        return "导出包含" + parts.joined(separator:"、") + "；金额、方向及实际笔数请到微信原记录核对。"
    }
    static func modelContext(_ messages: [ParsedMessage]) -> String {
        if transfers(messages).isEmpty && redPackets(messages).isEmpty {
            return "程序未识别到任何转账或红包标识记录。不得添加‘导出含交易标记’、交易缺失或回微信核对金额/方向/笔数等通用提醒；普通文字提及交易不等于实际交易记录。"
        }
        return "程序已识别到导出中的独立交易标识消息，稍后会追加带原文引用的核对说明。模型正文不要重复交易占位或提醒；标识消息条数不等于实际交易笔数。"
    }
    static func notice(_ messages: [ParsedMessage]) -> String {
        let transfers = transfers(messages), packets = redPackets(messages)
        guard !transfers.isEmpty || !packets.isEmpty else { return "" }
        var lines: [String] = []
        if !transfers.isEmpty {
            let missing = transfers.filter{$0.text.trimmingCharacters(in:.whitespacesAndNewlines) == "[转账]"}.count
            lines.append("聊天记录中发现 \(transfers.count) 条转账相关记录。" + (missing > 0 ? "其中 \(missing) 条仅有 [转账] 占位，未提供金额等交易明细。" : "这些记录不等同于相同笔数的独立交易。"))
            lines.append("具体金额、实际笔数、资金方向及收款状态，请从微信聊天记录中查看。不能只凭消息发送人推断谁向谁付款，发起和收款确认也可能属于同一笔交易。")
            lines.append("对应原文：" + transfers.map{"[["+$0.id+"]]"}.joined(separator:" "))
        }
        if !packets.isEmpty {
            lines.append("聊天记录中发现 \(packets.count) 条红包相关记录。具体金额、领取对象和领取状态，请从微信聊天记录中查看；导出标记不能证明已经收款。")
            lines.append("对应原文：" + packets.map{"[["+$0.id+"]]"}.joined(separator:" "))
        }
        return "\n\n## 转账与红包核对\n" + lines.joined(separator:"\n\n") + "\n"
    }
}
