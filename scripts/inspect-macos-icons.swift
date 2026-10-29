import AppKit
let app = NSApplication.shared
let bundle = CommandLine.arguments[1]
func save(_ image:NSImage,_ path:String) throws {
 let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:128,pixelsHigh:128,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
 NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
 image.draw(in:NSRect(x:0,y:0,width:128,height:128));NSGraphicsContext.restoreGraphicsState()
 try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:path))
}
try save(NSWorkspace.shared.icon(forFile:bundle),CommandLine.arguments[2]+"/resolved-app.png")
let file=URL(fileURLWithPath:CommandLine.arguments[3])
let services=NSSharingService.sharingServices(forItems:[file]).filter{$0.title.contains("WeChatPort")}
guard services.count==1 else { print("service_count=\(services.count)");exit(2) }
try save(services[0].image,CommandLine.arguments[2]+"/resolved-share.png")
print("service_count=1 title=\(services[0].title) image_size=\(services[0].image.size)")
