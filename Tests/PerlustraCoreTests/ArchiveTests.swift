import Foundation
import Testing
@testable import PerlustraCore

@Suite("压缩与解压")
struct ArchiveOperationTests {
    @Test("路径清洗拦截 ..、反斜杠穿越和 NUL 字节，规范化前导斜杠")
    func sanitizePaths() {
        #expect(ArchivePathSafety.sanitizeRelativePath("docs/readme.md") == "docs/readme.md")
        #expect(ArchivePathSafety.sanitizeRelativePath("/leading/slash.txt") == "leading/slash.txt")
        #expect(ArchivePathSafety.sanitizeRelativePath("./a/./b.txt") == "a/b.txt")
        #expect(ArchivePathSafety.sanitizeRelativePath("win\\dir\\file.txt") == "win/dir/file.txt")
        #expect(ArchivePathSafety.sanitizeRelativePath("../escape.txt") == nil)
        #expect(ArchivePathSafety.sanitizeRelativePath("a/../../escape.txt") == nil)
        #expect(ArchivePathSafety.sanitizeRelativePath("win\\..\\escape.txt") == nil)
        #expect(ArchivePathSafety.sanitizeRelativePath("bad\0name.txt") == nil)
        #expect(ArchivePathSafety.sanitizeRelativePath("/") == nil)
    }

    @Test("目标目录下预先存在逃逸符号链接时拒绝写入")
    func rejectPreexistingSymlinkEscape() throws {
        let root = TestTemp.dir("symlink-root")
        let outside = TestTemp.dir("symlink-outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(ArchivePathSafety.safeDestination(relativePath: "escape/pwn.txt", under: root) == nil)
        #expect(ArchivePathSafety.safeDestination(relativePath: "safe/ok.txt", under: root) != nil)
    }

    @Test("防炸桌面：单一顶层目录不再套壳，零散多文件自动建同名目录，忽略 __MACOSX")
    func smartRootWrapping() {
        let singleDirEntries = [
            ArchiveEntry(path: "project/", size: 0, modified: nil, isDirectory: true, isEncrypted: false, isSymlink: false),
            ArchiveEntry(path: "project/a.txt", size: 10, modified: nil, isDirectory: false, isEncrypted: false, isSymlink: false),
            ArchiveEntry(path: "__MACOSX/._a.txt", size: 10, modified: nil, isDirectory: false, isEncrypted: false, isSymlink: false),
        ]
        #expect(ArchivePathSafety.smartRootDirectoryName(for: singleDirEntries, archiveURL: URL(fileURLWithPath: "/tmp/project.zip")) == nil)

        let looseEntries = [
            ArchiveEntry(path: "a.txt", size: 10, modified: nil, isDirectory: false, isEncrypted: false, isSymlink: false),
            ArchiveEntry(path: "b.txt", size: 10, modified: nil, isDirectory: false, isEncrypted: false, isSymlink: false),
        ]
        #expect(ArchivePathSafety.smartRootDirectoryName(for: looseEntries, archiveURL: URL(fileURLWithPath: "/tmp/报表.tar.gz")) == "报表")
    }

    @Test("ZIP 与 tar.gz 压缩解压往返：保留中文名与内容，自动跳过 .DS_Store 和符号链接")
    func compressAndExtractRoundTrip() throws {
        let work = TestTemp.dir("roundtrip")
        let src = work.appendingPathComponent("季度资料")
        let nested = src.appendingPathComponent("子目录")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let text = "犟骨头 2026 经营汇总\n第一行\n"
        try Data(text.utf8).write(to: src.appendingPathComponent("说明.txt"))
        try Data("a,b\n1,2\n".utf8).write(to: nested.appendingPathComponent("数据.csv"))
        try Data("junk".utf8).write(to: src.appendingPathComponent(".DS_Store"))
        // Symlink inside source folder should be skipped during compression.
        try FileManager.default.createSymbolicLink(
            at: src.appendingPathComponent("link.txt"),
            withDestinationURL: URL(fileURLWithPath: "/etc/hosts")
        )

        for format in ArchiveOutputFormat.allCases {
            let archiveURL = ArchiveWriter.suggestedArchiveURL(for: [src], format: format, in: work)
            let comp = try ArchiveWriter.compress(
                items: [src],
                to: archiveURL,
                options: ArchiveCompressOptions(format: format, skipMacOSJunk: true)
            )
            #expect(comp.fileCount == 2)
            #expect(comp.archiveBytes > 0)

            let outDir = work.appendingPathComponent("out-\(format.rawValue)")
            let ext = try ArchiveExtractor.extract(archiveURL: archiveURL, to: outDir)
            #expect(ext.extractedFiles == 2)
            #expect(ext.skippedUnsafe == 0)

            let readBack = try String(contentsOf: outDir.appendingPathComponent("季度资料/说明.txt"), encoding: .utf8)
            #expect(readBack == text)
            #expect(!FileManager.default.fileExists(atPath: outDir.appendingPathComponent("季度资料/.DS_Store").path))
            #expect(!FileManager.default.fileExists(atPath: outDir.appendingPathComponent("季度资料/link.txt").path))
        }
    }

    @Test("选择性解压与单文件流式预览提取")
    func selectiveAndSingleEntryExtract() throws {
        let work = TestTemp.dir("selective")
        let src = work.appendingPathComponent("pkg")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: src.appendingPathComponent("a.txt"))
        try Data("nested-data".utf8).write(to: src.appendingPathComponent("sub/b.txt"))

        let zipURL = work.appendingPathComponent("pkg.zip")
        _ = try ArchiveWriter.compress(items: [src], to: zipURL)

        let selOut = work.appendingPathComponent("sel-out")
        let res = try ArchiveExtractor.extract(
            archiveURL: zipURL,
            to: selOut,
            options: ArchiveExtractOptions(selectedPaths: ["pkg/sub/b.txt"], smartWrap: false)
        )
        #expect(res.extractedFiles == 1)
        let extracted = try String(contentsOf: selOut.appendingPathComponent("b.txt"), encoding: .utf8)
        #expect(extracted == "nested-data")

        let previewFile = work.appendingPathComponent("preview/b.txt")
        let bytes = try ArchiveExtractor.extractSingleEntryToFile(
            archiveURL: zipURL,
            entryPath: "pkg/sub/b.txt",
            destinationFile: previewFile
        )
        #expect(bytes == Int64("nested-data".utf8.count))
        #expect(try String(contentsOf: previewFile, encoding: .utf8) == "nested-data")
    }

