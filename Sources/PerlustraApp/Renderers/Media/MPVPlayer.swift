import AppKit
import SwiftUI
import OpenGL.GL3
import PerlustraCore

/// Retained C-callback trampoline whose lifetime extends until `mpv_terminate_destroy` completes,
/// preventing Use-After-Free if libmpv invokes a wakeup or render callback during teardown.
private final class MPVCallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var player: MPVPlayer?

    init(player: MPVPlayer) {
        self.player = player
    }

    func currentPlayer() -> MPVPlayer? {
        lock.lock()
        defer { lock.unlock() }
        return player
    }

    func detach() {
        lock.lock()
        player = nil
        lock.unlock()
    }
}

/// One libmpv instance. Events are drained on a private queue and forwarded to the model on main.
final class MPVPlayer: @unchecked Sendable {
    let api: MPVLibrary.API
    private let stateLock = NSLock()
    private var _handle: OpaquePointer?
    private var _destroyed = false
    private(set) var renderContext: OpaquePointer?
    private let queue = DispatchQueue(label: "perlustra.mpv.events")
    private var callbackPtr: UnsafeMutableRawPointer?
    weak var layer: MPVGLLayer?
    var onEvent: ((String, Any?) -> Void)?
    var onEndFile: ((Bool) -> Void)?
    var onLoaded: (() -> Void)?
    var onRenderFailure: (() -> Void)?

