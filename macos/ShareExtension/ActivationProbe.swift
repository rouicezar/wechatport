import AppKit
final class Probe: NSObject, NSApplicationDelegate, NSSharingServiceDelegate {
    var window: NSWindow!
    var service: NSSharingService?
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "WeChatPort 合成分享验证"
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        service = NSSharingService.sharingServices(forItems: [url]).first { $0.title.contains("WeChatPort") }
        guard let service else { print("event=service_missing"); exit(30) }
        service.delegate = self
        print("event=perform_synthetic_share"); fflush(stdout)
        service.perform(withItems: [url])
        DispatchQueue.main.asyncAfter(deadline: .now()+90) { print("event=activation_timeout"); exit(31) }
    }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        print("event=share_cancelled_or_failed domain=\((error as NSError).domain) code=\((error as NSError).code)"); fflush(stdout); NSApp.terminate(nil)
    }
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        print("event=unexpected_share_success"); fflush(stdout); exit(32)
    }
}
let app=NSApplication.shared
let probe=Probe(); app.delegate=probe; app.run()
