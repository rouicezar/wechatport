import SwiftUI
import ServiceManagement

@MainActor final class AppBehavior: ObservableObject {
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var error = ""
    func setLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            error = SMAppService.mainApp.status == .requiresApproval ? "请在系统设置中允许登录项。" : ""
        } catch { loginEnabled = SMAppService.mainApp.status == .enabled; self.error = "无法更改登录项，请在系统设置中检查。" }
    }
}
struct BehaviorSettings: View {
    @StateObject private var behavior = AppBehavior()
    @AppStorage("showMenuBar") private var showMenuBar = false
    @AppStorage("processingPaused") private var paused = false
    @AppStorage("appearance") private var appearance = "system"
    var body: some View {
        GroupBox {
            VStack(alignment:.leading,spacing:14) {
                Picker("外观",selection:$appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }
                Toggle("登录时打开",isOn:Binding(get:{behavior.loginEnabled},set:{behavior.setLogin($0)}))
                Toggle("显示菜单栏图标",isOn:$showMenuBar)
                Toggle("暂停处理新批次",isOn:$paused)
                if paused { Text("新分享仍安全暂存，恢复后可处理。").font(.caption).foregroundStyle(.secondary) }
                if !behavior.error.isEmpty { Text(behavior.error).foregroundStyle(.red) }
            }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
        }.onChange(of:appearance) { _, value in NSApp.appearance = value == "dark" ? NSAppearance(named:.darkAqua) : value == "light" ? NSAppearance(named:.aqua) : nil }
    }
}
struct MenuBarControls: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("打开 WeChatPort") { openWindow(id:"main"); NSApp.activate(ignoringOtherApps:true) }
        Divider()
        Button("检查更新…") { UpdateController.shared.show(check:true) }
        Button("版本升级…") { UpdateController.shared.show() }
        Divider()
        Button("退出") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
