import Foundation
import Darwin

@main struct PendingProbe {
    static func main() throws {
        let args = CommandLine.arguments
        let container = URL(fileURLWithPath: args[2])
        let inbox = PendingInbox(container: container)
        switch args[1] {
        case "seed":
            let source = container.appendingPathComponent("synthetic-" + UUID().uuidString + ".txt")
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            try Data("P1-05 synthetic bytes\u{0}\r\n".utf8).write(to: source)
            let store = try InboxStore(root: inbox.root, expected: 1)
            try store.copy(source, index: 0, originalName: "synthetic.txt", mediaType: "text/plain", control: ReceiveControl())
            try store.finish(control: ReceiveControl())
            print(store.id)
        case "scan", "crash":
            let snapshot = try inbox.scan(beforeCommit: args[1] == "crash" ? { kill(getpid(), SIGKILL) } : nil)
            let result: [String: Any] = ["ids": snapshot.batches.map(\.id), "rejected": snapshot.rejected, "incomplete": snapshot.incomplete]
            print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
        case "signal": InboxSignal.post()
        default: exit(2)
        }
    }
}
