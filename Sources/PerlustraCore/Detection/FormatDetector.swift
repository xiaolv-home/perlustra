import Foundation

/// Identifies a file's format from magic bytes, extension and content sniffing,
/// in that order of trust. Never throws: anything unreadable becomes `.binary`.
public enum FormatDetector {
    public static let headLength = 64 * 1024

    public static func detect(url: URL) -> DetectedFormat {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return detectDirectory(url)
        }
        let head = readHead(url, length: headLength)
        let tail = { readTail(url, length: 256 * 1024) }
        return detect(
            head: head, ext: url.pathExtension.lowercased(),
            name: url.lastPathComponent.lowercased(), tail: tail)
    }

    /// Pure function used by `detect(url:)` and by tests.
    public static func detect(head: Data, ext: String, name: String, tail: () -> Data = { Data() }) -> DetectedFormat {
        let byExt = formatForExtension(ext, name: name)
        if let magic = formatFromMagic(head, ext: ext, tail: tail) {
            var f = magic
            if let e = byExt, !compatible(magic: magic, ext: e, extString: ext) {
                f.extensionMismatch = true
            }
            return f
        }
        // No signature. Trust the extension for text-ish and signature-less formats,
        // but verify that "text" really looks like text.
        if var e = byExt {
            switch e.family {
            case .text, .code, .markdown, .json, .csv, .html, .svg, .plist:
                if head.isEmpty || TextSniffer.isLikelyText(head) {
                    if e.family == .plist { e.language = "xml" }
                    return e
                }
                var b = binaryFormat()
                b.extensionMismatch = true
                return b
            default:
                // Ambiguous extensions such as .ts (TypeScript vs MPEG-TS) or a PEM .key:
                // text content wins over a binary family.
                if !head.isEmpty, TextSniffer.isLikelyText(head) {
                    if let lang = ExtensionTable.language[ext] ?? (ext == "ts" || ext == "mts" ? "typescript" : nil) {
                        return DetectedFormat(
                            family: .code, token: ext.uppercased(),
                            label: "\(ExtensionTable.languageDisplayName(lang)) 源代码",
                            language: lang, source: .sniff)
                    }
                    var t = sniffText(head, ext: ext)
                    t.extensionMismatch = true
                    return t
                }
                // Signature-less binary formats (e.g. some RAW, TGA, MP3 without ID3).
                return e
            }
        }
        // Unknown extension: sniff content.
        if head.isEmpty {
            return DetectedFormat(
                family: .text, token: ext.isEmpty ? "TXT" : ext.uppercased(),
                label: "空文件", language: "plain", source: .sniff)
        }
        if TextSniffer.isLikelyText(head) {
            return sniffText(head, ext: ext)
        }
        return binaryFormat()
    }

    // MARK: - Extension mapping

    public static func formatForExtension(_ ext: String, name: String) -> DetectedFormat? {
        let T = ExtensionTable.self
        let token = ext.uppercased()
        func make(_ fam: FormatFamily, _ label: String, lang: String? = nil) -> DetectedFormat {
            DetectedFormat(family: fam, token: token, label: label, language: lang, source: .extension)
        }
        if ext.isEmpty || T.specialNames[name] != nil {
            if let lang = T.specialNames[name] {
                return DetectedFormat(
                    family: lang == "plain" ? .text : .code,
                    token: lang == "plain" ? "TXT" : lang.uppercased(),
                    label: ExtensionTable.languageDisplayName(lang) + (lang == "plain" ? "" : " 源代码"),
                    language: lang, source: .extension)
            }
            return nil
        }
        if T.pdf.contains(ext) { return make(.pdf, "PDF 文档") }
        if T.svg.contains(ext) { return make(.svg, "SVG 矢量图") }
        if T.rawImage.contains(ext) { return make(.image, "相机 RAW 图像") }
        if T.image.contains(ext) { return make(.image, "\(token) 图像") }
        if T.video.contains(ext) { return make(.video, "\(token) 视频") }
        if T.audio.contains(ext) { return make(.audio, "\(token) 音频") }
        if T.markdown.contains(ext) { return make(.markdown, "Markdown 文档", lang: "markdown") }
        if T.json.contains(ext) { return make(.json, "JSON 数据", lang: "json") }
        if T.plist.contains(ext) { return make(.plist, "属性列表", lang: "xml") }
        if T.csv.contains(ext) {
            var f = make(.csv, "CSV 表格"); f.delimiter = UInt8(ascii: ","); return f
        }
        if T.tsv.contains(ext) {
            var f = make(.csv, "TSV 表格"); f.delimiter = UInt8(ascii: "\t"); return f
        }
        if T.html.contains(ext) { return make(.html, "HTML 网页", lang: "html") }
        if T.sqlite.contains(ext) { return make(.sqlite, "SQLite 数据库") }
        if T.font.contains(ext) { return make(.font, "\(token) 字体") }
        if let k = T.iwork[ext] {
            var f = make(.iwork, "\(k.appName) 文稿"); f.iwork = k; return f
        }
        if T.office.contains(ext) { return make(.office, officeLabel(ext)) }
        if T.archive.contains(ext) { return make(.archive, "\(token) 压缩包") }
        if T.quicklook.contains(ext) { return make(.quicklook, "\(token) 文件") }
        if let lang = T.language[ext] {
            if lang == "plain" || lang == "log" {
                return make(.text, lang == "log" ? "日志文件" : "纯文本", lang: lang)
            }
            return make(.code, "\(ExtensionTable.languageDisplayName(lang)) 源代码", lang: lang)
        }
        return nil
    }

    static func officeLabel(_ ext: String) -> String {
        switch ext {
        case "doc", "docx", "docm", "dot", "dotx", "dotm", "wps": return "Word 文档"
        case "xls", "xlsx", "xlsm", "xlsb", "xlt", "xltx", "et": return "Excel 工作簿"
        case "ppt", "pptx", "pptm", "pps", "ppsx", "pot", "potx", "dps": return "PowerPoint 演示文稿"
        case "rtf", "rtfd": return "RTF 富文本"
        case "odt": return "OpenDocument 文本"
        case "ods": return "OpenDocument 表格"
        case "odp": return "OpenDocument 演示"
        default: return "Office 文档"
        }
    }

    // MARK: - Magic bytes

    static func formatFromMagic(_ d: Data, ext: String, tail: () -> Data) -> DetectedFormat? {
        let b = [UInt8](d.prefix(512))
        func at(_ off: Int, _ sig: [UInt8]) -> Bool {
            guard b.count >= off + sig.count else { return false }
            for i in 0..<sig.count where b[off + i] != sig[i] { return false }
            return true
        }
        func ascii(_ off: Int, _ s: String) -> Bool { at(off, Array(s.utf8)) }
        func m(_ fam: FormatFamily, _ token: String, _ label: String) -> DetectedFormat {
            DetectedFormat(family: fam, token: token, label: label, source: .magic)
        }

        if ascii(0, "%PDF-") { return m(.pdf, "PDF", "PDF 文档") }
        if at(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return m(.image, "PNG", "PNG 图像") }
        if at(0, [0xFF, 0xD8, 0xFF]) { return m(.image, "JPEG", "JPEG 图像") }
        if ascii(0, "GIF87a") || ascii(0, "GIF89a") { return m(.image, "GIF", "GIF 图像") }
        if ascii(0, "RIFF") && b.count >= 12 {
            if ascii(8, "WEBP") { return m(.image, "WEBP", "WebP 图像") }
            if ascii(8, "WAVE") { return m(.audio, "WAV", "WAV 音频") }
            if ascii(8, "AVI ") { return m(.video, "AVI", "AVI 视频") }
        }
        if ascii(0, "8BPS") { return m(.image, "PSD", "Photoshop 文档") }
        if at(0, [0x00, 0x00, 0x01, 0x00]) && b.count > 6 && b[4] > 0 && b[5] == 0
            && (ext == "ico" || ext == "cur" || ext.isEmpty || b[4] < 64)
        {
            // ICO: reserved 0, type 1, count < 64. Weak, so require plausible count.
            if ext == "ico" || ext == "cur" || ext.isEmpty { return m(.image, "ICO", "图标文件") }
        }
        if ascii(0, "icns") { return m(.image, "ICNS", "Apple 图标") }
        if ascii(0, "BM") && b.count > 14 && (ext == "bmp" || ext == "dib" || ext.isEmpty) {
            return m(.image, "BMP", "BMP 图像")
        }
        if at(0, [0x49, 0x49, 0x2A, 0x00]) || at(0, [0x4D, 0x4D, 0x00, 0x2A]) || at(0, [0x49, 0x49, 0x2B, 0x00]) {
            if ExtensionTable.rawImage.contains(ext) { return m(.image, ext.uppercased(), "相机 RAW 图像") }
            return m(.image, "TIFF", "TIFF 图像")
        }
        if at(0, [0x49, 0x49, 0x55, 0x00]) { return m(.image, "RW2", "相机 RAW 图像") }  // Panasonic
        if ascii(0, "FUJIFILMCCD-RAW") { return m(.image, "RAF", "相机 RAW 图像") }
        if at(0, [0x76, 0x2F, 0x31, 0x01]) { return m(.image, "EXR", "OpenEXR 图像") }
        if ascii(0, "#?RADIANCE") || ascii(0, "#?RGBE") { return m(.image, "HDR", "Radiance HDR") }
        if at(0, [0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20]) { return m(.image, "JP2", "JPEG 2000") }
        if at(0, [0xFF, 0x0A]) || at(0, [0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20]) { return m(.image, "JXL", "JPEG XL") }
        if ascii(0, "DDS ") { return m(.image, "DDS", "DDS 纹理") }

        // ISO base media (mp4/mov/heic/avif/3gp/m4a)
        if b.count >= 12 && ascii(4, "ftyp") {
            let brand = String(bytes: b[8..<12], encoding: .ascii)?.lowercased() ?? ""
            let compat = String(bytes: b[8..<min(b.count, 64)], encoding: .ascii)?.lowercased() ?? ""
            if ["heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1"].contains(brand) {
                if compat.contains("avif") { return m(.image, "AVIF", "AVIF 图像") }
                return m(.image, "HEIC", "HEIF 图像")
            }
            if brand == "avif" || brand == "avis" { return m(.image, "AVIF", "AVIF 图像") }
            if brand == "crx " { return m(.image, "CR3", "相机 RAW 图像") }
            if ["m4a ", "m4b ", "m4p ", "f4a ", "f4b "].contains(brand) || ExtensionTable.audio.contains(ext) {
                return m(.audio, ext.isEmpty ? "M4A" : ext.uppercased(), "MPEG-4 音频")
            }
            if brand == "qt  " { return m(.video, "MOV", "QuickTime 影片") }
            if brand.hasPrefix("3g") { return m(.video, "3GP", "3GP 视频") }
            return m(.video, ext.isEmpty || !ExtensionTable.video.contains(ext) ? "MP4" : ext.uppercased(), "MPEG-4 视频")
        }
        if b.count >= 8 && (ascii(4, "moov") || ascii(4, "mdat") || ascii(4, "wide") || ascii(4, "free")) && ext != "txt" {
            if ExtensionTable.video.contains(ext) || ext.isEmpty || ext == "mov" { return m(.video, "MOV", "QuickTime 影片") }
        }
        if at(0, [0x1A, 0x45, 0xDF, 0xA3]) {
            let isWebm = d.prefix(64).range(of: Data("webm".utf8)) != nil
            return isWebm
                ? m(.video, "WEBM", "WebM 视频") : (ExtensionTable.audio.contains(ext) ? m(.audio, "MKA", "Matroska 音频") : m(.video, "MKV", "Matroska 视频"))
        }
        if ascii(0, "FLV") && b.count > 3 && b[3] == 1 { return m(.video, "FLV", "Flash 视频") }
        if at(0, [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11]) {
            return ExtensionTable.audio.contains(ext) ? m(.audio, "WMA", "WMA 音频") : m(.video, "WMV", "Windows Media 视频")
        }
        if ascii(0, ".RMF") { return m(.video, "RMVB", "RealMedia 视频") }
        if at(0, [0x00, 0x00, 0x01, 0xBA]) || at(0, [0x00, 0x00, 0x01, 0xB3]) { return m(.video, "MPG", "MPEG 视频") }
        if b.count > 376 && b[0] == 0x47 && b[188] == 0x47 && b[376] == 0x47 && !TextSniffer.isLikelyText(d) { return m(.video, "TS", "MPEG-TS 视频") }
        if ascii(0, "OggS") {
            let isVideo = d.prefix(256).range(of: Data("theora".utf8)) != nil
            if isVideo { return m(.video, "OGV", "Ogg 视频") }
            let isOpus = d.prefix(256).range(of: Data("OpusHead".utf8)) != nil
            return m(.audio, isOpus ? "OPUS" : "OGG", isOpus ? "Opus 音频" : "Ogg 音频")
        }
        if ascii(0, "fLaC") { return m(.audio, "FLAC", "FLAC 无损音频") }
        if ascii(0, "ID3") { return m(.audio, "MP3", "MP3 音频") }
        if ascii(0, "FORM") && b.count >= 12 && (ascii(8, "AIFF") || ascii(8, "AIFC")) { return m(.audio, "AIFF", "AIFF 音频") }
        if ascii(0, "caff") { return m(.audio, "CAF", "Core Audio 音频") }
        if ascii(0, "MAC ") { return m(.audio, "APE", "Monkey's Audio") }
        if ascii(0, "#!AMR") { return m(.audio, "AMR", "AMR 音频") }
        if ascii(0, "MThd") { return m(.audio, "MIDI", "MIDI 音乐") }
        if ascii(0, "wvpk") { return m(.audio, "WV", "WavPack 音频") }
        if b.count > 2 && b[0] == 0xFF && (b[1] & 0xE0) == 0xE0 && ExtensionTable.audio.contains(ext) {
            return m(.audio, ext.uppercased(), "\(ext.uppercased()) 音频")
        }

        // Fonts
        if ascii(0, "wOFF") { return m(.font, "WOFF", "WOFF 字体") }
        if ascii(0, "wOF2") { return m(.font, "WOFF2", "WOFF2 字体") }
        if ascii(0, "OTTO") { return m(.font, "OTF", "OpenType 字体") }
        if ascii(0, "ttcf") { return m(.font, "TTC", "TrueType 字体集") }
        if at(0, [0x00, 0x01, 0x00, 0x00]) && b.count > 12 && looksLikeSFNT(b) { return m(.font, "TTF", "TrueType 字体") }
        if ascii(0, "true") && looksLikeSFNT(b) { return m(.font, "TTF", "TrueType 字体") }

        // Archives & containers
        if at(0, [0x50, 0x4B, 0x03, 0x04]) || at(0, [0x50, 0x4B, 0x05, 0x06]) || at(0, [0x50, 0x4B, 0x07, 0x08]) {
            return classifyZip(head: d, ext: ext, tail: tail)
        }
        if at(0, [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
            // OLE2 compound file: legacy Office (or msg/msi). Extension decides the flavour.
            if ExtensionTable.office.contains(ext) { return m(.office, ext.uppercased(), officeLabel(ext)) }
            if ext == "msi" || ext == "msg" { return m(.quicklook, ext.uppercased(), "OLE 复合文档") }
            let s = d.prefix(64 * 1024)
            if s.range(of: Data("W\0o\0r\0d\0D\0o\0c\0u\0m\0e\0n\0t".utf8)) != nil { return m(.office, "DOC", "Word 文档") }
            if s.range(of: Data("W\0o\0r\0k\0b\0o\0o\0k".utf8)) != nil { return m(.office, "XLS", "Excel 工作簿") }
            if s.range(of: Data("P\0o\0w\0e\0r\0P\0o\0i\0n\0t".utf8)) != nil { return m(.office, "PPT", "PowerPoint 演示文稿") }
            return m(.office, "DOC", "Office 文档")
        }
        if at(0, [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return m(.archive, "7Z", "7-Zip 压缩包") }
        if ascii(0, "Rar!") { return m(.archive, "RAR", "RAR 压缩包") }
        if at(0, [0x1F, 0x8B]) {
            let token = (ext == "tgz" || ext == "gz") ? ext.uppercased() : "GZ"
            if ext == "svgz" { return m(.svg, "SVGZ", "SVG 矢量图") }
            return m(.archive, token, "Gzip 压缩包")
        }
        if ascii(0, "BZh") && b.count > 3 && (0x31...0x39).contains(b[3]) { return m(.archive, "BZ2", "Bzip2 压缩包") }
        if at(0, [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return m(.archive, "XZ", "XZ 压缩包") }
        if at(0, [0x28, 0xB5, 0x2F, 0xFD]) { return m(.archive, "ZST", "Zstandard 压缩包") }
        if at(0, [0x04, 0x22, 0x4D, 0x18]) { return m(.archive, "LZ4", "LZ4 压缩包") }
        if ascii(257, "ustar") { return m(.archive, "TAR", "TAR 归档") }
        if ascii(0, "xar!") { return m(.archive, ext == "pkg" ? "PKG" : "XAR", "XAR 归档") }
        if ascii(0, "MSCF") { return m(.archive, "CAB", "CAB 压缩包") }
        if ascii(0, "!<arch>") { return m(.archive, ext == "deb" ? "DEB" : "AR", "AR 归档") }
        if at(0, [0xED, 0xAB, 0xEE, 0xDB]) { return m(.archive, "RPM", "RPM 软件包") }
        if ascii(0, "070701") || ascii(0, "070707") { return m(.archive, "CPIO", "CPIO 归档") }
        if d.count > 0x8006, let s = String(bytes: d[0x8001..<0x8006], encoding: .ascii), s == "CD001" {
            return m(.archive, "ISO", "ISO 光盘映像")
        }

        // Structured text with signatures
        if ascii(0, "bplist0") { return DetectedFormat(family: .plist, token: "PLIST", label: "二进制属性列表", language: "xml", source: .magic) }
        if ascii(0, "{\\rtf") { return m(.office, "RTF", "RTF 富文本") }
        if ascii(0, "SQLite format 3\0") { return m(.sqlite, "SQLITE", "SQLite 数据库") }

        // Text that announces itself (after BOM-stripping)
        if TextSniffer.isLikelyText(d) {
            let prefix = TextSniffer.leadingText(d, max: 1024).lowercased()
            let trimmed = prefix.drop(while: { $0.isWhitespace || $0 == "\u{feff}" })
            if trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<!doctype plist") || trimmed.hasPrefix("<plist") {
                if prefix.contains("<!doctype plist") || prefix.contains("<plist") {
                    return DetectedFormat(family: .plist, token: "PLIST", label: "属性列表", language: "xml", source: .magic)
                }
                if prefix.contains("<svg") { return m(.svg, "SVG", "SVG 矢量图") }
                if prefix.contains("<html") || prefix.contains("<!doctype html") {
                    return DetectedFormat(family: .html, token: "XHTML", label: "HTML 网页", language: "html", source: .magic)
                }
                // generic XML: let extension refine (e.g. .storyboard, .xml); default to XML code.
                if ExtensionTable.language[ext] != nil || ExtensionTable.office.contains(ext) { return nil }
                return DetectedFormat(family: .code, token: "XML", label: "XML 文档", language: "xml", source: .magic)
            }
            if trimmed.hasPrefix("<svg") { return m(.svg, "SVG", "SVG 矢量图") }
            if trimmed.hasPrefix("<!doctype html") || trimmed.hasPrefix("<html") {
                if ExtensionTable.html.contains(ext) || ext.isEmpty || !(ExtensionTable.language[ext] != nil || ExtensionTable.markdown.contains(ext)) {
                    return DetectedFormat(family: .html, token: "HTML", label: "HTML 网页", language: "html", source: .magic)
                }
            }
            if trimmed.hasPrefix("#!") {
                // Shebang only decides when the extension is not already informative.
                if ext.isEmpty || ExtensionTable.language[ext] == nil {
                    let line = trimmed.prefix(while: { $0 != "\n" })
                    let lang = shebangLanguage(String(line))
                    return DetectedFormat(
                        family: .code, token: lang.uppercased(), label: "\(ExtensionTable.languageDisplayName(lang)) 脚本", language: lang, source: .magic)
                }
            }
        }
        return nil
    }

    static func looksLikeSFNT(_ b: [UInt8]) -> Bool {
        guard b.count >= 12 else { return false }
        let numTables = Int(b[4]) << 8 | Int(b[5])
        guard numTables > 0 && numTables < 100 else { return false }
        // First table tag must be 4 printable ASCII characters.
        guard b.count >= 16 else { return false }
        return b[12..<16].allSatisfy { $0 >= 0x20 && $0 < 0x7F }
    }

    static func shebangLanguage(_ line: String) -> String {
        let l = line.lowercased()
        if l.contains("python") { return "python" }
        if l.contains("node") || l.contains("deno") || l.contains("bun") { return "javascript" }
        if l.contains("ruby") { return "ruby" }
        if l.contains("perl") { return "perl" }
        if l.contains("php") { return "php" }
        if l.contains("swift") { return "swift" }
        if l.contains("lua") { return "lua" }
        if l.contains("osascript") { return "plain" }
        return "shell"
    }

    /// Distinguish OOXML / iWork / ODF / EPUB / plain ZIP by looking at entry names.
    static func classifyZip(head: Data, ext: String, tail: () -> Data) -> DetectedFormat {
        func m(_ fam: FormatFamily, _ token: String, _ label: String) -> DetectedFormat {
            DetectedFormat(family: fam, token: token, label: label, source: .magic)
        }
        if let k = ExtensionTable.iwork[ext] {
            var f = m(.iwork, ext.uppercased(), "\(k.appName) 文稿"); f.iwork = k; return f
        }
        if ExtensionTable.office.contains(ext) { return m(.office, ext.uppercased(), officeLabel(ext)) }
        if ExtensionTable.archive.contains(ext) && !["zip"].contains(ext) { return m(.archive, ext.uppercased(), "\(ext.uppercased()) 压缩包") }

        var blob = head
        let t = tail()
        blob.append(t)
        func has(_ s: String) -> Bool { blob.range(of: Data(s.utf8)) != nil }
        if has("mimetypeapplication/epub+zip") { return m(.quicklook, "EPUB", "EPUB 电子书") }
        if has("mimetypeapplication/vnd.oasis.opendocument.text") { return m(.office, "ODT", "OpenDocument 文本") }
        if has("mimetypeapplication/vnd.oasis.opendocument.spreadsheet") { return m(.office, "ODS", "OpenDocument 表格") }
        if has("mimetypeapplication/vnd.oasis.opendocument.presentation") { return m(.office, "ODP", "OpenDocument 演示") }
        if has("word/document.xml") || has("word/_rels") { return m(.office, "DOCX", "Word 文档") }
        if has("xl/workbook.xml") || has("xl/_rels") { return m(.office, "XLSX", "Excel 工作簿") }
        if has("ppt/presentation.xml") || has("ppt/_rels") { return m(.office, "PPTX", "PowerPoint 演示文稿") }
        if has("Index/Document.iwa") || has("Index/Slide") || has("Index/Tables/") || has("Index/CalculationEngine") {
            let kind: IWorkKind =
                has("Index/Slide") || has("Index/MasterSlide")
                ? .keynote
                : (has("Index/CalculationEngine") || has("Index/Tables/") ? .numbers : .pages)
            var f = m(.iwork, kind == .keynote ? "KEY" : kind.rawValue.uppercased(), "\(kind.appName) 文稿")
            f.iwork = kind
            return f
        }
        if has("AndroidManifest.xml") { return m(.archive, "APK", "Android 安装包") }
        if has("META-INF/MANIFEST.MF") { return m(.archive, ext == "war" ? "WAR" : "JAR", "Java 归档") }
        return m(.archive, ext.isEmpty || ext == "zip" ? "ZIP" : ext.uppercased(), "ZIP 压缩包")
    }

    /// Extension and magic agree well enough not to warn.
    static func compatible(magic: DetectedFormat, ext e: DetectedFormat, extString: String) -> Bool {
        if magic.family == e.family { return true }
        let groups: [Set<FormatFamily>] = [
            [.video, .audio],
            [.text, .code, .markdown, .json, .csv, .html, .plist, .svg],
            [.archive, .office, .iwork, .quicklook],
            [.image, .svg],
        ]
        if magic.family == .pdf && ["ai", "eps"].contains(extString) { return true }  // Illustrator files are PDF
        return groups.contains { $0.contains(magic.family) && $0.contains(e.family) }
    }

    static func sniffText(_ head: Data, ext: String) -> DetectedFormat {
        let text = TextSniffer.leadingText(head, max: 16 * 1024)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = ext.isEmpty ? "TXT" : ext.uppercased()
        if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")),
            head.count < headLength, let d = trimmed.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])) != nil
        {
            return DetectedFormat(family: .json, token: "JSON", label: "JSON 数据", language: "json", source: .sniff)
        }
        if trimmed.hasPrefix("{") && (trimmed.contains("\":") || trimmed.contains("\" :")) {
            return DetectedFormat(family: .json, token: "JSON", label: "JSON 数据", language: "json", source: .sniff)
        }
        if let delim = CSVSniffer.sniffDelimiter(text) {
            return DetectedFormat(
                family: .csv, token: delim == 9 ? "TSV" : "CSV",
                label: delim == 9 ? "TSV 表格" : "CSV 表格", delimiter: delim, source: .sniff)
        }
        let mdSignals = ["\n# ", "\n## ", "\n- [ ]", "\n```", "](http", "\n* ", "\n> "]
        let hits = mdSignals.filter { ("\n" + text).contains($0) }.count
        if hits >= 2 {
            return DetectedFormat(family: .markdown, token: "MD", label: "Markdown 文档", language: "markdown", source: .sniff)
        }
        return DetectedFormat(family: .text, token: token, label: "纯文本", language: "plain", source: .sniff)
    }

    static func binaryFormat() -> DetectedFormat {
        DetectedFormat(family: .binary, token: "BIN", label: "二进制文件", source: .sniff)
    }

    // MARK: - Directories / packages

    static func detectDirectory(_ url: URL) -> DetectedFormat {
        let ext = url.pathExtension.lowercased()
        let fm = FileManager.default
        if let k = ExtensionTable.iwork[ext] {
            var f = DetectedFormat(family: .iwork, token: ext.uppercased(), label: "\(k.appName) 文稿（包）", source: .directory)
            f.iwork = k
            return f
        }
        if ext == "rtfd" { return DetectedFormat(family: .office, token: "RTFD", label: "RTFD 富文本", source: .directory) }
        if fm.fileExists(atPath: url.appendingPathComponent("Index.zip").path) {
            var f = DetectedFormat(family: .iwork, token: "IWORK", label: "iWork 文稿（包）", source: .directory)
            f.iwork = .pages
            return f
        }
        if ["app", "bundle", "framework", "plugin", "kext", "xcarchive", "photoslibrary", "fcpbundle", "logicx", "band", "playground"].contains(ext) {
            return DetectedFormat(family: .directory, token: ext.uppercased(), label: "软件包", source: .directory)
        }
        return DetectedFormat(family: .directory, token: "DIR", label: "文件夹", source: .directory)
    }

    // MARK: - IO

    public static func readHead(_ url: URL, length: Int) -> Data {
        guard let h = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? h.close() }
        return (try? h.read(upToCount: length)) ?? Data()
    }

    public static func readTail(_ url: URL, length: Int) -> Data {
        guard let h = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? h.close() }
        guard let end = try? h.seekToEnd() else { return Data() }
        let start = end > UInt64(length) ? end - UInt64(length) : 0
        try? h.seek(toOffset: start)
        return (try? h.read(upToCount: length)) ?? Data()
    }
}
