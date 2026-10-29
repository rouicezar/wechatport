import AppKit
import CoreServices
var error: Unmanaged<CFError>?
let id="com.rouice.wechatport" as CFString
let urls=LSCopyApplicationURLsForBundleIdentifier(id,&error)?.takeRetainedValue() as? [URL] ?? []
let data=try JSONSerialization.data(withJSONObject:urls.map{$0.standardizedFileURL.path}.sorted(),options:[.prettyPrinted])
print(String(data:data,encoding:.utf8)!)
