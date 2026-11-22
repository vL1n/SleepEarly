# 构建与发布

## 触发及产物

| 事件 | 结果 |
| --- | --- |
| push 到 main | 构建并测试，上传 FrameFlow-iOS-Unsigned |
| Actions 手动运行 | 相同未签名产物，可另行选择签名导出 |
| push 新的 v* 标签 | 重新构建并测试该提交，在 GitHub Release 附加 IPA、构建信息和 SHA-256 |

工作流使用 GitHub 托管 macOS 26，枚举稳定命名的 Xcode，检查 Swift 与 iPhoneOS SDK，选择满足项目条件的最新安装版本。脚本使用 DEVELOPER_DIR 设置当前运行环境。SDK 最低为 18，部署目标为 18.0。解析 SPM 后显式选择 Release、iphoneos、generic/platform=iOS、arm64、CODE_SIGNING_ALLOWED=NO。项目当前没有第三方依赖。

脚本将 Release-iphoneos 的完整 App 拷入新的 Payload 目录，保留可执行权限和符号链接，去除可能存在的 linker ad-hoc 签名后创建 ZIP。校验覆盖 ZIP CRC、路径和符号链接边界、Info.plist、标识符、真机平台、主程序 Mach-O 类型、可执行权限、全部 Mach-O 的 arm64 架构及 LC_BUILD_VERSION 平台。通过后才移动到最终文件名。测试在独立的 simulator 构建目录运行，优先选择可用的 Duo。上传步骤只接受成功完成的构建和测试。每次 Artifact 含实际 IPA、编译元数据与校验和。

本地使用完整 Xcode 时，可先导出 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`，然后在 Git checkout 根目录依次执行：

```sh
scripts/test-ios.sh
scripts/build-unsigned.sh
(cd build/dist && shasum -a 256 -c checksums.txt)
```

若已有真实设备构建产物，可独立运行 `scripts/package-ipa.sh path/to/FrameFlow.app build/dist/FrameFlow-unsigned.ipa`。可从任意目录运行 `scripts/validate-ipa.sh /absolute/path/to/FrameFlow-unsigned.ipa com.frameflow.app` 检查默认 ID 的产物。

## 发布一个版本

在 Xcode 中更新 App target 的 MARKETING_VERSION 和 CURRENT_PROJECT_VERSION 并提交，确认 main 对应提交已通过。给要发布的提交创建新标签并推送，例如：

```sh
git tag v1.0.0
git push origin v1.0.0
```

普通构建使用 contents: read，只有标签发布 Job 使用 contents: write。Release 从同一次运行成功上传的 Artifact 下载文件并重新校验 SHA-256。无需 PAT 或 Apple 签名凭据。分支、标签保护及仓库 Actions 权限须允许对应操作。Artifact 采用仓库保留期限，正式版本可从 Releases 下载。

## 故障定位

打开运行页展开首个失败步骤。下载 FrameFlow-build-logs 查看 toolchain.log、resolve.log、device.log、package.log、simulator.log 或 xcresult；可用 Xcode 打开 Tests.xcresult。失败前尚未执行到的步骤没有对应日志。若 simulator 目标不匹配，比较 destinations.txt 与 devices.json。若 IPA 校验报错，先查 build-info 对应的 Bundle ID 设置和 device.log 的 SDK、ARCHS，再对包内主程序运行 xcrun vtool -show-build。签名错误单独查看 signed Job、签名日志与 SIGNING.md。
