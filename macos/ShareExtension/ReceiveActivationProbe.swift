// Synthetic NSSharingService host; does not enumerate or operate other apps.
import AppKit
final class ReceiveProbe: NSObject, NSApplicationDelegate, NSSharingServiceDelegate {
    var window: NSWindow!
    var service: NSSharingService?
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "WeChatPort 合成接收验证"
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        let files = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
        service = NSSharingService.sharingServices(forItems: files).first { $0.title.contains("WeChatPort") }
        guard let service else { print("event=service_missing"); exit(30) }
        service.delegate = self
        print("event=perform_synthetic_share attachments=\(files.count)"); fflush(stdout)
        service.perform(withItems: files)
        DispatchQueue.main.asyncAfter(deadline: .now()+60) { print("event=activation_timeout"); exit(31) }
    }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        print("event=share_failed domain=\((error as NSError).domain) code=\((error as NSError).code)"); fflush(stdout); exit(4)
    }
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        print("event=share_completed returned_items=\(items.count)"); fflush(stdout); NSApp.terminate(nil)
    }
}
let app = NSApplication.shared
let probe = ReceiveProbe(); app.delegate = probe; app.run()
