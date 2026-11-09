import AppKit
import SwiftUI
import PerlustraCore

#if DEBUG
    /// Hooks for the debug harness (synthetic input, layout dumps).
    extension SpreadsheetRenderer: DebugScriptable {
        /// Window point at the centre of a grid cell (view row, sheet column) — for synthetic input tests.
        func debugWindowPoint(row: Int, col: Int) -> NSPoint? {
            grid.scrollTo(row: row, col: col)
            grid.layoutSubtreeIfNeeded()
            guard let (v, r) = grid.editorHost(row: row, col: col) else { return nil }
            return v.convert(NSPoint(x: r.midX, y: r.midY), to: nil)
        }
        var debugBottomOutside: NSPoint {
            let v = grid.scroll
            return v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.maxY + 40), to: nil)
        }
        /// Window point on the right edge of a column header / bottom edge of a row number.
        func debugEdgePoint(column c: Int) -> NSPoint? {
            guard let i = layout.position(of: c) else { return nil }
            return grid.header.convert(NSPoint(x: layout.xs[i + 1] - grid.scrollOffset.x - 1, y: GridView.headerHeight / 2), to: nil)
        }
        func debugEdgePoint(row r: Int) -> NSPoint? {
            guard r < layout.rowCount else { return nil }
            let g = r < layout.frozenRows ? grid.frozenGutter : grid.gutter
            let oy = r < layout.frozenRows ? 0 : grid.scrollOffset.y + layout.frozenHeight
            return g.convert(NSPoint(x: g.bounds.midX, y: layout.ys[r + 1] - oy - 1), to: nil)
        }
        var debugSelection: String { "rects=\(rects.map { "r\($0.r0)-\($0.r1) c\($0.c0)-\($0.c1)" }) active=\(active) scrollY=\(Int(grid.scrollOffset.y))" }

        /// Diagnostics for the debug harness (`--cmd dump`).
        func debugDump() -> String {
            let L = layout
            let widths = L.cols.prefix(8).enumerated().map { "\(Sheet.columnName($0.element))=\(Int(L.xs[$0.offset + 1] - L.xs[$0.offset]))" }.joined(
                separator: ",")
            let heights = (0..<min(8, L.rowCount)).map { "\(Int(L.ys[$0 + 1] - L.ys[$0]))" }.joined(separator: ",")
            return
                "rows=\(L.rowCount) cols=\(L.cols.count) frozen=\(L.frozenRows) zoom=\(zoom) size=\(Int(L.width))x\(Int(L.height)) widths[\(widths)] heights[\(heights)] merges=\(mergeViews.count) scroll=\(grid.scrollOffset) grid=\(grid.frame) body=\(grid.body.frame) frozen=\(grid.frozen.frame)/\(grid.frozen.isHidden) gutter=\(grid.gutter.frame) sv=\(grid.scroll.frame) win=\(grid.window != nil) address=\(address) formula=\(formulaText)"
        }

        private func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

        /// `--cmd sheet:<verb>:<args>`; prints the resulting status line.
        func debugRun(verb: String, arg: String, window: NSWindow) async {
            let r = self
            while workbookTask != nil { await pause(0.05) }
            // Each scripted step is its own undo step, as separate user actions would be.
            let um = window.undoManager
            let grouped = [
                "sort", "filter", "gt", "clear", "startrow", "startsort", "insrows", "inscols", "delrows", "delcols", "edit", "resizecol", "resizerow", "merge",
                "mergeforce", "unmerge",
            ].contains(verb)
            if grouped { um?.groupsByEvent = false; um?.beginUndoGrouping() }
            defer { if grouped { um?.endUndoGrouping() } }
            switch verb {
            case "col": r.gridHeaderClicked(column: Int(arg) ?? 0, extend: false)
            case "filter":
                let kv = arg.split(separator: "=", maxSplits: 1).map(String.init)
                r.setFilter(.values([kv[1]]), column: Int(kv[0]) ?? 0)
            case "gt":
                let kv = arg.split(separator: ">", maxSplits: 1).map(String.init)
                r.setFilter(.greater(Double(kv[1]) ?? 0), column: Int(kv[0]) ?? 0)
            case "sort":
                let kv = arg.split(separator: ",").map(String.init)
                r.sort(column: Int(kv[0]) ?? 0, ascending: kv.count < 2 || kv[1] != "desc")
            case "clear": r.clearFilters()
            case "startrow": r.startData(atSheetRow: Int(arg) ?? 0)
            case "startsort":
                let kv = arg.split(separator: ",").map(String.init)
                r.sort(fromSheetRow: Int(kv[0]) ?? 0, column: Int(kv[1]) ?? 0, ascending: kv.count < 3 || kv[2] != "desc")
            case "hover":
                let rc = arg.split(separator: ",").compactMap { Int($0) }
                _ = r.grid.debugHover(row: rc.first ?? 0, col: rc.count > 1 ? rc[1] : 0)
                print("SHEET hover now", r.grid.debugHoverShown)
                await pause(0.5)
                print("SHEET hover after", r.grid.debugHoverShown)
                if rc.count > 2, let tip = window.childWindows?.first(where: { $0 is NSPanel }) {
                    let shot = Process()
                    shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    shot.arguments = ["-x", "-o", "-l", "\(tip.windowNumber)", NSTemporaryDirectory() + "perlustra-hover.png"]
                    try? shot.run()
                    shot.waitUntilExit()
                    print("SHEET hovershot tip=\(tip.frame) window=\(window.frame)")
                }
            case "fulltext":
                let rc = arg.split(separator: ",").compactMap { Int($0) }
                let p = GridPoint(row: rc.first ?? 0, col: rc.count > 1 ? rc[1] : 0)
                print("SHEET hover", r.gridHoverText(p).map { "\($0.count) 字" } ?? "不截断")
                r.gridShowFullText(p)
                await pause(0.6)
                print("SHEET panel", r.cellTextPanel?.isShown ?? false)
                if rc.count > 2, let w = r.cellTextPanel?.contentViewController?.view.window {
                    let shot = Process()
                    shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    shot.arguments = ["-x", "-o", "-l", "\(w.windowNumber)", NSTemporaryDirectory() + "perlustra-cell-panel.png"]
                    try? shot.run()
                    shot.waitUntilExit()
                    print("SHEET panelshot", NSTemporaryDirectory() + "perlustra-cell-panel.png")
                }
            case "rows":
                print(
                    "SHEET rows",
                    r.visible.prefix(Int(arg) ?? 8).map { row in
                        "\(row + 1):" + (0..<r.sheet.columnCount).map { r.sheet.cell(row, $0).display }.joined(separator: "|")
                    })
            case "formula", "calc": r.calcText = arg; r.calculate(); await pause(0.8); print("SHEET result", r.resultText)
            case "fill": r.calcText = arg; r.fillComputedColumn(); await pause(1.5)
            case "search": r.searchText = arg; r.runSearch(); print("SHEET search", r.searchInfo, r.address)
            case "tab": r.switchSheet(Int(arg) ?? 0)
            case "hiddensheets": r.setShowHiddenSheets(arg == "on")
            case "tabs":
                print(
                    "SHEET tabs", r.tabSheets.map { r.workbook.sheets[$0].name + (r.workbook.sheets[$0].isHidden ? "(隐)" : "") }, "current", r.sheet.name,
                    "hidden", r.hiddenSheetCount)
            case "hidecol": r.hideColumns([Int(arg) ?? 0])
            case "hiderows": r.hideSelectedRows()
            case "header": r.setHeaderRow(arg == "on")
            case "drag", "dragout", "click", "shiftclick", "cmdclick":
                // Synthetic mouse input through the real event path (hitTest → mouseDown → tracking loop).
                let w = window
                let n = arg.split(separator: ",").compactMap { Int($0) }
                guard n.count >= 2, let start = r.debugWindowPoint(row: n[0], col: n[1]) else { print("SHEET bad drag arg"); break }
                var path: [NSPoint] = []
                if verb == "drag", n.count == 4, let end = r.debugWindowPoint(row: n[2], col: n[3]) {
                    _ = r.debugWindowPoint(row: n[0], col: n[1])
                    for i in 1...8 { path.append(NSPoint(x: start.x + (end.x - start.x) * CGFloat(i) / 8, y: start.y + (end.y - start.y) * CGFloat(i) / 8)) }
                } else if verb.hasSuffix("click") {
                    path = [NSPoint(x: start.x + 2, y: start.y - 1)]  // a real click wobbles a little
                } else if verb == "dragout" {
                    let out = r.debugBottomOutside
                    path = Array(repeating: out, count: 40)  // pointer held below the grid
                }
                func ev(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
                    NSEvent.mouseEvent(
                        with: t, location: p, modifierFlags: verb == "shiftclick" ? .shift : verb == "cmdclick" ? .command : [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                }
                for p in path { if let e = ev(.leftMouseDragged, p) { NSApp.postEvent(e, atStart: false) } }
                if let e = ev(.leftMouseUp, path.last ?? start) { NSApp.postEvent(e, atStart: false) }
                if let down = ev(.leftMouseDown, start) { w.sendEvent(down) }
                print("SHEET \(verb) result", r.debugSelection)
            case "edit":
                let kv = arg.split(separator: "=", maxSplits: 1).map(String.init)
                let rc = kv[0].split(separator: ",").compactMap { Int($0) }
                r.writeCell(row: rc[0], col: rc[1], input: kv.count > 1 ? kv[1] : "")
            case "begin":
                let rc = arg.split(separator: ",").compactMap { Int($0) }
                r.gridBeginEdit(GridPoint(row: rc[0], col: rc[1]), typed: rc.count > 2 ? "8" : nil)
            case "select":
                let n = arg.split(separator: ",").compactMap { Int($0) }
                if n.count == 4 {
                    r.gridSelect(
                        [GridRect(GridPoint(row: n[0], col: n[1]), GridPoint(row: n[2], col: n[3]))], active: GridPoint(row: n[0], col: n[1]),
                        anchor: GridPoint(row: n[0], col: n[1]))
                }
            case "cell":
                let n = arg.split(separator: ",").compactMap { Int($0) }
                if n.count == 2 {
                    print(
                        "SHEET cell", Sheet.columnName(n[1]) + "\(n[0] + 1)", "=", r.sheet.cell(n[0], n[1]).display, "cols", r.sheet.columnCount, "rows",
                        r.sheet.rows.count)
                }
            case "zoom": r.setZoom(CGFloat(Double(arg) ?? 100) / 100)
            case "insrows": r.insertRows(below: arg == "below")
            case "inscols": r.insertColumns(right: arg == "right")
            case "delrows": r.deleteSelectedRows()
            case "delcols": r.deleteSelectedColumns()
            case "enter": r.runSearch(backwards: arg == "back"); print("SHEET search", r.searchInfo, r.address)
            case "resizecol", "resizerow":
                // Drag a column's right edge / a row's bottom edge by N points through real events.
                let w = window
                let n = arg.split(separator: ",").compactMap { Int($0) }
                guard n.count == 2, let start = verb == "resizecol" ? r.debugEdgePoint(column: n[0]) : r.debugEdgePoint(row: n[0]) else {
                    print("SHEET bad resize arg"); break
                }
                let end = verb == "resizecol" ? NSPoint(x: start.x + CGFloat(n[1]), y: start.y) : NSPoint(x: start.x, y: start.y - CGFloat(n[1]))
                func ev(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
                    NSEvent.mouseEvent(
                        with: t, location: p, modifierFlags: verb == "shiftclick" ? .shift : verb == "cmdclick" ? .command : [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                }
                for i in 1...6 {
                    if let e = ev(.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * CGFloat(i) / 6, y: start.y + (end.y - start.y) * CGFloat(i) / 6))
                    {
                        NSApp.postEvent(e, atStart: false)
                    }
                }
                if let e = ev(.leftMouseUp, end) { NSApp.postEvent(e, atStart: false) }
                if let down = ev(.leftMouseDown, start) { w.sendEvent(down) }
                print("DUMP", r.debugDump())
            case "fxpanel":
                // Renders the ƒx panel (normally a popover) to an image.
                let v = NSHostingView(rootView: FunctionPanel(insert: { _, _ in }).background(Color(nsColor: Theme.sheet)))
                v.frame = NSRect(x: 0, y: 0, width: 631, height: 430)
                v.appearance = window.effectiveAppearance
                v.layoutSubtreeIfNeeded()
                if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
                }
            case "insertsel": r.insertSelectionReference(); print("SHEET calc", r.calcText)
            case "keys":
                // Plain key presses on the grid ("down", "x", "delete", "return").
                let code: UInt16 = ["down": 125, "up": 126, "left": 123, "right": 124, "return": 36, "delete": 51][arg] ?? 0
                let ch = ["down": "\u{F701}", "up": "\u{F700}", "left": "\u{F702}", "right": "\u{F703}", "return": "\r", "delete": "\u{7F}"][arg] ?? arg
                if let e = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch,
                    isARepeat: false, keyCode: code)
                {
                    window.makeFirstResponder(r.grid)
                    r.grid.keyDown(with: e)
                }
            case "merge": r.mergeSelection()
            case "mergeforce": if let m = r.selectedSheetRange { r.commitMerge(m) }
            case "type": r.formulaText = arg
            case "unmerge": r.unmergeSelection()
            case "qltree": print(debugOriginalTree())
            case "qljs": print("QLJS", await (originalView as? OriginalPreview)?.evaluate(arg) ?? "no preview")
            case "qlzoom": originalZoom = CGFloat(Double(arg) ?? 100) / 100
            // The action the 撤销 menu item sends, so the menu's route is what gets tested.
            case "undo": window.perform(Selector(("undo:")), with: nil)
            case "redo": window.perform(Selector(("redo:")), with: nil)
            case "save": r.save { ok in print("SHEET saved", ok) }; await pause(1.5)
            case "saveas": r.write(to: URL(fileURLWithPath: arg)) { ok in print("SHEET savedAs", ok) }; await pause(1.5)
            default: print("SHEET unknown verb", verb)
            }
            print("SHEET \(verb) →", r.statusText, "| addr", r.address, "| formula", r.formulaText)
        }

        /// Class tree of the Quick Look "原样" view (to find its web view).
        func debugOriginalTree() -> String {
            var out = ""
            func walk(_ v: NSView, _ d: Int) {
                out += String(repeating: "  ", count: d) + "\(type(of: v)) \(v.frame)\n"
                if d < 14 { for s in v.subviews { walk(s, d + 1) } }
            }
            if let o = originalView { walk(o, 0) }
            return out
        }

        func debugImages(to prefix: String) {
            for (name, v) in [("frozen", grid.frozen), ("body", grid.body), ("gutter", grid.gutter), ("grid", grid)] as [(String, NSView)] {
                guard v.bounds.width > 0, v.bounds.height > 0, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: prefix + "-\(name).png"))
            }
        }
    }
#endif
