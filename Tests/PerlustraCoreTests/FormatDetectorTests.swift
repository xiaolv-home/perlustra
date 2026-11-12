import Testing
import Foundation
@testable import PerlustraCore

/// Format identification: magic bytes beat extensions, extensions decide signature-less text.
@Suite("格式识别")
struct FormatDetectorTests {
    func detect(_ bytes: [UInt8], _ name: String) -> DetectedFormat {
        let ext = (name as NSString).pathExtension.lowercased()
        return FormatDetector.detect(head: Data(bytes), ext: ext, name: name.lowercased())
    }
    func detect(_ text: String, _ name: String) -> DetectedFormat { detect(Array(text.utf8), name) }

    @Test(
        "常见二进制签名",
        arguments: [
            ([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31], FormatFamily.pdf, "PDF"),
            ([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], .image, "PNG"),
            ([0xFF, 0xD8, 0xFF, 0xE0], .image, "JPEG"),
            (Array("GIF89a".utf8), .image, "GIF"),
            ([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], .archive, "7Z"),
            (Array("Rar!\u{1A}\u{07}".utf8), .archive, "RAR"),
            ([0x1A, 0x45, 0xDF, 0xA3, 0, 0, 0], .video, "MKV"),
            (Array("fLaC".utf8), .audio, "FLAC"),
            (Array("ID3".utf8), .audio, "MP3"),
            (Array("wOF2".utf8), .font, "WOFF2"),
            (Array("bplist00".utf8), .plist, "PLIST"),
            (Array("8BPS".utf8), .image, "PSD"),
            (Array("SQLite format 3\0".utf8), .sqlite, "SQLITE"),
            (Array("PAR1".utf8), .parquet, "PARQUET"),
            (Array("PARE".utf8), .parquet, "PARQUET"),
        ] as [([UInt8], FormatFamily, String)])
    func magic(bytes: [UInt8], family: FormatFamily, token: String) {
        let f = detect(bytes + [UInt8](repeating: 0, count: 32), "file")
        #expect(f.family == family)
        #expect(f.token == token)
        #expect(f.source == .magic)
    }

    @Test("ISO 媒体 brand 区分 HEIC / AVIF / MP4 / M4A")
    func isoBrands() {
        func ftyp(_ brand: String) -> [UInt8] { [0, 0, 0, 0x18] + Array("ftyp\(brand)".utf8) + [0, 0, 0, 0] + Array("mif1".utf8) }
        #expect(detect(ftyp("heic"), "a.heic").token == "HEIC")
        #expect(detect(ftyp("avif"), "a.avif").token == "AVIF")
        #expect(detect(ftyp("isom"), "a.mp4").family == .video)
        #expect(detect(ftyp("M4A "), "a.m4a").family == .audio)
        #expect(detect(ftyp("qt  "), "a.mov").token == "MOV")
    }

    @Test("扩展名错误时以内容为准并标记")
    func mismatch() {
        let parquet = detect("PAR1" + String(repeating: "\0", count: 32), "data.txt")
        #expect(parquet.family == .parquet && parquet.extensionMismatch)
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0, count: 40)
        let f = detect(png, "photo.txt")
        #expect(f.family == .image)
        #expect(f.extensionMismatch)
        let pdf = detect("%PDF-1.7\n", "scan.jpg")
        #expect(pdf.family == .pdf)
        #expect(pdf.extensionMismatch)
    }

    @Test("无扩展名的文本内容嗅探")
    func sniffing() {
        #expect(detect("{\"a\": [1, 2, 3]}", "data").family == .json)
        #expect(detect("id,name,value\n1,a,2\n2,b,3\n", "export").family == .csv)
        #expect(detect("#!/usr/bin/env python3\nprint(1)\n", "tool").language == "python")
        #expect(detect("# 标题\n\n## 小节\n\n- [ ] 任务\n", "notes").family == .markdown)
        #expect(detect("just some words\n", "LICENSE").family == .text)
    }

    @Test("歧义扩展名：.ts 既可能是 TypeScript 也可能是 MPEG-TS")
    func tsAmbiguity() {
        #expect(detect("export const x: number = 1;\n", "main.ts").language == "typescript")
        var ts = [UInt8](repeating: 0xFF, count: 600)
        ts[0] = 0x47; ts[188] = 0x47; ts[376] = 0x47; ts[1] = 0x00
        #expect(detect(ts, "clip.ts").family == .video)
    }

    @Test("ZIP 容器按内部条目细分")
    func zipFlavours() {
        let header: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        #expect(detect(header + Array("....[Content_Types].xml word/document.xml".utf8), "x").token == "DOCX")
        #expect(detect(header + Array("....xl/workbook.xml".utf8), "x").token == "XLSX")
        #expect(detect(header + Array("....ppt/presentation.xml".utf8), "x").token == "PPTX")
        #expect(detect(header + Array("....Index/Document.iwa".utf8), "x").family == .iwork)
        #expect(detect(header + Array("....mimetypeapplication/epub+zip".utf8), "x").token == "EPUB")
        #expect(detect(header + Array("....readme.txt".utf8), "x").token == "ZIP")
    }

    @Test("文本扩展名但内容是二进制时降级为二进制")
    func binaryDisguisedAsText() {
        var bytes = [UInt8](repeating: 0, count: 200)
        for i in 0..<200 { bytes[i] = UInt8(i % 7) }
        let f = detect(bytes, "notes.txt")
        #expect(f.family == .binary)
        #expect(f.extensionMismatch)
    }

    @Test("代码语言按扩展名与特殊文件名识别")
    func languages() {
        #expect(detect("let x = 1\n", "a.swift").language == "swift")
        #expect(detect("fn main() {}\n", "lib.rs").language == "rust")
        #expect(detect("all:\n\tmake\n", "Makefile").language == "makefile")
        #expect(detect("FROM alpine\n", "Dockerfile").language == "dockerfile")
        #expect(detect("a: 1\n", "c.yml").language == "yaml")
    }

    @Test("空文件按文本处理")
    func empty() {
        #expect(detect([UInt8](), "x.unknown").family == .text)
    }
}
