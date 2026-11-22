# 签名与安装

## 模式 A · 下载后自行签名

1. 按实际 Apple 开发团队的 App ID 决定 Bundle ID。在仓库 Actions Variables 中设置 `FRAMEFLOW_BUNDLE_ID`，或在本机执行 `FRAMEFLOW_BUNDLE_ID=org.example.frameflow scripts/build-unsigned.sh`。默认值为 `com.frameflow.app`。
2. 下载并解压 Artifact，运行 `shasum -a 256 -c checksums.txt`。在配有 Xcode 的 Mac 上可再次运行 `scripts/validate-ipa.sh FrameFlow-unsigned.ipa org.example.frameflow`，最后一个参数换成构建时的 ID。
3. 在兼容签名工具中导入 IPA、带私钥的有效证书和对应 profile。选择与 profile 授权相符的实际 Bundle ID，检查 Team ID、有效期和注册设备 UDID。开发调试与 Ad Hoc 分发要分别使用匹配的证书和 profile。
4. 嵌入 profile 到 `Payload/FrameFlow.app/embedded.mobileprovision`。让签名工具生成该 App 实际需要且获得授权的 entitlements。系统会校验 application-identifier、团队和访问组等签名信息。当前版本使用系统框架，没有自带 Framework 或 Extension；以后如有嵌套代码，应由工具识别 Frameworks 和 PlugIns，逐个由内向外签名，扩展使用对应的标识和 profile，最后签主 App。签名后更改可执行文件、资源、Info.plist 或嵌套代码都需要重新签名。
5. 使用 Xcode 的设备管理或 Apple Configurator 安装签名后的 IPA。在开发安装需要时，在设备上启用开发者模式。安装后打开 App，用一个可读 ARW 验证文件访问、参数保存与导出。[Apple 注册设备安装指南](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)

文件选择器与默认私有 Keychain 访问组足以实现当前功能。工程没有自定义 entitlements 文件，也没有 App Groups、iCloud、共享 Keychain 组或后台网络权限。重新签名若更换团队或 Bundle ID，系统可能将其视为独立应用，原容器和原 Keychain 项的访问权限可能变化。第三方重签工具的兼容性需要实机验证。Apple 支持的签名交付路径见下方 archive/export 流程。[Apple 签名与嵌套代码说明](https://developer.apple.com/documentation/xcode/using-the-latest-code-signature-format) · [Provisioning Profile 授权模型](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)

## 模式 B · Xcode 签名导出

在受信任的仓库设置以下 Actions Secrets。P12 和 profile 的值是原文件的 Base64，Base64 的保密性完全依赖 Secrets 存储。证书、私钥及密码留在本机或 Secrets 中。

| Secret | 内容 |
| --- | --- |
| IOS_P12_BASE64 | 含证书和私钥的 PKCS#12 文件，以 Base64 编码 |
| IOS_P12_PASSWORD | 导出 P12 的密码 |
| IOS_PROFILE_BASE64 | 与目标设备、团队及 Bundle ID 匹配的 provisioning profile，以 Base64 编码 |

手动运行工作流并勾选签名选项。开发 profile 选 `debugging`，Ad Hoc 分发选 `release-testing`。签名 Job 在 unsigned Job 成功后独立启动。缺少任一凭据会显示跳过通知。凭据无效或导出失败会使 signed Job 失败，已经产生的 unsigned Artifact 仍可下载。

脚本创建临时 Keychain，导入证书，匹配 profile 中有效的签名身份，临时安装 profile。从 profile 读取团队信息并用手动签名设置执行 `xcodebuild archive` 和 `xcodebuild -exportArchive`。导出后验证 ZIP、签名和内嵌 profile，上传 `FrameFlow-iOS-Signed/FrameFlow-signed.ipa`。临时凭据在 finally 中清理。签名 IPA 按苹果格式包含其授权 profile；面向公开 Release 的 Job 只取未签名 Artifact。当前签名配置覆盖单 App target，新加扩展时需要为其添加 profile 映射。