    var handle: OpaquePointer? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _destroyed ? nil : _handle
    }

    init?(api: MPVLibrary.API) {
        self.api = api
        guard let h = api.create() else { return nil }
        _handle = h
        let opts: [(String, String)] = [
            ("vo", "libmpv"), ("hwdec", "auto-safe"), ("keep-open", "yes"), ("idle", "yes"),
            ("input-default-bindings", "no"), ("input-vo-keyboard", "no"), ("osc", "no"), ("terminal", "no"),
            ("config", "no"), ("load-scripts", "no"), ("ytdl", "no"), ("audio-display", "no"),
            ("sub-auto", "fuzzy"), ("sub-font-size", "44"), ("sub-border-size", "2.5"), ("sub-codepage", "auto"),
            ("screenshot-format", "png"), ("demuxer-max-bytes", "150MiB"), ("cache", "no"),
            ("profile", "high-quality"),
            ("target-prim", "display-p3"), ("target-trc", "srgb"),
        ]
        for (k, v) in opts { _ = api.setOption(h, k, v) }
        guard api.initialize(h) >= 0 else { api.terminateDestroy(h); return nil }
        for (i, name) in ["time-pos", "duration", "pause", "volume", "speed", "eof-reached"].enumerated() {
            let fmt = (name == "pause" || name == "eof-reached") ? MPVConst.formatFlag : MPVConst.formatDouble
            _ = api.observe(h, UInt64(i + 1), name, fmt)
        }
        let box = MPVCallbackBox(player: self)
        let retainedPtr = Unmanaged.passRetained(box).toOpaque()
        callbackPtr = retainedPtr
        api.setWakeup(
            h,
            { ctx in
                guard let ctx else { return }
                let box = Unmanaged<MPVCallbackBox>.fromOpaque(ctx).takeUnretainedValue()
                guard let me = box.currentPlayer() else { return }
                me.queue.async { [weak me] in me?.drain() }
            }, retainedPtr)
    }

    func createRenderContext() {
        guard renderContext == nil, let h = handle, let ctx = layer?.cglContext, let cbPtr = callbackPtr else { return }
        CGLSetCurrentContext(ctx)
        var initParams = mpv_opengl_init_params(get_proc_address: getProcAddress, get_proc_address_ctx: nil)
        let apiType = strdup("opengl")
        defer { free(apiType) }
        var rc: OpaquePointer?
        let r: Int32 = withUnsafeMutablePointer(to: &initParams) { ip in
            var params = [
                mpv_render_param(type: MPVConst.rpAPIType, data: UnsafeMutableRawPointer(apiType)),
                mpv_render_param(type: MPVConst.rpGLInit, data: UnsafeMutableRawPointer(ip)),
                mpv_render_param(type: MPVConst.rpInvalid, data: nil),
            ]
            return params.withUnsafeMutableBufferPointer { api.rcCreate(&rc, h, UnsafeMutableRawPointer($0.baseAddress!)) }
        }
        guard r >= 0, let rc else { return }
        renderContext = rc
        api.rcSetUpdate(
            rc,
            { ctx in
                guard let ctx else { return }
                let box = Unmanaged<MPVCallbackBox>.fromOpaque(ctx).takeUnretainedValue()
                guard let me = box.currentPlayer() else { return }
                DispatchQueue.main.async { [weak me] in me?.layer?.setNeedsDisplay() }
            }, cbPtr)
    }

    func command(_ args: [String]) {
        guard let h = handle else { return }
        var cargs = args.map { UnsafePointer<CChar>(strdup($0)) }
        cargs.append(nil)
        defer { cargs.forEach { if let p = $0 { free(UnsafeMutablePointer(mutating: p)) } } }
        _ = cargs.withUnsafeMutableBufferPointer { api.command(h, $0.baseAddress!) }
    }

    func set(_ name: String, double v: Double) {
        guard let h = handle else { return }
        var x = v
        _ = api.setProperty(h, name, MPVConst.formatDouble, &x)
    }

    func set(_ name: String, flag: Bool) {
        guard let h = handle else { return }
        var x: Int32 = flag ? 1 : 0
        _ = api.setProperty(h, name, MPVConst.formatFlag, &x)
    }

    func string(_ name: String) -> String? {
        guard let h = handle, let p = api.getPropertyString(h, name) else { return nil }
        defer { api.free(p) }
        return String(cString: p)
    }

    private func drain() {
        while let h = handle, let raw = api.waitEvent(h, 0) {
            let ev = raw.assumingMemoryBound(to: mpv_event.self)
            let id = ev.pointee.event_id
            if id == 0 { break }
            switch id {
            case MPVConst.evShutdown: return
            case MPVConst.evPropertyChange:
                guard let d = ev.pointee.data else { continue }
                let p = d.assumingMemoryBound(to: mpv_event_property.self).pointee
                guard let n = p.name.map({ String(cString: $0) }) else { continue }
                var value: Any?
                if let data = p.data {
                    if p.format == MPVConst.formatDouble {
                        value = data.assumingMemoryBound(to: Double.self).pointee
                    } else if p.format == MPVConst.formatFlag {
                        value = data.assumingMemoryBound(to: Int32.self).pointee != 0
                    }
                }
                DispatchQueue.main.async { [weak self] in self?.onEvent?(n, value) }
            case MPVConst.evVideoReconfig:
                DispatchQueue.main.async { [weak self] in self?.onEvent?("video-reconfig", nil) }
            case MPVConst.evFileLoaded:
                DispatchQueue.main.async { [weak self] in self?.onLoaded?() }
            case MPVConst.evEndFile:
                var failed = false
                if let d = ev.pointee.data {
                    let e = d.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                    failed = e.reason == MPVConst.endReasonError
                }
                DispatchQueue.main.async { [weak self] in self?.onEndFile?(failed) }
            default: break
            }
        }
    }

    /// Frees the render context (with the GL context current) before destroying mpv.
    func destroy() {
        stateLock.lock()
        guard !_destroyed else { stateLock.unlock(); return }
        _destroyed = true
        let h = _handle
        _handle = nil
        let cbPtr = callbackPtr
        callbackPtr = nil
        stateLock.unlock()

        if let cbPtr {
            Unmanaged<MPVCallbackBox>.fromOpaque(cbPtr).takeUnretainedValue().detach()
        }
        if let h { api.setWakeup(h, nil, nil) }
        if let rc = renderContext {
            api.rcSetUpdate(rc, nil, nil)
            if let ctx = layer?.cglContext { CGLSetCurrentContext(ctx) }
            api.rcFree(rc)
            renderContext = nil
        }
        let api = self.api
        queue.async {
            if let h { api.terminateDestroy(h) }
            if let cbPtr { Unmanaged<MPVCallbackBox>.fromOpaque(cbPtr).release() }
        }
    }
}