    @Test("超出安全体积上限时中止并清理，不留残留目录")
    func zipBombBudgetGuard() throws {
        let work = TestTemp.dir("budget")
        let srcFile = work.appendingPathComponent("big.bin")
        try Data(repeating: 0x41, count: 16 * 1024).write(to: srcFile)
        let zipURL = work.appendingPathComponent("big.zip")
        _ = try ArchiveWriter.compress(items: [srcFile], to: zipURL)

        let outDir = work.appendingPathComponent("out")
        var hitLimit = false
        do {
            _ = try ArchiveExtractor.extract(
                archiveURL: zipURL,
                to: outDir,
                options: ArchiveExtractOptions(smartWrap: true, maxTotalBytes: 4 * 1024)
            )
        } catch ArchiveOperationError.sizeLimitExceeded {
            hitLimit = true
        }
        #expect(hitLimit)
        #expect(!FileManager.default.fileExists(atPath: outDir.appendingPathComponent("big").path))
    }

    @Test("压缩时重名目标自动顺延编号，绝不静默覆盖")
    func nonDestructiveNaming() throws {
        let work = TestTemp.dir("collision")
        let file = work.appendingPathComponent("report.txt")
        try Data("v1".utf8).write(to: file)

        let first = ArchiveWriter.suggestedArchiveURL(for: [file], format: .zip, in: work)
        #expect(first.lastPathComponent == "report.zip")
        _ = try ArchiveWriter.compress(items: [file], to: first)

        let second = ArchiveWriter.suggestedArchiveURL(for: [file], format: .zip, in: work)
        #expect(second.lastPathComponent == "report 2.zip")
    }
}
