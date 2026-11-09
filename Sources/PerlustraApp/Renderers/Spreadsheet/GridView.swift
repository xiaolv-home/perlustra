import AppKit
import PerlustraCore

/// What the grid asks of its owner (the spreadsheet renderer).
@MainActor
protocol GridViewOwner: AnyObject {
    var gridLayout: GridLayout { get }
    /// Paints rows × column positions into the current context, in grid coordinates.
    func gridPaint(rows: Range<Int>, colIndices: Range<Int>, dirty: NSRect)
    func gridSelect(_ rects: [GridRect], active: GridPoint, anchor: GridPoint)
    func gridSelection() -> (rects: [GridRect], active: GridPoint, anchor: GridPoint)
    func gridMenu(at point: GridPoint?) -> NSMenu?
    func gridColumnMenu(column: Int) -> NSMenu?
    func gridRowMenu(row: Int) -> NSMenu?
    func gridHeaderClicked(column: Int, extend: Bool)
    func gridHeaderPanel(column: Int, rect: NSRect, in view: NSView)
    func gridColumnHeader(_ col: Int) -> (mark: String, selected: Bool)
    func gridRowLabel(_ row: Int) -> (text: String, selected: Bool, pinned: Bool)
    var gridGutterDigits: Int { get }
    func gridResizeColumn(_ col: Int, width: CGFloat, done: Bool)
    func gridResizeRow(_ row: Int, height: CGFloat, done: Bool)
    func gridAutoFitColumn(_ col: Int)
    func gridCopy()
    func gridBeginEdit(_ p: GridPoint, typed: String?)
    func gridClearSelection()
    func gridPaste(_ text: String)
    func gridMagnify(_ factor: CGFloat, done: Bool)
    /// The merged area containing a cell, if any (keyboard moves step over it).
    func gridMergeArea(row: Int, col: Int) -> GridRect?
    /// False when the table is only for looking: keys then navigate instead of editing.
    var gridEditable: Bool { get }
    func gridAppearanceChanged()
    /// A cell's text when it is cut off where drawn (shown as a tooltip), else nil.
    func gridHoverText(_ p: GridPoint) -> String?
    func gridShowFullText(_ p: GridPoint)
}

/// The spreadsheet grid: a column header and row gutter that follow scrolling, a frozen band
/// for header rows, and the scrolling body. All cells are drawn by the owner (no cell views),
/// so merged areas, text overflowing into empty neighbours and zoom behave like a spreadsheet.
final class GridView: NSView {
    weak var owner: GridViewOwner?
    let scroll = NSScrollView()
    let body = GridPane(frozen: false)
    let frozen = GridPane(frozen: true)
    let header = GridColumnHeader()
    let gutter = GridRowGutter(frozen: false)
    let frozenGutter = GridRowGutter(frozen: true)
    let corner = GridCorner()
    static let headerHeight: CGFloat = 22
    private(set) var gutterWidth: CGFloat = 40

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var layoutInfo: GridLayout { owner?.gridLayout ?? GridLayout() }
    var scrollOffset: NSPoint { scroll.contentView.bounds.origin }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.documentView = body
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.sheet
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        // macOS 14+ no longer clips drawing to a view's bounds by default; these views paint
        // whole dirty rects, so they must clip or they cover their neighbours.
        clipsToBounds = true
        for v in [scroll, frozen, frozenGutter, gutter, header, corner] as [NSView] { v.clipsToBounds = true; addSubview(v) }
        body.clipsToBounds = true
        for p in [body, frozen] { p.grid = self }
        for g in [gutter, frozenGutter] { g.grid = self }
        header.grid = self
        corner.grid = self
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Call after the owner's layout changed (rows, columns, sizes, zoom).
    func reload() {
        let L = layoutInfo
        let digits = max(2, owner?.gridGutterDigits ?? 2)
        gutterWidth = CGFloat(digits) * 7 + 18
        body.setFrameSize(NSSize(width: max(L.width, 1), height: max(L.height - L.frozenHeight, 1)))
        layoutGrid()
        redrawAll()
        window?.invalidateCursorRects(for: header)
        window?.invalidateCursorRects(for: gutter)
        window?.invalidateCursorRects(for: frozenGutter)
    }

    override func layout() {
        super.layout()
        layoutGrid()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutGrid()
    }

