# LiteShot

LiteShot 是一个偏 AppKit 的 macOS 菜单栏截图工具原型，参考项目根目录中的界面图做了半透明截图遮罩、尺寸标签、浮动工具栏、历史记录和偏好设置。

## 功能

- 菜单栏常驻，快捷键可在偏好设置中录制；默认快捷键：
  - `Control + Shift + Command + 1`：截取区域
  - `Control + Shift + Command + 2`：截取全屏
- 浮动工具栏中的“保存”才会写入文件；“复制”“OCR”“翻译”不会自动保存到下载目录。
- 截图区域内支持简单箭头、矩形、画笔和文本标注。
- 本地 OCR 使用 Apple Vision，不需要联网；结果会显示并复制到剪贴板。
- AI 翻译使用 OpenAI Responses API 形态，可在偏好设置中自定义 API Key、模型、接口地址和目标语言。
- 历史记录只保存图片路径和元数据，尽量避免常驻时持有大图。

## 构建

```bash
swift build --product LiteShot
```

调试运行：

```bash
swift run LiteShot
```

打包为本地 `.app`：

```bash
Scripts/package_app.sh
open build/LiteShot.app
```

首次截图需要在系统设置里给 LiteShot 授予“屏幕与系统音频录制”权限。直接 `swift run` 时，权限可能会归属到 Terminal；长期使用建议运行打包后的 `build/LiteShot.app`。

## 结构

- `Sources/LiteShot/App`：AppKit 应用入口、菜单栏和窗口管理。
- `Sources/LiteShot/Capture`：屏幕截图、裁剪和导出。
- `Sources/LiteShot/Editor`：截图遮罩、浮动工具栏和标注绘制。
- `Sources/LiteShot/Core`：设置、Keychain、历史记录、OCR、翻译和剪贴板。
- `Sources/LiteShot/UI`：SwiftUI 偏好设置和历史记录。

## 当前边界

- 当前版本优先支持主显示器截图。
- 文本标注先固定为“文本”，后续可以接入原地编辑。
- 自定义 API 需要兼容 OpenAI Responses API 的请求/响应字段。
