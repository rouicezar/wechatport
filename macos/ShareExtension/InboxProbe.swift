// Synthetic-only fault harness; never included in the product bundle.
import Foundation
import Darwin
@main struct InboxProbe {
    static func main() throws {
        let args = CommandLine.arguments
        let mode = args[1]; let root = URL(fileURLWithPath: args[2])
        if mode == "recover" {
            let r = try InboxStore.recover(root: root)
            print("recovered=\(r.recovered) incomplete=\(r.incomplete) busy=\(r.busy)"); return
        }
        let files = args.dropFirst(3).map { URL(fileURLWithPath: $0) }
        let store = try InboxStore(root: root, expected: files.count)
        let control = ReceiveControl(); control.onCancel(store.cancellationMarker())
        print("batch=\(store.id)"); fflush(stdout)
        do {
            for (index, file) in files.enumerated() {
                try store.copy(file, index: index, originalName: file.lastPathComponent,
                               mediaType: "application/octet-stream", control: control, chunkObserved: { bytes in
                    if mode == "interrupt", bytes >= 1048576 { kill(getpid(), SIGKILL) }
                    if mode == "cancel" { control.cancel() }
                })
            }
            if mode == "cancel-after-copy" { control.cancel() }
            if mode == "stage" { return }
            if mode == "hold" { print("event=holding_lock"); fflush(stdout); sleep(30); return }
            if mode == "sealed-interrupt" {
                try store.finish(control: control, beforeRename: { kill(getpid(), SIGKILL) }); return
            }
            if mode == "tamper" {
                let attachment = try FileManager.default.contentsOfDirectory(at: store.partial.appendingPathComponent("attachments"), includingPropertiesForKeys: nil).first!
                try Data("corrupted".utf8).write(to: attachment)
            }
            try store.finish(control: control)
            guard !control.cancel() else { throw InboxError.corrupt }
            print("event=ready")
        } catch {
            print("event=failed")
            if mode == "retry" {
                // Failure caused by absent second source; make only that explicit synthetic input now.
                try Data("retry synthetic".utf8).write(to: files.last!)
                for (index, file) in files.enumerated() {
                    try store.copy(file, index: index, originalName: file.lastPathComponent,
                                   mediaType: "application/octet-stream", control: control)
                }
                try store.finish(control: control); print("event=retry_ready")
            } else { exit(4) }
        }
    }
}
