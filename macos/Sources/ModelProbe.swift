import Foundation

final class FixtureProtocol: URLProtocol {
    static var status = 200
    static var body = ""
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.absoluteString == "https://api.deepseek.com/chat/completions",
              request.httpMethod == "POST", request.value(forHTTPHeaderField:"Authorization") == "Bearer synthetic-not-a-key" else { fatalError("unexpected destination") }
        let response = HTTPURLResponse(url:request.url!,statusCode:Self.status,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"text/event-stream","Retry-After":"5"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(Self.body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
@main struct ModelProbe {
    static func main() async throws {
        let isolatedService = "com.rouice.wechatport.test."+UUID().uuidString
        defer { try? CredentialStore.delete(service:isolatedService) }
        try CredentialStore.save("synthetic-test-value-1",service:isolatedService)
        guard try CredentialStore.read(service:isolatedService) == "synthetic-test-value-1" else { fatalError("credential read") }
        try CredentialStore.save("synthetic-test-value-2",service:isolatedService)
        guard try CredentialStore.read(service:isolatedService) == "synthetic-test-value-2" else { fatalError("credential replace") }
        try CredentialStore.delete(service:isolatedService)
        guard try CredentialStore.read(service:isolatedService) == nil else { fatalError("credential delete") }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FixtureProtocol.self]
        let client = DeepSeekClient(configuration:configuration)
        func invoke() async throws -> String { try await client.generate(model:"deepseek-flash",key:"synthetic-not-a-key",system:"synthetic",user:"synthetic",progress:{_ in}) }
        FixtureProtocol.body = "data: {\"choices\":[{\"delta\":{\"content\":\"测试\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        guard try await invoke() == "测试" else { fatalError("stream content") }
        for code in [401,403,402,429,500,503] {
            FixtureProtocol.status = code
            do { _ = try await invoke(); fatalError("HTTP error accepted") } catch let rate as RateLimitFailure {
                guard code == 429, rate.retryAt > Date() else { fatalError("retry after") }
            } catch let error as ModelFailure {
                guard error.localizedDescription == ModelFailure.http(code).localizedDescription else { fatalError("HTTP mapping") }
            }
        }
        FixtureProtocol.status = 200
        for body in ["data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":\"length\"}]}\n\ndata: [DONE]\n\n", "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":null}]}\n\n", "data: bad-json\n\n"] {
            FixtureProtocol.body = body
            do { _ = try await invoke(); fatalError("incomplete stream accepted") } catch is ModelFailure { }
        }

        // Isolated application settings lifecycle, without touching production preferences/key.
        let suiteName = "com.rouice.wechatport.settings-test."+UUID().uuidString
        let defaults = UserDefaults(suiteName:suiteName)!
        defer { defaults.removePersistentDomain(forName:suiteName) }
        let settings = await ModelSettings(defaults:defaults,credentialService:isolatedService,client:client)
        await MainActor.run { settings.keyInput = "synthetic-not-a-key"; settings.save() }
        FixtureProtocol.status = 200
        FixtureProtocol.body = "data: {\"choices\":[{\"delta\":{\"content\":\"OK\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        await settings.validate()
        while await settings.busy { try await Task.sleep(nanoseconds:10_000_000) }
        guard await settings.verified.contains("deepseek-flash") else { fatalError("settings validation success not recorded") }
        let successRestart = await ModelSettings(defaults:defaults,credentialService:isolatedService,client:client)
        guard await successRestart.verified.contains("deepseek-flash") else { fatalError("successful validation not restored") }
        FixtureProtocol.status = 401
        await settings.validate()
        while await settings.busy { try await Task.sleep(nanoseconds:10_000_000) }
        guard await !settings.verified.contains("deepseek-flash") else { fatalError("failed validation kept verified state") }
        let reopened = await ModelSettings(defaults:defaults,credentialService:isolatedService,client:client)
        guard await !reopened.verified.contains("deepseek-flash") else { fatalError("failed validation resurrected after restart") }

        await MainActor.run { reopened.keyInput = "synthetic-replacement-key"; reopened.save() }
        let replaced = await ModelSettings(defaults:defaults,credentialService:isolatedService,client:client)
        guard await replaced.hasKey, await replaced.verified.isEmpty else { fatalError("replacement key inherited old verification") }
        await replaced.remove()
        let deleted = await ModelSettings(defaults:defaults,credentialService:isolatedService,client:client)
        guard await !deleted.hasKey, await deleted.verified.isEmpty else { fatalError("deleted key restored as usable") }
        defaults.set("unsupported-model",forKey:"deepseekModel")
        let unsupported = await ModelSettings(defaults:defaults,credentialService:isolatedService,client:client)
        guard await unsupported.selected == "deepseek-flash" else { fatalError("unsupported saved model was selected") }
        print("PASS isolated model settings: success restart, failure restart, replacement/deletion verification reset and supported model fallback")
        print("PASS isolated Keychain save/read/replace/delete (no user credential access); controlled HTTPS request/stream completion; 401/403/402/429/500/503 classification; length/missing DONE/malformed response rejected. URLProtocol fixtures only, no real model call.")
    }
}
