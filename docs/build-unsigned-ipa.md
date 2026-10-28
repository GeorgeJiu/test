# 用 GitHub Actions 生成未签名 IPA，再用轻松签安装

工作流文件：`.github/workflows/ios-unsigned-ipa.yml`

## 触发

- 推送改动了 `ios/` 或工作流本身的提交会自动构建。
- 也可以手动运行：GitHub 仓库 → Actions → "iOS unsigned IPA" → Run workflow。
  可在 `bundle_id` 中填入与你描述文件匹配的 App ID（也可以留默认值，之后在轻松签里改）。

## 下载

构建完成后打开该次运行页面，底部 Artifacts 中：

- `LifeRecorder-unsigned-ipa-<commit>`：内含 `LifeRecorder-unsigned.ipa` 和 `build-info.txt`（commit、Bundle ID、Xcode 版本）。
- `build-log-<commit>`：完整编译日志，失败时也会上传。

GitHub 下载的 artifact 外面会再包一层 zip，先解压，得到 `.ipa`。

## 签名安装（轻松签）

1. 把 `LifeRecorder-unsigned.ipa` 传到 iPhone（AirDrop / 文件 App），用轻松签导入。
2. 选择你自己的 `.p12` 证书和 `.mobileprovision` 描述文件签名。
3. 如果描述文件不是通配符（wildcard），Bundle ID 必须与描述文件里的 App ID 一致。
4. 安装后首次打开，允许麦克风权限。

注意：

- 未签名 IPA 不能直接安装。
- 工作流不会读取或保存证书、密码或描述文件，也不要把它们提交到仓库。
- App 没有 entitlements 文件；后台录音来自 `Info.plist` 的 `UIBackgroundModes=audio`。
- 最低系统版本为 iOS 17。
