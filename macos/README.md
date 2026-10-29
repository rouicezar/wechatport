# macOS 构建

使用macOS、Xcode命令行工具与Python 3。版本定义位于shared/version.json。

- 隔离合成检查：python3 scripts/verify-macos-product.py
- 双架构无签名构建：python3 scripts/macos-app.py verify-build
- 本机签名：python3 scripts/macos-share.py --identity "$IDENTITY" --arch arm64；另以x86_64构建Intel。
- 本地DMG：python3 scripts/package-macos-dmg.py --identity "$IDENTITY"

IDENTITY是本机证书指纹，私钥只留在钥匙串。构建产物位于run-output，不纳入源码。打包不自动上传发布。开发签名不代表Developer ID或公证。
