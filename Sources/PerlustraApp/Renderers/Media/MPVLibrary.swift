import AppKit
import SwiftUI
import OpenGL.GL3
import PerlustraCore

// Minimal libmpv ABI (loaded with dlopen, so mpv stays optional).
struct mpv_render_param { var type: Int32; var data: UnsafeMutableRawPointer? }

struct mpv_opengl_init_params {
    var get_proc_address: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?)?
    var get_proc_address_ctx: UnsafeMutableRawPointer?
}

struct mpv_opengl_fbo { var fbo: Int32; var w: Int32; var h: Int32; var internal_format: Int32 }

struct mpv_event { var event_id: Int32; var error: Int32; var reply_userdata: UInt64; var data: UnsafeMutableRawPointer? }

struct mpv_event_property { var name: UnsafePointer<CChar>?; var format: Int32; var data: UnsafeMutableRawPointer? }

struct mpv_event_end_file { var reason: Int32; var error: Int32 }

enum MPVConst {
    static let formatFlag: Int32 = 3, formatDouble: Int32 = 5
    static let evShutdown: Int32 = 1, evEndFile: Int32 = 7, evFileLoaded: Int32 = 8, evPropertyChange: Int32 = 22, evVideoReconfig: Int32 = 17
    static let rpInvalid: Int32 = 0, rpAPIType: Int32 = 1, rpGLInit: Int32 = 2, rpFBO: Int32 = 3, rpFlipY: Int32 = 4
    static let endReasonError: Int32 = 4
}