    private func layoutGrid() {
        let L = layoutInfo
        let h = Self.headerHeight, gw = gutterWidth, fh = L.frozenRows > 0 ? L.frozenHeight : 0
        let w = bounds.width, H = bounds.height
        corner.frame = NSRect(x: 0, y: 0, width: gw, height: h)
        header.frame = NSRect(x: gw, y: 0, width: max(0, w - gw), height: h)
        frozenGutter.frame = NSRect(x: 0, y: h, width: gw, height: fh)
        frozen.frame = NSRect(x: gw, y: h, width: max(0, w - gw), height: fh)
        frozen.isHidden = fh == 0
        frozenGutter.isHidden = fh == 0
        gutter.frame = NSRect(x: 0, y: h + fh, width: gw, height: max(0, H - h - fh))
        scroll.frame = NSRect(x: gw, y: h + fh, width: max(0, w - gw), height: max(0, H - h - fh))
    }

    func redrawAll() {
        for v in [body, frozen, header, gutter, frozenGutter, corner] as [NSView] { v.needsDisplay = true }
    }

    /// Redraws the cells under a grid-coordinate rectangle, plus headers and gutters.
    func invalidate(_ r: NSRect) {
        let L = layoutInfo
        let rr = r.insetBy(dx: -3, dy: -3)
        body.setNeedsDisplay(rr.offsetBy(dx: 0, dy: -L.frozenHeight))
        if L.frozenRows > 0 { frozen.setNeedsDisplay(rr.offsetBy(dx: -scrollOffset.x, dy: 0)) }
        header.needsDisplay = true
        gutter.needsDisplay = true
        frozenGutter.needsDisplay = true
    }

    @objc private func scrolled() {
        endHover()
        header.needsDisplay = true
        gutter.needsDisplay = true
        if layoutInfo.frozenRows > 0 { frozen.needsDisplay = true }
        window?.invalidateCursorRects(for: header)
        window?.invalidateCursorRects(for: gutter)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        owner?.gridAppearanceChanged()
        scroll.backgroundColor = Theme.sheet
        redrawAll()
    }

    // MARK: Coordinates

    /// Grid coordinates of a window location (unclamped; the frozen band maps to the top rows).
    func gridLocation(_ windowPoint: NSPoint) -> NSPoint {
        let p = convert(windowPoint, from: nil)
        let L = layoutInfo
        let x = p.x - gutterWidth + scrollOffset.x
        let top = Self.headerHeight
        if L.frozenRows > 0 && p.y < top + L.frozenHeight { return NSPoint(x: x, y: p.y - top) }
        return NSPoint(x: x, y: p.y - top + scrollOffset.y)
    }

    func cell(at g: NSPoint) -> GridPoint? {
        let L = layoutInfo
        guard L.rowCount > 0, !L.cols.isEmpty else { return nil }
        return GridPoint(row: L.row(at: g.y), col: L.cols[L.colIndex(at: g.x)])
    }

    /// The view and local rectangle where an in-place editor for a cell goes.
    func editorHost(row: Int, col: Int) -> (NSView, NSRect)? {
        let L = layoutInfo
        guard let r = L.rect(row: row, col: col) else { return nil }
        if row < L.frozenRows { return (frozen, r.offsetBy(dx: -scrollOffset.x, dy: 0)) }
        return (body, r.offsetBy(dx: 0, dy: -L.frozenHeight))
    }

    // MARK: Hover

    private var hoverCell: GridPoint?
    private lazy var hoverTip = CellHoverTip()

