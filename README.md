# 相册扫描（TwinPix iOS）

自用 iPhone/iPad 照片去重 App。核心算法从 [TwinPixCleaner](https://github.com/AkshayKrGupta/TwinPixCleaner) macOS 版迁入，并加上类似 [Whittle](https://github.com/surendranb/whittle) 的 AI 选优。

## 功能

- **完全重复**：同尺寸分桶 → SHA-256
- **视觉相似**：Vision Feature Print + L2 + Union-Find（截图单独更严阈值）
- **iCloud**：可按需下载云端照片参与扫描 / 预览
- **预览**：点缩略图全屏查看，云端图自动拉取
- **AI 建议**：对接 DashScope 千问 VL（OpenAI 兼容接口），从一组相似图里选出该留哪张并给理由
- **删除**：PhotoKit →「最近删除」

## 打开工程

```bash
open TwinPixCleanerIOS.xcodeproj
```

1. Xcode → 选你的 **Team**
2. Bundle ID：`com.wangjiale.TwinPixCleanerIOS`
3. 接真机 → Run（需已安装对应 iOS 平台支持）

## 使用

1. 选「完全重复 / 视觉相似」和日期范围  
2. 可选「包含 iCloud 照片」  
3. 开始扫描 → 勾选多余 / 点「AI 建议」→ 删除  

首次用 AI：首页或结果页 →「配置 AI」→ 填入 DashScope API Key（默认 `qwen-vl-plus`）。

## 目录

- `TwinPixCore/` — 扫描 / 哈希 / 相似 / 删除  
- `TwinPixIOS/` — SwiftUI 界面 + AI 选优  

## 说明

照片经 AI 建议时会上传到你配置的 API 提供商。Key 只存在本机 `UserDefaults`，不会写入仓库。
