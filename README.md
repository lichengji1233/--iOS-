# 小帮手小熊猫（iOS 版）

Android 版「小帮手小熊猫」的 iOS 移植。支持抖音 / 小红书 / B站链接解析，保存原视频、原图、文案。

## 目录结构

- `ios-app/`：SwiftUI 应用源码（解析器、下载、保存相册、界面）
- `project.yml`：XcodeGen 工程配置（用 XcodeGen 生成 `.xcodeproj`）
- `.github/workflows/build-ipa.yml`：GitHub Actions 云端构建 IPA
- `codemagic.yaml`：Codemagic 云端构建配置（备选）

## 本地构建（需要有 Mac）

```bash
brew install xcodegen
xcodegen generate
open LinkSaver.xcodeproj
```

在 Xcode 中选择 LinkSaver scheme，选择自己的签名 Team 后运行到真机；或 `Product > Archive` 导出。

## 云端构建（没有 Mac 也能出 IPA）

把本目录推送到 GitHub 仓库（`main` 分支），GitHub Actions 会自动在 macOS 机器上编译并生成 `LinkSaver.ipa`，在 Actions 页面下载 artifact 即可。

## 安装到 iPhone（无开发者账号）

推荐用电脑（Windows/Mac 均可）上的 **Sideloadly** 安装：

1. iPhone 连接电脑，在 iPhone 上「设置 → 通用 → VPN与设备管理」信任电脑；
2. 电脑安装 Sideloadly（https://sideloadly.io）；
3. 打开 Sideloadly，拖入 `LinkSaver.ipa`，填入 Apple ID（免费即可）和密码，点击 Start；
4. 装好后在「设置 → 通用 → VPN与设备管理」信任该开发者；
5. 免费 Apple ID 签名的应用每 7 天需要重新签名一次（再次运行 Sideloadly 即可）。

注意：Apple ID 建议用不常用的账号，开启"允许 App 专用密码"更稳妥。