    /// Shows the whole text of the cell under the pointer when that text is cut off.
    func paneHover(_ e: NSEvent, in pane: GridPane) {
        let p = cell(at: gridLocation(e.locationInWindow))
        guard p != hoverCell else { return }
        hoverCell = p
        guard let p, let window, let text = owner?.gridHoverText(p), let (host, rect) = editorHost(row: p.row, col: p.col), host === pane else {
            hoverTip.hide()
            return
        }
        hoverTip.show(text, below: window.convertToScreen(pane.convert(rect, to: nil)), over: window)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endHover() }
        super.viewWillMove(toWindow: newWindow)
    }

    #if DEBUG
        /// Moves a pretend pointer onto a cell, as the automation's hover check.
        func debugHover(row: Int, col: Int) -> NSWindow? {
            guard let window, let (host, rect) = editorHost(row: row, col: col), let pane = host as? GridPane else { return nil }
            let at = pane.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            guard
                let e = NSEvent.mouseEvent(
                    with: .mouseMoved, location: at, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
            else { return nil }
            paneHover(e, in: pane)
            return hoverTip.isShown ? window.childWindows?.first : nil
        }
        var debugHoverShown: Bool { hoverTip.isShown }
    #endif

    /// Takes the hover text away (pointer left, click, scroll or key).
    func endHover() {
        hoverCell = nil
        hoverTip.hide()
    }

    func scrollTo(row: Int, col: Int) {
        let L = layoutInfo
        guard row >= 0, row < L.rowCount else { return }
        let x: NSRect
        if let p = L.position(of: col) { x = NSRect(x: L.xs[p], y: 0, width: L.xs[p + 1] - L.xs[p], height: 0) } else { x = .zero }
        var target: NSRect
        if row < L.frozenRows {
            target = NSRect(x: x.minX, y: body.visibleRect.minY, width: x.width, height: 1)
        } else {
            target = NSRect(x: x.minX, y: L.ys[row] - L.frozenHeight, width: x.width, height: L.ys[row + 1] - L.ys[row])
        }
        if x.width == 0 { target.origin.x = body.visibleRect.minX; target.size.width = 1 }
        body.scrollToVisible(target)
    }

    /// Scrolls so that the given grid point is at the top-left of the scrolling area.
    func scrollOrigin(to p: NSPoint) {
        let L = layoutInfo
        let maxX = max(0, body.frame.width - scroll.contentView.bounds.width)
        let maxY = max(0, body.frame.height - scroll.contentView.bounds.height)
        let target = NSPoint(x: min(maxX, max(0, p.x)), y: min(maxY, max(0, p.y - L.frozenHeight)))
        scroll.contentView.scroll(to: target)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    var visibleRowCount: Int {
        let L = layoutInfo
        let vr = body.visibleRect
        return max(1, L.rows(from: vr.minY + L.frozenHeight, to: vr.maxY + L.frozenHeight).count - 1)
    }

    // MARK: Mouse

    enum TrackMode { case cells, rows, cols }

    func paneMouseDown(_ e: NSEvent) {
        window?.makeFirstResponder(self)
        guard let owner, let p = cell(at: gridLocation(e.locationInWindow)) else { return }
        if e.clickCount == 2 {
            // Editing takes the double-click when allowed; otherwise it opens the whole text.
            if owner.gridEditable { owner.gridBeginEdit(p, typed: nil) } else { owner.gridShowFullText(p) }
            return
        }
        var (rects, _, anchor) = owner.gridSelection()
        if e.modifierFlags.contains(.shift) {
            owner.gridSelect([GridRect(anchor, p)], active: p, anchor: anchor)
        } else if e.modifierFlags.contains(.command) {
            rects.append(GridRect(p, p))
            owner.gridSelect(rects, active: p, anchor: p)
        } else {
            owner.gridSelect([GridRect(p, p)], active: p, anchor: p)
        }
        track(.cells, from: e)
    }

    func selectRows(from e: NSEvent, row: Int) {
        guard let owner else { return }
        window?.makeFirstResponder(self)
        let L = layoutInfo
        guard let first = L.cols.first, let last = L.cols.last else { return }
        var (rects, _, anchor) = owner.gridSelection()
        let a = GridPoint(row: row, col: first), b = GridPoint(row: row, col: last)
        if e.modifierFlags.contains(.shift) {
            rects = [GridRect(GridPoint(row: anchor.row, col: first), b)]
        } else if e.modifierFlags.contains(.command) {
            rects.append(GridRect(a, b)); anchor = a
        } else {
            rects = [GridRect(a, b)]; anchor = a
        }
        owner.gridSelect(rects, active: a, anchor: anchor)
        track(.rows, from: e)
    }

    func selectColumns(from e: NSEvent, col: Int) {
        guard let owner else { return }
        window?.makeFirstResponder(self)
        owner.gridHeaderClicked(column: col, extend: e.modifierFlags.contains(.shift))
        track(.cols, from: e)
    }

    /// Classic tracking loop: keeps extending the selection and auto-scrolling even while the
    /// pointer rests outside the grid (periodic events), until the button is released.
    private func track(_ mode: TrackMode, from start: NSEvent) {
        guard let window else { return }
        var loc = start.locationInWindow
        NSEvent.startPeriodicEvents(afterDelay: 0.15, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        while let ev = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) {
            if ev.type == .leftMouseUp { break }
            if ev.type == .leftMouseDragged { loc = ev.locationInWindow }
            let inScroll = scroll.convert(loc, from: nil)
            if !scroll.bounds.contains(inScroll),
                let fake = NSEvent.mouseEvent(
                    with: .leftMouseDragged, location: loc, modifierFlags: [], timestamp: ev.timestamp,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            {
                body.autoscroll(with: fake)
            }
            guard let owner, let p = cell(at: gridLocation(loc)) else { continue }
            var (rects, _, anchor) = owner.gridSelection()
            let L = layoutInfo
            let rect: GridRect
            let active: GridPoint
            switch mode {
            case .cells:
                rect = GridRect(anchor, p); active = p
            case .rows:
                rect = GridRect(GridPoint(row: anchor.row, col: L.cols.first ?? 0), GridPoint(row: p.row, col: L.cols.last ?? 0))
                active = GridPoint(row: p.row, col: L.cols.first ?? 0)
            case .cols:
                rect = GridRect(GridPoint(row: 0, col: anchor.col), GridPoint(row: max(0, L.rowCount - 1), col: p.col))
                active = GridPoint(row: 0, col: p.col)
            }
            if rects.isEmpty { rects = [rect] } else if rects[rects.count - 1] == rect { continue } else { rects[rects.count - 1] = rect }
            owner.gridSelect(rects, active: active, anchor: anchor)
        }
    }

    /// Drags a column's right edge (`horizontal`) or a row's bottom edge until release.
    func trackResize(from e: NSEvent, column: Int?, row: Int?, start size: CGFloat) {
        guard let window, let owner else { return }
        let origin = e.locationInWindow
        var current = size
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        while let ev = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let d = column != nil ? ev.locationInWindow.x - origin.x : origin.y - ev.locationInWindow.y
            current = max(column != nil ? 12 : 8, size + d)
            if let c = column { owner.gridResizeColumn(c, width: current, done: ev.type == .leftMouseUp) }
            if let r = row { owner.gridResizeRow(r, height: current, done: ev.type == .leftMouseUp) }
            if ev.type == .leftMouseUp { break }
        }
    }

    func cellMenu(for event: NSEvent) -> NSMenu? {
        guard let owner else { return nil }
        let p = cell(at: gridLocation(event.locationInWindow))
        if let p {
            // Right-click outside the selection moves it, like Numbers/Excel.
            let (rects, _, _) = owner.gridSelection()
            if !rects.contains(where: { $0.contains(p.row, p.col) }) { owner.gridSelect([GridRect(p, p)], active: p, anchor: p) }
        }
        return owner.gridMenu(at: p)
    }

    override func magnify(with e: NSEvent) {
        owner?.gridMagnify(1 + e.magnification, done: e.phase == .ended || e.phase == .cancelled)
    }

    // MARK: Keyboard

    override func keyDown(with e: NSEvent) {
        endHover()
        guard let owner else { super.keyDown(with: e); return }
        let L = layoutInfo
        guard L.rowCount > 0, !L.cols.isEmpty else { super.keyDown(with: e); return }
        var (rects, active, anchor) = owner.gridSelection()
        let shift = e.modifierFlags.contains(.shift)
        let cmd = e.modifierFlags.contains(.command)
        var dr = 0, dc = 0
        switch e.keyCode {
        case 123: dc = -1
        case 124: dc = 1
        case 36, 76, 120:  // Return / Enter / F2 start editing the active cell (or move down)
            if owner.gridEditable { owner.gridBeginEdit(active, typed: nil); return }
            dr = shift ? -1 : 1
        case 49 where !owner.gridEditable && !cmd:  // Space: the active cell's whole text, like Quick Look
            owner.gridShowFullText(active)
            return
        case 51, 117:  // Delete / Forward delete clear the selection
            if owner.gridEditable { owner.gridClearSelection() }
            return
        case 125: dr = 1
        case 126: dr = -1
        case 48: dc = shift ? -1 : 1
        case 116: dr = -visibleRowCount
        case 121: dr = visibleRowCount
        default:
            // Typing a character starts editing with that character, like a spreadsheet.
            if owner.gridEditable, !cmd, !e.modifierFlags.contains(.control), let ch = e.characters, let u = ch.unicodeScalars.first,
                u.value >= 0x20, u.value != 0x7F, !(0xF700...0xF8FF).contains(u.value)
            {
                owner.gridBeginEdit(active, typed: ch)
                return
            }
            if cmd, e.charactersIgnoringModifiers == "a" { selectAll(nil); return }
            super.keyDown(with: e)
            return
        }
        // Step out of a merged area from its far edge.
        var from = active.row, pos = L.position(of: active.col) ?? 0
        if !shift, let m = owner.gridMergeArea(row: active.row, col: active.col) {
            if dr > 0 { from = m.r1 }
            if dc > 0 { pos = L.position(of: m.c1) ?? pos }
        }
        var row = from + dr, p = pos + dc
        if cmd {
            // Jump to the edge like Excel's ⌘-arrow.
            if dr < 0 { row = 0 } else if dr > 0 { row = L.rowCount - 1 }
            if dc < 0 { p = 0 } else if dc > 0 { p = L.cols.count - 1 }
        }
        row = max(0, min(L.rowCount - 1, row))
        p = max(0, min(L.cols.count - 1, p))
        let next = GridPoint(row: row, col: L.cols[p])
        // Shift extends with arrows; Shift-Tab and Shift-Return just move back.
        if shift && ![48, 36, 76, 120].contains(e.keyCode) {
            rects = [GridRect(anchor, next)]
            owner.gridSelect(rects, active: next, anchor: anchor)
        } else {
            owner.gridSelect([GridRect(next, next)], active: next, anchor: next)
        }
        scrollTo(row: next.row, col: next.col)
    }

    @objc override func selectAll(_ sender: Any?) {
        let L = layoutInfo
        guard let owner, L.rowCount > 0, let first = L.cols.first, let last = L.cols.last else { return }
        let (_, active, _) = owner.gridSelection()
        owner.gridSelect(
            [GridRect(GridPoint(row: 0, col: first), GridPoint(row: L.rowCount - 1, col: last))],
            active: active, anchor: GridPoint(row: 0, col: first))
    }

    @objc func copy(_ sender: Any?) { owner?.gridCopy() }
    @objc func paste(_ sender: Any?) {
        if let t = NSPasteboard.general.string(forType: .string) { owner?.gridPaste(t) }
    }
    @objc func delete(_ sender: Any?) { owner?.gridClearSelection() }
}

/// The scrolling body (documentView) or the frozen band of header rows. It only draws;
/// input goes to the GridView.
final class GridPane: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    let isFrozenBand: Bool
    weak var grid: GridView?

    init(frozen: Bool) {
        isFrozenBand = frozen
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    /// Grid coordinates of this view's local origin.
    var gridOrigin: NSPoint {
        guard let grid else { return .zero }
        return isFrozenBand ? NSPoint(x: grid.scrollOffset.x, y: 0) : NSPoint(x: 0, y: grid.layoutInfo.frozenHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let grid, let owner = grid.owner, let ctx = NSGraphicsContext.current?.cgContext else {
            Theme.sheet.setFill(); dirtyRect.fill(); return
        }
        let L = owner.gridLayout
        let o = gridOrigin
        let g = dirtyRect.offsetBy(dx: o.x, dy: o.y)
        var rows = L.rows(from: g.minY, to: g.maxY)
        let band = isFrozenBand ? 0..<min(L.frozenRows, L.rowCount) : min(L.frozenRows, L.rowCount)..<L.rowCount
        rows = rows.clamped(to: band)
        ctx.saveGState()
        ctx.translateBy(x: -o.x, y: -o.y)
        owner.gridPaint(rows: rows, colIndices: L.colIndices(from: g.minX, to: g.maxX), dirty: g)
        ctx.restoreGState()
        if isFrozenBand {
            // The edge of the frozen band.
            Theme.ink.withAlphaComponent(0.28).setFill()
            NSRect(x: dirtyRect.minX, y: bounds.maxY - 1, width: dirtyRect.width, height: 1).fill()
        }
    }

    override func mouseDown(with e: NSEvent) {
        grid?.endHover()
        grid?.paneMouseDown(e)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with e: NSEvent) { grid?.paneHover(e, in: self) }
    override func mouseExited(with e: NSEvent) { grid?.endHover() }
    override func menu(for event: NSEvent) -> NSMenu? { grid?.cellMenu(for: event) }
    override func magnify(with e: NSEvent) { grid?.magnify(with: e) }
    override func scrollWheel(with e: NSEvent) {
        grid?.endHover()
        if isFrozenBand { grid?.scroll.scrollWheel(with: e) } else { super.scrollWheel(with: e) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only the in-place editor keeps its own events.
        guard let v = super.hitTest(point) else { return nil }
        var p: NSView? = v
        while let x = p, x !== self { if x is CellEditor { return v }; p = x.superview }
        return self
    }
}
