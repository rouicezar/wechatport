import AppKit
let app = NSApplication.shared
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let textMode = CommandLine.arguments[1] == "--text"
let items: [Any] = textMode ? ["Synthetic plain text"] : [url]
let services = NSSharingService.sharingServices(forItems: items)
let matches = services.filter { $0.title.contains("WeChatPort") }
print("matching_services=\(matches.count)")
for service in matches { print("title=\(service.title)") }
exit(textMode ? (matches.isEmpty ? 0 : 30) : (matches.isEmpty ? 30 : 0))
