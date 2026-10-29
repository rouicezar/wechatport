import Foundation
@main struct UpdateProbe {
    static func main() throws {
        let fm = FileManager.default
        let source = URL(fileURLWithPath:CommandLine.arguments[1]), old = URL(fileURLWithPath:CommandLine.arguments[2]), base = URL(fileURLWithPath:CommandLine.arguments[3])
        try fm.createDirectory(at:base,withIntermediateDirectories:true)
        let before = try UpdateInstaller.inspect(old), after = try UpdateInstaller.inspect(source)
        guard after > before, AppVersion(version:"0.10.0",build:1) > AppVersion(version:"0.9.0",build:999), AppVersion(version:"0.1.0",build:21) > AppVersion(version:"0.1.0",build:20) else { fatalError("version ordering") }
        let destination = base.appendingPathComponent("WeChatPort.app"); try fm.copyItem(at:old,to:destination)
        enum Fault: Error { case stop }
        do { _ = try UpdateInstaller.install(source:source,destination:destination,expected:before,afterBackup:{throw Fault.stop}); fatalError("fault accepted") } catch is UpdateFailure { }
        guard try UpdateInstaller.inspect(destination) == before else { fatalError("rollback failed") }
        let backup = try UpdateInstaller.install(source:source,destination:destination,expected:before)
        guard try UpdateInstaller.inspect(destination) == after, try UpdateInstaller.inspect(backup) == before else { fatalError("upgrade/backup") }
        do { _ = try UpdateInstaller.install(source:old,destination:destination,expected:after); fatalError("downgrade") } catch is UpdateFailure { }
        let tampered = base.appendingPathComponent("tampered.app"); try fm.copyItem(at:source,to:tampered)
        let executable = tampered.appendingPathComponent("Contents/MacOS/WeChatPort")
        let handle = try FileHandle(forWritingTo:executable); try handle.seekToEnd(); try handle.write(contentsOf:Data("tamper".utf8)); try handle.close()
        do { _ = try UpdateInstaller.inspect(tampered); fatalError("tampered signature accepted") } catch is UpdateFailure { }
        guard try UpdateInstaller.inspect(destination) == after else { fatalError("rejection changed installed app") }
        print("PASS signed update identity/version, actual isolated replacement/old backup, after-backup fault rollback, downgrade/tamper rejection; no production install/network/helper relaunch claim")
    }
}
