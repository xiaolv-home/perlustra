# 架构

Perlustra 是一个不联网优先的 macOS 文件查看器：打开一个文件，挑一个合适的渲染器显示它。这份文档讲代码怎么分层、为什么这样分。分层规则由 `scripts/check-architecture.py` 执行，CI 里违反就失败，所以这里写的都是真实状态。

## 三个目标

```
Sources/Perlustra        入口，只有一行：PerlustraApplication.run()
Sources/PerlustraApp     应用：窗口、渲染器、AI 面板（依赖 AppKit / SwiftUI / WebKit）
Sources/PerlustraCore    纯逻辑：格式识别、表格、公式、AI 协议（不依赖任何界面框架）
```

把应用放进库而不是可执行目标，是为了让 `Tests/PerlustraAppTests` 能 `@testable import`。

## PerlustraApp 的分层

依赖只能朝下，不能反过来：

```
App, Shell      窗口、菜单、标签页、版口（知道一切）
AI/UI           AI 面板
AI, AI/Tools    会话和工具（只通过协议接触窗口与文档）
Renderers       每种文件怎么显示（不知道窗口是谁）
Services        跨渲染器的服务（导出、草稿）
DesignSystem    配色和通用控件
Base            设置、日志
```

外壳和渲染器之间、AI 和外壳之间只通过协议说话：

| 协议 | 定义在 | 作用 |
|---|---|---|
| `Renderer` | Renderers | 外壳需要从渲染器知道的一切：视图、状态、命令、降级说明、AI 建议 |
| `RenderHost` | Renderers | 渲染器需要窗口做的事：进度、横幅、降级、打开文件 |
| `FormatCommandHandling` | Renderers | 能接受「格式」菜单命令的文档 |
| `AppActions` | Renderers | 经响应链发送的应用级动作，视图不用认识 `AppDelegate` |
| `AIDocumentTools` | AI/Tools | 渲染器给 AI 提供的专属工具 |
| `AIWorkspace`, `AIDocument` | AI/Tools | AI 需要窗口和文档做的事 |

只有 `RendererRegistry` 能点名具体的渲染器。需要在外壳里判断「它是不是表格」时，正确的做法是给 `Renderer` 加一项能力，让它自己回答。

`AI/UI` 还会读 `TabList` 来知道当前标签页，所以它算外壳的一部分，不算 AI 内核。

## PerlustraCore 的分层

```
AI                               模型接口、工具循环、技能
Spreadsheet, Formula,            表格引擎：这四个互相引用，算一个整体
  Drawing, Chart
Text, Archive                    CSV、高亮、JSON、压缩包
Detection                        格式与编码识别
Support, Security                零散工具、路径边界（不依赖任何人）
```

这些是同一个模块里的文件夹，不是独立模块：表格引擎的循环里到处是跨文件的调用，拆成模块要把内部类型全部公开，还会失去跨模块优化。边界由架构检查保证。

## 打开一个文件时发生了什么

1. `ViewerModel` 在后台建 `FileContext`（读文件头、识别格式）。
2. `RendererRegistry.chain(for:)` 给出按顺序尝试的渲染器，比如 Markdown → 纯文本 → 十六进制。
3. 依次尝试 `makeView`。失败就换下一个，并记下原因。
4. 接手的渲染器用 `fallbackNote` 说明自己为什么在这里；如果显示的是损坏文件的原始内容，还会弹横幅。

渲染器是一次性的：一个文件一个实例，换文件时调用 `cleanup()`。

## 网页内容

Markdown、HTML 走 WKWebView。所有资源经 `perlustra://` 协议提供（`perlustra://app/` 是应用自带的，`perlustra://file/` 是用户文件），外网请求一律被内容规则拦截。写作模式基于 Vditor，`writer.js` 不往编辑器 DOM 里加东西，专注模式、查找高亮和下划线都用样式规则或 CSS Highlight API，否则可能被写进文件。

## 改名

应用原名 Loupe。Bundle ID 有意保留 `app.loupe.viewer`：系统按它记录最近文档、默认打开方式和文件访问授权，这些都带不到新 ID 上。其余旧名字的数据由 `Services/LegacyData.swift` 在首次启动时迁移。

## 主题

首页的雕版线在 `Shell/Home/`：着色器运行时编译（命令行工具没有 Metal 编译器），放大镜里是同一组曲线。不跑循环，只有东西在动时才有显示链接，所以被窗口挡住时不出帧，自动化要看效果用 `--cmd homepng:路径`。自动化运行读不到真实的最近打开，只读环境变量 `PERLUSTRA_RECENTS`。

颜色都在 `DesignSystem/Theme.swift`，用动态色，浅色和黑色各一套。给图层设颜色时不能直接取 `Theme.x.cgColor`：它按当前外观解析，系统是浅色、应用选了黑色时会取到浅色。要用 `NSView.resolved(_:)`，或者在 `updateLayer()` 里取，或者用 `SurfaceView`。架构检查会拦这种写法。

## 调试代码

`AppAutomation` 的 `--probe` 留在正式版里，CI 用它检查打包好的应用。截图、脚本化操作和所有 `debug*` 钩子都在 `#if DEBUG` 里，不会进正式包。

## 怎么加一种新格式

Parquet 在 `PerlustraCore/Parquet` 中读取，界面在 `ParquetRenderer`。固定版本的 DuckDB C 头文件在 `Sources/CDuckDB`，通用动态库由 `scripts/duckdb.sh` 校验下载，打包到 `Contents/Frameworks` 后按需加载；只有 Debug 测试可通过环境变量指定库。只使用固定查询和绑定参数，通配符文件名按字面值处理，关闭扩展自动安装和网络/其他文件访问。读取在后台进行，限制行列数量，带取消和超时；不依赖 Python。更新库版本时同时更新 C 头、下载哈希、许可证和样例回归。

1. 在 `Renderers/` 下写一个实现 `Renderer` 的类。
2. 在 `RendererRegistry.chain(for:)` 里排好它的位置，并在 `RendererRegistryTests` 里写明。
3. 在 `fixtures/` 放一个样例，并加进 `scripts/verify-renderers.py`。
4. 需要外壳配合时加协议能力，不要让外壳判断类型。
