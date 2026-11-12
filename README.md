# Perlustra

轻量、离线、原生的 macOS 万能文件查看器。一个窗口，看清每一种文件。

- **原生**：Swift + SwiftUI/AppKit，Universal（Apple Silicon + Intel），macOS 14 起。
- **轻量**：1.0.0 在 Apple Silicon 上测得安装包约 8 MB、启动到出窗口约 0.4–0.5 秒。之后每个带版本标签的发布说明会写上该次 DMG 的体积。启动时间要在本机直接运行二进制并设置 `PERLUSTRA_TIMING=1` 再测（`open -a` 传不进这个环境变量）。
- **稳定**：每种格式都有一条渲染器降级链：专用渲染器 → 系统快速查看 → 文本 → 十六进制，打不开就降级，不会白屏或崩溃。
- **离线优先、以看为主**：看文件不联网。Office 宏不执行。PDF 的外部链接不会自动打开，要点「在浏览器中打开」。Word / PowerPoint 交给系统快速查看，里面的超链接由系统处理，Perlustra 没有再拦一层。应用没有启用 App Sandbox，网页和 AI 的限制是程序自己做的检查。本地网页的脚本只在受限环境里运行（见「本地网页」）。只有你主动用 AI 或安装技能时才会访问对应的服务。表格和 Markdown 可以按需打开编辑。
- **独特的视觉**：「校样」设计语言。文档像一张带裁切标记的校样纸放在打样台上；代码用墨色加余烬橙的双色套印高亮；底部是印刷品出血区那样的版口信息条和色标条。

## 下载安装

