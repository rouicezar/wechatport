import Foundation
import Security
import Combine
import CryptoKit

struct ModelChoice: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    static let catalog = [ModelChoice(id: "deepseek-flash", name: "DeepSeek Flash"), ModelChoice(id: "deepseek-v4-pro", name: "DeepSeek V4 Pro")]
    static let version = "2026-10-29-deepseek-1"
}
enum CredentialStore {
    static let defaultService = "com.rouice.wechatport.deepseek"
    static func save(_ value: String, service: String = defaultService) throws {
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"api-key"]
        let attributes: [String:Any] = [kSecValueData as String:Data(value.utf8),kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _,new in new } as CFDictionary,nil) == errSecSuccess else { throw ModelFailure.credential }
        } else if status != errSecSuccess { throw ModelFailure.credential }
    }
    static func read(service: String = defaultService) throws -> String? {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"api-key",kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data:data,encoding:.utf8) else { throw ModelFailure.credential }
        return value
    }
    static func delete(service: String = defaultService) throws {
        let status = SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"api-key"] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ModelFailure.credential }
    }
}
enum ModelFailure: LocalizedError {
    case credential, auth, balance, rate, network, server, response, truncated, cancelled, budget, references
    var errorDescription: String? {
        switch self {
        case .credential: return "无法访问安全凭据，请在本机设置中重新保存 Key。"
        case .auth: return "Key 无效或权限不足，请更换后重新验证。"
        case .balance: return "DeepSeek 余额不足，请在服务商账户处理后重试。"
        case .rate: return "服务商限流，暂未完成。请稍后手动重试；重试可能产生费用。"
        case .network: return "网络连接中断或超时；已成功段保留，可手动重试失败部分。"
        case .server: return "服务商暂不可用，请稍后重试。"
        case .response: return "模型响应格式无法识别，未标记完整成功。"
        case .truncated: return "模型输出被截断或过滤，未标记完整成功。请缩小范围或重试。"
        case .cancelled: return "已取消；成功段已保留，重新请求可能产生费用。"
        case .budget: return "消息、提示词或所选范围超过本版本预算，请缩小后重试。没有静默截断。"
        case .references: return "结果引用校验未通过，存在快照以外引用或缺少来源；未标记完整成功。"
        }
    }
    static func http(_ status: Int) -> ModelFailure {
        switch status { case 401,403:return .auth; case 402:return .balance; case 429:return .rate; case 500...599:return .server; default:return .response }
    }
}
struct RateLimitFailure: LocalizedError {
    let retryAt: Date
    var errorDescription: String? {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        return "DeepSeek限流，请在 " + formatter.string(from:retryAt) + " 后重试。"
    }
    static func from(_ response: HTTPURLResponse) -> RateLimitFailure {
        let raw = response.value(forHTTPHeaderField:"Retry-After") ?? ""
        if let seconds = Double(raw), seconds.isFinite, seconds >= 0 { return RateLimitFailure(retryAt:Date(timeIntervalSinceNow:seconds)) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT:0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return RateLimitFailure(retryAt:max(formatter.date(from:raw) ?? Date(timeIntervalSinceNow:30),Date()))
    }
}
// Controlled HTTPS destination; redirects are rejected so a bearer key cannot follow another origin.
final class DeepSeekClient: NSObject, URLSessionTaskDelegate {
    private let testConfiguration: URLSessionConfiguration?
    init(configuration: URLSessionConfiguration? = nil) { testConfiguration = configuration; super.init() }
    private lazy var session: URLSession = {
        let config = testConfiguration ?? URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 120; config.timeoutIntervalForResource = 600
        config.httpCookieStorage = nil; config.urlCache = nil
        return URLSession(configuration:config,delegate:self,delegateQueue:nil)
    }()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func generate(model: String, key: String, system: String, user: String, progress: @escaping (Int) async -> Void) async throws -> String {
        guard ModelChoice.catalog.contains(where:{$0.id == model}) else { throw ModelFailure.response }
        var request = URLRequest(url:URL(string:"https://api.deepseek.com/chat/completions")!)
        request.httpMethod = "POST"; request.setValue("Bearer " + key,forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject:["model":model,"messages":[["role":"system","content":system],["role":"user","content":user]],"thinking":["type":"disabled"],"stream":true,"max_tokens":8192])
        do {
            let (bytes,response) = try await session.bytes(for:request)
            guard let http = response as? HTTPURLResponse else { throw ModelFailure.response }
            if http.statusCode == 429 { throw RateLimitFailure.from(http) }
            guard http.statusCode == 200 else { throw ModelFailure.http(http.statusCode) }
            var output = "", stopped = false, done = false, characters = 0
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data:") else { continue }
                let content = line.dropFirst(5).trimmingCharacters(in:.whitespaces)
                if content == "[DONE]" { done = true; break }
                guard let data = content.data(using:.utf8),
                      let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],
                      let choices = object["choices"] as? [[String:Any]] else { throw ModelFailure.response }
                for choice in choices {
                    if let delta = choice["delta"] as? [String:Any], let text = delta["content"] as? String {
                        output += text; characters += text.count
                        guard output.utf8.count <= 4*1024*1024 else { throw ModelFailure.budget }
                        if characters >= 128 { await progress(output.count); characters = 0 }
                    }
                    if let finish = choice["finish_reason"] as? String { guard finish == "stop" else { throw ModelFailure.truncated }; stopped = true }
                }
            }
            guard done, stopped, !output.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw ModelFailure.truncated }
            return output
        } catch is CancellationError { throw ModelFailure.cancelled }
        catch let failure as RateLimitFailure { throw failure }
        catch let failure as ModelFailure { throw failure }
        catch { if Task.isCancelled { throw ModelFailure.cancelled }; throw ModelFailure.network }
    }
}

