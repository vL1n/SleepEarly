# FrameFlow

面向 Sony A7C II 的原生 iPhone / iPad 选片与 RAW 显影工具。最低系统为 iOS / iPadOS 18。一个通用 IPA 同时包含两种设备家族的支持。

## 下载未签名 IPA

1. 打开 [Build FrameFlow IPA](https://github.com/vL1n/SleepEarly/actions/workflows/build-ipa.yml)，点 **Run workflow**，选择 `main`，保持签名选项关闭。
2. 打开该次运行。绿色的 `unsigned` Job 表示真机 Release 构建、IPA 校验和模拟器测试均已通过。
3. 在运行页底部的 **Artifacts** 下载 **FrameFlow-iOS-Unsigned**。解压下载的外层 ZIP，得到 `FrameFlow-unsigned.ipa`、`build-info.txt` 和 `checksums.txt`。下载 Artifact 需要登录 GitHub。
4. 在解压目录执行 `shasum -a 256 -c checksums.txt` 核对传输。IPA 自身已经包含 `Payload/FrameFlow.app`，可直接交给兼容的签名工具。

推送到 `main` 会自动执行相同流程。推送 `v*` 标签会在成功后发布带有 IPA 的 GitHub Release。复现方式及失败日志见 [RELEASE.md](RELEASE.md)。

**安装前必须签名。** 默认 Bundle ID 为 `com.frameflow.app`。可在仓库 Settings → Secrets and variables → Actions → Variables 设置 `FRAMEFLOW_BUNDLE_ID` 后重新构建。能否安装、运行以及使用相应权限取决于实际证书、私钥、Provisioning Profile、Bundle ID、Entitlements 和设备授权。默认工作流无需 Team ID 或 Secrets。详见 [SIGNING.md](SIGNING.md)。

## 从 SD 卡到 Mac mini

1. 插入读卡器，点 **导入 ARW**，在系统文件选择器进入 SD 卡的 DCIM 目录，可一次选多张。导入会复制并校验本地工作副本，需为原片和导出预留空间。
2. 浏览懒加载缩略图，点照片进入编辑器。设置 0–5 星、收藏或淘汰。在照片库按收藏或淘汰筛选。淘汰只改变标记。
3. 调整曝光、高光、阴影、相机白平衡基础上的色温偏移和对比度。可选居中裁剪、柔和或鲜明预设。编辑操作保存在 SwiftData 中，归档时写入版本化 JSON。
4. 从操作菜单复制当前照片参数，在网格点 **多选** 后同步，或 **导出 JPEG** 到指定文件夹。导出使用全分辨率 RAW 管线、sRGB 和当前裁剪。
5. 在 Mac mini 开启文件共享并允许账户写入目标共享目录。在 iOS“文件”→“浏览”→“…”→“连接服务器”输入 `smb://主机名或IP` 并登录。在 FrameFlow 选择 **归档 ARW、JPEG 与 JSON**，从文件选择器打开该共享内的目标文件夹。SMB2/3 协商、登录与网络会话由系统管理。[Apple 文件服务器连接指南](https://support.apple.com/guide/iphone/iphe9aff429a/ios)
6. 每张照片有一个版本目录，内含 `original.arw`、`edited.jpg`、`edits.json`。JSON 保留相机原文件名、库内 UUID、RAW SHA-256、选片标记和调整参数。断线后重新连接并对同一批照片和目录重试。已校验的照片维持单独的完成记录。保持 App 在前台。
7. 要释放空间，选择已归档照片，点 **清理已校验的本地副本** 并确认。重新选择同一归档根目录，App 会回读三个目标文件并核对本地原片，再移除 App 管理的 ARW。SD 卡原片始终保留。清理后库中保留参数和归档记录，再次显影需重新导入原片。

Apple 将 Sony Alpha ILCE-7C II 列在 iOS 18 的支持清单中。具体 ARW 编码仍需系统解码器实际接受。可读内嵌预览与可输出全分辨率 RAW 是独立能力，解码失败会显示错误。[Apple RAW 支持清单](https://support.apple.com/en-gb/120534)

## 工程和本机运行

```text
FrameFlow.xcodeproj/                 共享 FrameFlow scheme、App 和 XCTest targets
FrameFlow/
  App/                              SwiftUI 入口与 SwiftData 容器
  Core/                             照片索引、非破坏性配方和 JSON 格式
  Features/                         照片网格、选片、编辑器与批处理交互
  Services/                         RAW、缩略图、协调文件访问、归档和 Keychain
  Resources/                        App 图标和资源目录
  Tests/                            iOS XCTest
.github/workflows/build-ipa.yml       构建、测试、签名和发布入口
scripts/                            macOS 构建、打包与校验脚本
ARCHITECTURE.md  SIGNING.md  RELEASE.md  LICENSE
```

使用带 iOS 18 或更新 SDK 的稳定 Xcode 16+ 打开工程，选择 FrameFlow scheme 和 iOS 模拟器运行。工程只链接 Apple 系统框架。命令行可执行：

```sh
scripts/build-unsigned.sh
scripts/test-ios.sh
scripts/validate-ipa.sh build/dist/FrameFlow-unsigned.ipa
```

## 设备覆盖与下一阶段

`NavigationSplitView` 根据可用空间折叠列，网格自动排列，编辑器使用水平 size class 切换布局。当前照片保存在 scene 状态，编辑配方属于同一条照片记录。CI 在可用的 iPhone 模拟器中运行测试，优先选择 Duo，同时用同一个编辑器实例切换紧凑竖屏、宽屏和紧凑横屏。具体覆盖见对应运行日志。[Apple 的 iPhone Duo 适配说明](https://developer.apple.com/videos/play/tech-talks/111461/)

真机签名安装、Duo 折叠切换、USB-C 读卡器和 Mac mini SMB 断线恢复仍需实机验收。优先完成这组验证，再扩展曲线、分色 HSL、自由裁剪和持久化批量任务队列。App 内 SMB 客户端与专用网络凭据管理属于后续版本。