**[下载最新版本](https://github.com/xiaolv-home/perlustra/releases/latest)**：下载 `Perlustra-版本号.dmg`，打开后把 **Perlustra** 拖进「应用程序」。需要 macOS 14 或更新版本，Apple Silicon 和 Intel 通用。首次打开的放行方法见下文「首次打开」。每个版本的 SHA-256 校验文件也在发布页里。

> [!NOTE]
> 当前在 Apple Silicon Mac 上日常使用；Intel 版本由同一份源码构建，没有在 Intel 机器上长期使用过。

## 支持的格式

| 类别 | 格式 | 引擎 | 说明 |
|---|---|---|---|
| PDF | pdf、ai | PDFKit | 缩略图 / 目录侧栏、页码跳转、缩放、文本选择、全文搜索高亮、全屏放映、加密 PDF 解锁；外部链接拦截 |
| iWork | pages、key、numbers（含旧版文件包） | Quick Look → Pages/Keynote/Numbers 导出 PDF | 先用快速查看秒开；本机装有 iWork 时在后台静默导出完整 PDF（缓存，文件修改后失效）；未安装时显示内嵌预览图并提示 |
| 表格 | xlsx/xlsm、ods、csv/tsv；xls、Numbers（经 Numbers 转换） | Perlustra 自有表格 | 保留原格式显示（含一格之内分段的字色、加粗、字号）；表上的图表（柱/条/折线/面积/饼/环形/散点/雷达/气泡、组合图与副坐标轴，没存缓存值的也从单元格现取数）、图片、形状和文本框、整页图表都画出来；筛选、查找、排序、隐藏行列、框选求和/平均/计数、约 90 个函数（含 VLOOKUP/XLOOKUP/SUMIFS）、计算列；可编辑单元格并保存（xlsx 局部写回、CSV 保持原编码）、另存为、导出 |
| Office | docx/doc、pptx/ppt、rtf/rtfd、odt/odp、wps | Quick Look | 演示文稿可「全屏放映」：借助 Keynote 转换，←/→ 翻页、Esc 退出；没有 Keynote 时改用快速查看全屏。不执行宏。快速查看里的超链接由系统打开，不像 PDF 那样先拦下来 |
| 图片 | jpg、png、gif（动图）、webp、heic/heif、avif、tiff（多页）、bmp、ico/icns、psd、exr、hdr、jp2、jxl、相机 RAW（cr2/cr3/nef/arw/dng/raf/orf/rw2…） | ImageIO + IOSurface | 1:1 原始像素 / 适应窗口、指针为中心缩放、拖动平移、旋转、像素化显示；保留色彩配置（Display P3 等）；HDR 以 EDR 显示；EXIF 信息；超过 16384 像素自动缩减显示 |
| 矢量图 | svg、svgz | WebKit（禁用脚本） | 可切换源码 |
| 视频 | mp4、mov、m4v（H.264/HEVC/ProRes/HDR） | AVFoundation | 原画质、逐帧、倍速、截图、画中画、全屏、外挂字幕 srt/ass/vtt、内嵌字幕 |
| 视频 | mkv、webm、avi、wmv、flv、rmvb、ts、mpg、ogv… | libmpv（内嵌 OpenGL，VideoToolbox 硬解） | 自动检测 Homebrew 的 mpv；嵌入失败时改用 mpv 独立窗口；未安装时给出安装提示 |
| 音频 | mp3、m4a、aac、flac、wav、aiff、caf → AVFoundation；opus、ogg、wma、ape、wv… → mpv | | 封面、标题、艺术家信息 |
| Markdown | md、markdown… | WebKit：Vditor，超长文档用 markdown-it（全部本地） | 打开就是能直接改的文档（像 Typora 一样边写边排版，内容居中，Markdown 符号只在光标处出现），⌘/ 切到**源码**；800 KB 以上的文档只显示排版页，在源码里修改；表格、任务列表、脚注、KaTeX 公式、Mermaid 图表、代码高亮；Typora 快捷键（见下）；⌘S 按原编码与换行保存，只写回改过的行，没改的地方保留原写法；跟随深浅色；HTML 经过净化，远程图片拦截，本地图片只限于该文件所在文件夹 |
| 文本 / 代码 | txt、log 以及 40 多种语言（swift、py、js/ts、go、rs、c/cpp、java、kt、sql、sh、yaml、toml、ini、xml、css、diff、Dockerfile、Makefile…） | TextKit | 行号、语法高亮、查找、自动换行；自动识别 UTF-8/UTF-16/UTF-32/GBK/GB18030/Big5/Shift_JIS/EUC-KR，可手动切换编码；超过 16 MB 进入虚拟化大文件模式（内存映射、按需解码、后台全文搜索），超过 2 MB 关闭高亮（可设置） |
| 数据 | json、geojson | 自研保序解析器 | 可折叠树视图（保持键顺序、拷贝值 / 路径）、源码；单行压缩 JSON 自动格式化 |
| 数据 | jsonl、ndjson | TextKit | 按行当文本高亮，不是可折叠树 |
| 数据 | plist（XML / 二进制） | PropertyListSerialization | 树视图；二进制 plist 自动转为可读 XML |
| 数据 | sqlite、sqlite3、db3 | Perlustra 自有 SQLite | 列出表和视图（名称、行数、列数），选中看每张表前 200 行数据；只读 |
| 数据 | parquet、parq | 内置 DuckDB | 离线只读预览，显示字段名、类型、总行数和行组数；前 200 行、最多 256 列，选中行 ⌘C 复制；支持 Snappy/Gzip/Zstd/Brotli/LZ4 和无压缩，长整数、小数、日期、列表与结构体 |
| 网页 | html、htm、xhtml | WebKit（禁用 JavaScript） | 远程资源拦截；可切换源码 |
| 字体 | ttf、otf、ttc、woff、woff2、dfont | CoreText | 字体样张、自定义预览文字、字符集网格、字面切换、字体信息（不会安装字体） |
| 压缩包 | zip、7z、rar、tar、gz/tgz、bz2、xz、zst、lz4、iso、cpio、xar/pkg、jar/apk、deb、rpm、cab… | 系统 libarchive | 只列目录结构，不解压；中文（GBK）文件名不乱码 |
| 文件夹 | 任意文件夹 / 软件包 | | 可展开浏览，双击打开文件 |
| 其他 | usdz、epub、vcf、ics、eml… | Quick Look | |
| 兜底 | 任何未知或二进制文件 | 十六进制查看器 | 文件信息与十六进制视图 |

格式识别依次参考**文件头魔数、扩展名、内容嗅探**。扩展名错误或缺失时也能正确识别，并在顶部提示「扩展名与实际内容不符」。

## 本地网页

离线阅读器、导出的报表这类本地 HTML 会运行自己的脚本，所以能正常显示。安全上做了这些限制：

- 所有联网请求都被拦住，包括 fetch、WebSocket 和跳转到网站。
- 脚本只能读取网页所在文件夹里的文件。会先解析符号链接，指向文件夹外面的链接读不到。关闭脚本时也一样，不能靠关掉脚本去读别的目录。
- 不能弹出新窗口。
- 阅读进度等本地存储会保留，与其他数据隔离。

如果不需要，可以在「设置 › 通用」里关掉。SVG 始终不运行脚本。

## 浏览与标签页

- **侧栏**（⌃⌘S）：显示当前文件夹，文件夹排在前面；顶部 ⌃ 返回上级，点文件夹名弹出上级路径、常用位置（个人、桌面、下载、文稿）、最近用过的文件夹和「选择文件夹…」。
- **标签页**：打开的文件以标签显示在窗口顶部，切换瞬间完成并保留各自的位置和选区；已开着的文件再打开会直接切过去。每个标签都有 ×，关掉最后一个回到首页。⌘T 新标签，⌘W 关闭标签（首页上 ⌘W 关窗口），⌃Tab / ⇧⌘] / ⇧⌘[ 切换。侧栏 ⌥单击或右键「在当前标签页中打开」则替换当前标签；←/→ 在同一文件夹里逐个浏览。侧栏可用键盘：↑↓ 移动，回车或 → 打开，← 返回上级。

## 表格

打开表格就是原文件的样子（合并单元格、颜色、字体、列宽、Excel 保存的缩放比例），用来看和算，默认不能编辑（设置里可打开「允许编辑表格」）。

- **计算框**：顶部 ƒx 框输入公式按回车出结果（可以不写等号），不改文件。支持约 90 个函数，跨工作表 `=汇总!A2`，跨文件 `=VLOOKUP(A2,[门店表.xlsx]Sheet1!A:C,2,0)`（文件放在同一文件夹，或点「引用其他文件」选择，会自动填好写法）。「填入选区」把选中的区域填进公式；「每行套用」把公式按行算成一列显示在最右边（只在屏幕上，可导出）。点 ƒx 看每个函数的中文说明和例子。
- **原样**：右上角的眼睛按钮用系统预览看原文件（图表、条件格式等），⌘U 切换。
- **选择**：单击、拖选；⇧单击选连续范围，⌘单击多选；点合并区域任意位置会选中整块；Shift 扩选、⌘ 追加选区；点行号选整行、点列标选整列；方向键移动，⌘ 方向键跳到数据边缘，⌘A 全选，⌘C 拷贝（制表符分隔，可直接粘贴进 Excel）。
- **统计**：底部状态栏实时显示选区的求和、平均、计数、最小和最大值；右键「拷贝统计结果」。
- **筛选与排序**：点列标右侧的 ▾（或右键列标）打开列面板，可以升序/降序、按条件筛选（包含、等于、大于、小于、介于、为空…）、勾选值筛选、隐藏列。也可以在单元格上右键「只显示 / 排除这个值」。多列筛选会同时生效。
- **隐藏**：右键「隐藏所选行 / 所选列」，状态栏会出现「显示隐藏的…」一键恢复。
- **查找**：⌘F 或公式栏右侧的查找框；所有匹配项都会高亮；回车跳到下一个，⇧回车上一个。
- **函数说明**：点公式栏的 ƒx 打开函数面板，按类别浏览或搜索（如「查找」「求和」），每个函数都有中文说明、写法、参数解释和例子，一键插入。在公式栏输入函数时，下方会提示当前正在填第几个参数、它是什么意思。
- **公式**：选中单元格时公式栏显示它的内容，Excel 里的公式会显示公式原文。在单元格或 ƒx 框里输入以 `=` 开头的公式，回车写入并计算，例如 `=SUMIF(B:B,"上海",D:D)`、`=VLOOKUP(B2,城市!A:B,2,FALSE)`。
- **计算列**：输入针对当前行的公式（如 `=D5/E5`），点「填充为新列」，就会像在 Excel 里拖动填充柄一样，算出整列放到表格最右边。相对引用随行变化，`$` 绝对引用保持不变。
- **支持的函数**（约 90 个）：
  - 聚合：SUM、AVERAGE、COUNT、COUNTA、MAX、MIN、MEDIAN、LARGE、SMALL、STDEV、SUMPRODUCT。
  - 条件：IF、IFS、IFERROR、IFNA、AND、OR、NOT、SWITCH、SUMIF(S)、COUNTIF(S)、AVERAGEIF(S)、MAXIFS、MINIFS。
  - 查找：VLOOKUP、HLOOKUP、XLOOKUP、INDEX、MATCH、XMATCH、CHOOSE。
  - 文本：LEFT、RIGHT、MID、LEN、FIND、SEARCH、SUBSTITUTE、REPLACE、TEXT、TEXTJOIN、CONCAT、TRIM、UPPER、LOWER、VALUE。
  - 数学：ROUND、ROUNDUP、ROUNDDOWN、INT、ABS、MOD、POWER、SQRT。
  - 日期：DATE、YEAR、MONTH、DAY、WEEKDAY、DAYS、DATEDIF、EDATE、EOMONTH、TODAY。
  - 支持跨工作表引用（`'表 名'!A1:B9`）和整列引用（`D:D`），条件里可以用 `*`、`?` 通配符。

## 写 Markdown（像 Typora）

- **⌘N 新建**：新文档先是草稿，边写边自动保存，不会丢；第一次 ⌘S 时再选存到哪里（草稿在 `~/Library/Application Support/Perlustra/Drafts`）。
- **文档和源码**：边写边排版，大纲栏 ⌃⌘1，⌘/ 切到源码。
- **快捷键与 Typora 一致**（「格式」菜单里都有）：⌘1–⌘6 标题、⌘0 正文、⌘B/⌘I/⌘U 加粗/斜体/下划线、⌘K 链接、⌃\` 行内代码、⌥⌘C 代码块、⌥⌘B 公式块、⌥⌘Q 引用、⌥⌘O/⌥⌘U/⌥⌘X 有序/无序/任务列表、⌥⌘T 表格、⌘[ ⌘] 缩进。
- **图片**：粘贴截图或拖入图片，自动存到文档旁边的 `assets/`，以相对路径插入（和 Typora 默认一样）。
- **保存只动改过的地方**：编辑器显示时会把 Markdown 规整一遍（表格补空格等），但保存时只把你改过的行写回去，其余保持原样；只打开再保存，文件不变。
- **导出**：底栏的导出按钮可存为 Word（原生表格和标题样式）、PDF、网页。

## AI 助手（⌘J）

窗口右侧的 AI 面板会对当前标签页的文件**真正动手**，不只是总结：

- **两种模式**：「本地」只连接 localhost 或 127.0.0.1（文件不出本机）；局域网或其他地址请改用「云端 API」里的自定义服务。「云端」支持 DeepSeek、通义千问、Kimi、智谱、豆包、硅基流动、Claude、OpenAI、OpenRouter 和任意 OpenAI 兼容接口。内置服务的接口地址是固定的，只有「自定义」和豆包可以改地址。API Key 只存在本机一个仅你的账户可读的文件里（~/Library/Application Support/Perlustra/ai-keys.json），不用钥匙串、不会弹密码框。
- **能做的事**：
  - 读任何文件：文本按原编码读，PDF 按页读，也能读 Word、PPT、Excel；图片会做文字识别（OCR）。
  - 用 Perlustra 的公式引擎精确计算，也可以跨文件 VLOOKUP。
  - 分组汇总、筛选屏幕上的表格、加计算列。
  - 直接在编辑器里改 Markdown，⌘Z 可撤销。
  - 生成文件：Word（原生表格、标题样式、编号列表）、PDF、HTML，以及 Excel（公式先算好结果再写入）和 CSV。
  - 在文件夹或资料库里搜索文字。
  - 运行终端命令（需要在设置里打开，每条都要你点「允许」）。
- **看图**：能看图的模型（本地 Qwen3.5/3.6 这类 VLM、Claude、GPT、通义 VL 等）可以直接看图片或 PDF 的某一页（`view_image`）。也可以点回形针附图，或直接粘贴截图。不能看图的模型会自动改为发送识别出的文字。
- **历史对话**：每次对话自动保存在本机（`~/Library/Application Support/Perlustra/Conversations`），面板顶部的时钟按钮可以搜索、打开后接着聊、删除。
- **安全**：原文件不会被改，生成的文件放在原文件旁边，覆盖已有文件要你确认。AI 只能写入个人文件夹（不含隐藏目录和 ~/Library）。不读取隐藏目录（包括嵌套的 `.env`、`.ssh`）和 `~/Library`（已安装的技能目录除外），也不读 `/etc`、`/System`。符号链接按它指向的真实路径判断。
- **使用云端模型时**，你发给 AI 的内容（包括它读取的文件内容和图片）会发送到你选择的服务商，按该服务商的条款处理。处理敏感文件请用「本地」模式。
- **AI 的输出只供参考**：包括「合同审阅」「简历诊断」等技能在内，结果不构成法律、财务、人事或其他专业意见，重要决定请自行核对或咨询专业人士。
- **技能**：用的是和 Claude、Codex 相同的 SKILL.md 格式。
  - 自带 6 个按 Perlustra 工具定制的技能：表格分析、表格核对对账、数据分析报告、合同审阅、简历诊断与重写、会议纪要。
  - 「技能市场」里有 22 个挑过的 GitHub 技能仓库，覆盖法务、求职、公文、财务会计、论文、咨询与营销、图表和 Office 处理，一键安装。也可以粘贴任意 GitHub 链接安装。这些技能属于各自的作者，按各自的许可证提供，Perlustra 不随安装包分发、也不审核它们的内容。
  - 技能装得多时，每次请求只附上相关的几个，其余的 AI 用 `find_skills` 按需搜索。

## 使用

- **打开文件**：拖到窗口或 Dock 图标、⌘O、Finder「打开方式」、命令行 `open -a Perlustra 文件`。可在 Finder「显示简介」里设为默认打开程序。
- **同目录浏览**：← / → 切换同文件夹的上一个、下一个文件，⌃⌘S 打开文件夹侧栏。
- **信息面板**：⌘I，显示大小、时间、尺寸、时长、编码、色彩空间、EXIF 等。
- **工具栏**：在 Finder 中显示、用默认应用打开、分享、拷贝路径。
- **快捷键**：完整列表见「帮助 › 键盘快捷键」（⌘/）。
- **设置**（⌘,）：单窗口 / 多窗口、侧栏、自动换行、高亮上限、图片默认 1:1、iWork 完整预览、libmpv 路径、优先使用 mpv。

## 可选依赖

| 依赖 | 作用 | 安装 |
|---|---|---|
| mpv | 播放 MKV / AVI / WMV / FLV / RMVB / WebM / Opus 等 AVFoundation 不支持的格式 | `brew install mpv`。Perlustra 会自动在 `/opt/homebrew/lib` 和 `/usr/local/lib` 里查找 libmpv，也可以在设置中手动指定路径 |
| Pages / Keynote / Numbers | iWork 文稿的完整多页预览；PPT 全屏放映 | App Store 免费下载。第一次使用时 macOS 会弹出「自动化」权限请求，选择允许即可 |

## 首次打开（绕过 Gatekeeper）

Perlustra 使用 ad-hoc 签名，没有经过 Apple 公证，所以第一次打开时 macOS 会拦截。任选一种方式放行：

1. 在「应用程序」里**右键点 Perlustra → 打开**，在弹窗中再点「打开」。
2. 或者在「系统设置 › 隐私与安全性」底部点「仍要打开」。
3. 或者在终端执行：

```bash
xattr -dr com.apple.quarantine /Applications/Perlustra.app
```

## 隐私与安全

- **不收集任何数据**：没有统计、遥测、崩溃上报，也不检查更新。
- **没有 App Sandbox**：下载的应用是 ad-hoc 签名，没有沙盒，也没有公证。网页文件夹限制和 AI 读写限制都是程序内部的检查，不是系统沙盒。
- **什么时候联网**：只有三种情况——用 AI 对话时访问你配置的模型服务（「本地」模式只连 localhost 或 127.0.0.1）；在技能市场安装技能时从 GitHub 下载；查找本地模型时访问本机端口。看文件本身不联网，网页、Markdown、SVG 里的远程资源都会被拦住。Markdown 和本地网页能读的本地文件只限于该文件所在文件夹。
- **AI 密钥**：保存在 `~/Library/Application Support/Perlustra/ai-keys.json`，文件权限 600（只有你的账户能读写），不放进钥匙串（本地签名的应用每次更新都会被钥匙串当成新应用、反复要密码）。同一台 Mac 上以你的账户运行的其他程序也能读到这个文件，请据此判断。
- **AI 运行命令**：默认关闭；打开后每一条命令都要你点「允许」才会执行。如果这次对话里载入过技能，运行命令前会再确认一次（技能内容未经 Perlustra 审核，命令以你的账户权限执行）。
- **安全问题**请通过 GitHub Issues 联系，涉及漏洞细节时请先不要公开写出复现方法。

## 构建

只需要 Command Line Tools，不需要完整 Xcode。首次构建或测试会下载并校验固定版本的 DuckDB（1.5.4，约 34 MB 下载）；缓存后可离线构建。读取库随应用分发，用户无需安装 Python、DuckDB 或其他工具。它只在打开 Parquet 时加载，Universal 读取库会使安装体积增加约 107 MB（压缩后的安装包增量更小）：

```bash
git clone https://github.com/xiaolv-home/perlustra.git
cd perlustra
scripts/build-app.sh release     # Universal、优化、ad-hoc 签名 → build/app.noindex/Perlustra.app（.noindex：不让开发版出现在启动台/App 列表里）
```

```bash
scripts/make-dmg.sh              # → build/Perlustra-1.1.0.dmg
```

开发时用 `scripts/build-app.sh debug`，只编译本机架构，速度更快。

## 测试

```bash
python3 scripts/gen-fixtures.py        # 生成 fixtures/（中文、GBK、大文件、损坏文件、扩展名错误的文件；字体样例从本机系统字体拷贝，不入库）
```

```bash
scripts/gen-iwork-fixtures.sh          # 用本机 iWork 生成 .pages/.key/.numbers（带 Apple 主题素材，不入库）以及 pptx/xlsx
scripts/gen-chart-fixtures.py          # 用 openpyxl 生成 fixtures/office/charts.xlsx（各种图表、图片、整页图表）
scripts/gen-richtext-fixture.py        # 生成 fixtures/office/rich-text.xlsx（一格里分段的颜色/加粗/字号，共享字符串和内联两种写法）
```

```bash
scripts/test.sh                        # 单元测试（Swift Testing）：格式识别、编码、CSV、字幕、JSON、行索引、高亮、压缩包、公式引擎、表格读取与筛选
```

```bash
python3 scripts/verify-renderers.py    # 端到端：用真实应用逐个打开样例，断言渲染引擎（没生成的样例会跳过并列出）
```

提交前跑 `scripts/check.sh`，详见 [CONTRIBUTING.md](CONTRIBUTING.md)。

Parquet 样例已入库，不依赖 Python 运行测试；需要重建时安装 `pyarrow` 后运行 `python3 scripts/gen-parquet-fixtures.py`。预览不提供 SQL 执行或编辑，限于所选的本地文件。带时区的时间统一显示为 UTC，无时区时间保持原值；超长单元格最多保留 16,384 个字符并明确标注截断，复制也使用截断后的内容。加密文件及读取库尚不支持的编码（如整数的 BYTE_STREAM_SPLIT）会说明失败原因并降级查看，不当作空表；后台读取可以取消，20 秒仍未完成会停止。

调试参数（除 `--probe` 和 `--purge-recents` 外只在 debug 版可用）：
- `Perlustra --probe 文件…`：输出每个文件实际使用的渲染引擎。
- `--snapshot 目录 文件…`：对窗口截图；锁屏时自动改为离屏渲染。
- `--stress 目录 --rounds N`：循环打开文件夹内所有文件并报告内存。
- `--cmd "sheet:col:3"` 等：脚本化操作表格，并打印状态栏结果。
- 以上调试参数运行时不写入「最近打开」、侧栏位置和窗口布局，不会影响日常使用。
- `--cmd "ai:要求"`：把要求发给 AI，结束后打印它做的每一步；`aiskill:技能名` 指定技能，`aiendpoint:协议|地址|模型|key` 换成模拟服务器，`installskill:GitHub链接` 测试安装（装到临时目录），`aiattach:图片` 附图，`aihistory` / `aiopen:序号` / `aidelete:序号` / `ainew` 测历史对话（存到临时目录）。
- `Perlustra --purge-recents 目录`：从「最近打开」里删掉某个目录下的所有记录。

> 测试使用 Swift Testing 而不是 XCTest，因为 XCTest 只随完整 Xcode 提供；装有 Xcode 时 `scripts/test.sh` 会自动直接调用 `swift test`。

## 结构

```
Sources/Perlustra/          入口
Sources/PerlustraApp/       应用：窗口与外壳、渲染器、AI 面板、设计系统
Sources/PerlustraCore/      纯逻辑（可单测，不依赖界面）：格式识别、表格、公式、图表、AI 协议
Sources/PerlustraObjC/      ObjC 异常兜底（AppKit/PDFKit 抛出的异常不会拖垮主线程）
Sources/CArchive/       系统 libarchive 的最小头文件声明
Tests/                  PerlustraCoreTests、PerlustraAppTests
fixtures/               样例文件     scripts/   构建、打包、样例生成、检查
```

分层和扩展方式见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，开发规范见 [CONTRIBUTING.md](CONTRIBUTING.md)，改动记录见 [CHANGELOG.md](CHANGELOG.md)。

## 许可证

[MIT](LICENSE)。第三方库与素材的声明见 [NOTICE](NOTICE)，各库的许可证原文在 `Sources/PerlustraApp/Resources/web/vendor/licenses/`。
