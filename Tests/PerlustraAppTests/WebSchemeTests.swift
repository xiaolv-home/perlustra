import Foundation
import Testing
@testable import PerlustraApp

@Suite("写作模式的本地资源")
struct WebSchemeTests {
    @Test("Vditor 要的 Mermaid 用应用自带的那份")
    func sharedMermaid() {
        #expect(PerlustraSchemeHandler.sharedVendorPath("/vditor/dist/js/mermaid/mermaid.min.js") == "vendor/mermaid.min.js")
    }

    @Test("Vditor 自己的文件不重定向")
    func ownFiles() {
        #expect(PerlustraSchemeHandler.sharedVendorPath("/vditor/dist/index.min.js") == "/vditor/dist/index.min.js")
    }

    @Test("本地网页数据存储标识按文件夹隔离且保持稳定")
    @MainActor
    func perFolderStoreIsolation() {
        let downloads = URL(fileURLWithPath: "/Users/test/Downloads")
        let reportDir = URL(fileURLWithPath: "/Users/test/Documents/report")
        #expect(WebFactory.storeIdentifier(forFolder: downloads) != WebFactory.storeIdentifier(forFolder: reportDir))
        #expect(WebFactory.storeIdentifier(forFolder: reportDir) == WebFactory.storeIdentifier(forFolder: reportDir))
    }

    @Test("libmpv 自定义路径拒绝临时目录、下载目录与非 libmpv 动态库名")
    func mpvLibraryTrustPolicy() throws {
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("libmpv.2.dylib")
        try Data("x".utf8).write(to: tmpFile)
        defer { try? FileManager.default.removeItem(at: tmpFile) }
        #expect(!MPVLibrary.isTrustedLibraryPath(tmpFile.path))
        #expect(!MPVLibrary.isTrustedLibraryPath("/opt/homebrew/lib/evil.dylib"))
    }
}