@MainActor final class ModelSettings: ObservableObject {
    @Published var selected = UserDefaults.standard.string(forKey:"deepseekModel") ?? "deepseek-flash"
    @Published var keyInput = ""
    @Published var hasKey = false
    @Published var busy = false
    @Published var status = "未配置模型"
    @Published var verified: Set<String> = []
    @Published var retryAt = Date.distantPast
    private let client = DeepSeekClient()
    init() {
        do { hasKey = try CredentialStore.read() != nil; status = hasKey ? "Key 已保存，待验证" : "未配置模型" }
        catch { status = error.localizedDescription }
        if hasKey, UserDefaults.standard.string(forKey:"validatedCatalog") == ModelChoice.version {
            verified = Set(UserDefaults.standard.stringArray(forKey:"verifiedModels") ?? [])
            if !verified.isEmpty { status = "连接已验证" }
        }
    }
    func save() {
        let value = keyInput.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do { try CredentialStore.save(value); keyInput = ""; hasKey = true; verified = []; UserDefaults.standard.removeObject(forKey:"verifiedModels"); status = "Key 已安全保存" }
        catch { status = error.localizedDescription }
    }
    func remove() {
        do { try CredentialStore.delete(); keyInput = ""; hasKey = false; verified = []; UserDefaults.standard.removeObject(forKey:"verifiedModels"); status = "已删除本机 Key" }
        catch { status = error.localizedDescription }
    }
    func validate() {
        guard !busy, hasKey, Date() >= retryAt else { return }; busy = true
        let model = selected
        Task {
            defer { busy = false }
            do {
                guard let key = try CredentialStore.read() else { throw ModelFailure.credential }
                _ = try await client.generate(model:model,key:key,system:"Reply only OK.",user:"Connection validation only. Reply OK.",progress:{_ in})
                verified.insert(model); UserDefaults.standard.set(model,forKey:"deepseekModel")
                UserDefaults.standard.set(Array(verified),forKey:"verifiedModels"); UserDefaults.standard.set(ModelChoice.version,forKey:"validatedCatalog")
                status = "连接正常"
            } catch { if let rate = error as? RateLimitFailure { retryAt = rate.retryAt }; verified.remove(model); status = error.localizedDescription }
        }
    }
}