/// Locates and binds libmpv at runtime (Homebrew on Apple Silicon or Intel, or a custom path).
enum MPVLibrary {
    typealias FnCreate = @convention(c) () -> OpaquePointer?
    typealias FnInit = @convention(c) (OpaquePointer?) -> Int32
    typealias FnSetOpt = @convention(c) (OpaquePointer?, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
    typealias FnCommand = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafePointer<CChar>?>) -> Int32
    typealias FnSetProp = @convention(c) (OpaquePointer?, UnsafePointer<CChar>, Int32, UnsafeMutableRawPointer) -> Int32
    typealias FnGetPropStr = @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    typealias FnFree = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias FnObserve = @convention(c) (OpaquePointer?, UInt64, UnsafePointer<CChar>, Int32) -> Int32
    typealias FnWaitEvent = @convention(c) (OpaquePointer?, Double) -> UnsafeMutableRawPointer?
    typealias FnWakeup = @convention(c) (OpaquePointer?, (@convention(c) (UnsafeMutableRawPointer?) -> Void)?, UnsafeMutableRawPointer?) -> Void
    typealias FnDestroy = @convention(c) (OpaquePointer?) -> Void
    typealias FnRCCreate = @convention(c) (UnsafeMutablePointer<OpaquePointer?>, OpaquePointer?, UnsafeMutableRawPointer) -> Int32
    typealias FnRCSetUpdate = @convention(c) (OpaquePointer?, (@convention(c) (UnsafeMutableRawPointer?) -> Void)?, UnsafeMutableRawPointer?) -> Void
    typealias FnRCRender = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer) -> Int32
    typealias FnRCFree = @convention(c) (OpaquePointer?) -> Void
    typealias FnErrorString = @convention(c) (Int32) -> UnsafePointer<CChar>?

    struct API {
        let create: FnCreate, initialize: FnInit, setOption: FnSetOpt, command: FnCommand, setProperty: FnSetProp
        let getPropertyString: FnGetPropStr, free: FnFree, observe: FnObserve, waitEvent: FnWaitEvent, setWakeup: FnWakeup
        let terminateDestroy: FnDestroy, rcCreate: FnRCCreate, rcSetUpdate: FnRCSetUpdate, rcRender: FnRCRender, rcFree: FnRCFree
        let errorString: FnErrorString
    }

    nonisolated(unsafe) private static var cached: (path: String, api: API)??
    private static let lock = NSLock()

    static var candidates: [String] {
        var c: [String] = []
        let custom = UserDefaults.standard.string(forKey: "mpvPath") ?? ""
        if !custom.isEmpty, isTrustedLibraryPath(custom) {
            c.append(URL(fileURLWithPath: custom).resolvingSymlinksInPath().standardizedFileURL.path)
        }
        c += [
            "/opt/homebrew/lib/libmpv.2.dylib", "/opt/homebrew/lib/libmpv.dylib", "/opt/homebrew/opt/mpv/lib/libmpv.2.dylib",
            "/usr/local/lib/libmpv.2.dylib", "/usr/local/lib/libmpv.dylib", "/usr/local/opt/mpv/lib/libmpv.2.dylib",
            "/opt/local/lib/libmpv.2.dylib",
        ]
        return c
    }

    /// Rejects untrusted dylib locations (temp folders, Downloads, hidden directories, non-mpv filenames).
    static func isTrustedLibraryPath(_ rawPath: String) -> Bool {
        let resolved = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().standardizedFileURL
        let path = resolved.path
        let name = resolved.lastPathComponent.lowercased()
        guard name.hasPrefix("libmpv"), name.hasSuffix(".dylib") else { return false }
        guard (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
        let untrustedPrefixes = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]
        if untrustedPrefixes.contains(where: { path.hasPrefix($0) }) { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path
        if FileAccessPolicy.contains(path, root: home) {
            let rel = String(path.dropFirst(home.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let parts = rel.split(separator: "/").map(String.init)
            if parts.first == "Downloads" || parts.contains(where: { $0.hasPrefix(".") }) { return false }
        }
        return true
    }

    static func load() -> (path: String, api: API)? {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        var result: (String, API)?
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            guard let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { continue }
            func sym<T>(_ name: String, _: T.Type) -> T? {
                guard let p = dlsym(h, name) else { return nil }
                return unsafeBitCast(p, to: T.self)
            }
            if let a = sym("mpv_create", FnCreate.self), let b = sym("mpv_initialize", FnInit.self),
                let c = sym("mpv_set_option_string", FnSetOpt.self), let d = sym("mpv_command", FnCommand.self),
                let e = sym("mpv_set_property", FnSetProp.self), let f = sym("mpv_get_property_string", FnGetPropStr.self),
                let g = sym("mpv_free", FnFree.self), let i = sym("mpv_observe_property", FnObserve.self),
                let j = sym("mpv_wait_event", FnWaitEvent.self), let k = sym("mpv_set_wakeup_callback", FnWakeup.self),
                let l = sym("mpv_terminate_destroy", FnDestroy.self), let m = sym("mpv_render_context_create", FnRCCreate.self),
                let n = sym("mpv_render_context_set_update_callback", FnRCSetUpdate.self),
                let o = sym("mpv_render_context_render", FnRCRender.self), let p = sym("mpv_render_context_free", FnRCFree.self),
                let q = sym("mpv_error_string", FnErrorString.self)
            {
                result = (
                    path,
                    API(
                        create: a, initialize: b, setOption: c, command: d, setProperty: e, getPropertyString: f, free: g,
                        observe: i, waitEvent: j, setWakeup: k, terminateDestroy: l, rcCreate: m, rcSetUpdate: n,
                        rcRender: o, rcFree: p, errorString: q)
                )
                break
            }
            dlclose(h)
        }
        cached = .some(result.map { (path: $0.0, api: $0.1) })
        return result.map { (path: $0.0, api: $0.1) }
    }

    static func reset() { lock.lock(); cached = nil; lock.unlock() }
    static var isAvailable: Bool { load() != nil }
    static var statusDescription: String {
        if let l = load() { return "已找到 libmpv：\(l.path)" }
        return "未检测到 libmpv（可执行 brew install mpv）"
    }

    /// The mpv command-line player next to the library, for the external-window fallback.
    static var executable: String? {
        let lib = load()?.path ?? ""
        let guesses = [
            URL(fileURLWithPath: lib).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("bin/mpv").path,
            "/opt/homebrew/bin/mpv", "/usr/local/bin/mpv", "/Applications/mpv.app/Contents/MacOS/mpv",
        ]
        return guesses.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - OpenGL layer driven by the mpv render API (same approach as IINA)

private let glFramework = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY)
/// Resolves OpenGL symbols for mpv's render context.
let getProcAddress: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { _, name in
    guard let name else { return nil }
    return dlsym(glFramework, name)
}
