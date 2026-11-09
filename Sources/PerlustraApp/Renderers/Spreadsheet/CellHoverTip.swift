import AppKit

/// The whole text of a cut-off cell, shown just below it while the pointer rests there. A small
/// window of its own: it never takes clicks or the keyboard, and appears without the window having
/// to be clicked first, unlike a system tooltip.
@MainActor
final class CellHoverTip {
    private static let delay: TimeInterval = 0.3
    private static let maxWidth: CGFloat = 420
    private static let maxLines = 14

    private let panel: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")
    private var pending: DispatchWorkItem?
    private(set) var isShown = false

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.hidesOnDeactivate = !AppEnvironment.isScripted
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let box = NSVisualEffectView()
        box.material = .toolTip
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 6
        box.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 12.5)
        label.maximumNumberOfLines = Self.maxLines
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -7),
        ])
        panel.contentView = box
    }

    /// Shows the text under a cell (a rectangle in screen coordinates). The first one waits a
    /// moment; while one is showing, moving to the next cell replaces it at once.
    func show(_ text: String, below cell: NSRect, over window: NSWindow) {
        pending?.cancel()
        if isShown {
            present(text, below: cell, over: window)
        } else {
            let work = DispatchWorkItem { [weak self] in self?.present(text, below: cell, over: window) }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
        }
    }

    func hide() {
        pending?.cancel()
        pending = nil
        guard isShown else { return }
        isShown = false
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func present(_ text: String, below cell: NSRect, over window: NSWindow) {
        // Automated runs check it from the background, where the app is never the active one.
        guard window.isVisible, NSApp.isActive || AppEnvironment.isScripted else { return }
        let shown = text.count > 1200 ? String(text.prefix(1200)) + "…" : text
        label.stringValue = shown
        panel.appearance = window.effectiveAppearance
        label.preferredMaxLayoutWidth = Self.maxWidth - 20
        let fit = label.fittingSize
        let size = NSSize(width: min(Self.maxWidth, ceil(fit.width) + 20), height: ceil(fit.height) + 14)
        let screen = window.screen?.visibleFrame ?? .infinite
        var origin = NSPoint(x: cell.minX, y: cell.minY - size.height - 4)
        if origin.y < screen.minY { origin.y = cell.maxY + 4 }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        isShown = true
    }
}
