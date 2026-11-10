import Foundation

/// An Office chart (DrawingML `chartSpace`) as written in the file: where each series takes
/// its numbers from and the copy the writer cached. Not tied to the table model — a sheet,
/// a Word or a PowerPoint chart all read into this; `resolved(using:)` then fills in the data.
public struct ChartSpec: Sendable {
    public var title: ChartText?
    /// Excel names a lone-series chart after the series unless the title was deleted.
    public var autoTitleDeleted = false
    public var plots: [ChartPlot] = []
    public var axes: [ChartAxis] = []
    public var legend: ChartLegend?
    public var background: RGBA?
    public var plotBackground: RGBA?
    /// Empty cells: gap (default), zero, or a line drawn across (span).
    public var displayBlanksAs = "gap"
    /// The document's theme, for series that leave their colour to it.
    public var theme = DrawingTheme.office
    /// Excel's built-in chart style (`c:style`, 1–48). It picks the colours of series that
    /// carry no fill of their own — openpyxl charts rely on it entirely.
    public var style: Int?

    public init() {}

    /// The colour Excel gives series `index` of `count` when the file leaves it to the style.
    /// Styles come in rows of eight: grey, the six accents in turn, then one accent per style,
    /// spread from darker to lighter across the series.
    public func seriesColor(_ index: Int, of count: Int) -> RGBA {
        guard let style, (1...48).contains(style) else { return theme.seriesColor(index) }
        let column = (style - 1) % 8
        if column == 1 { return theme.seriesColor(index) }
        let base = column == 0 ? RGBA(r: 128, g: 128, b: 128) : theme.seriesColor(column - 2)
        guard count > 1 else { return base }
        // Same spread as Excel: −70 % (shade) … +70 % (tint), evenly over the series.
        let t = Double(index % count + 1) / Double(count + 1) * 1.4 - 0.7
        return t < 0 ? base.linearShade(1 + t) : base.linearTint(1 - t)
    }
}

/// Text that is either written out or taken from a cell.
public struct ChartText: Sendable, Equatable {
    public var text: String?
    public var reference: String?
    public var size: Double?
    public var bold: Bool?
    public var color: RGBA?
    public init(text: String? = nil, reference: String? = nil) { self.text = text; self.reference = reference }
}

public enum ChartKind: String, Sendable {
    case bar, line, area, pie, doughnut, scatter, radar, bubble
}

public struct ChartPlot: Sendable {
    public var kind: ChartKind
    /// Bars running left to right (`barDir="bar"`) instead of columns.
    public var horizontal = false
    /// standard, clustered, stacked or percentStacked.
    public var grouping = "clustered"
    public var axisIDs: [String] = []
    public var varyColors = false
    public var gapWidth: Double = 150
    public var overlap: Double = 0
    public var holeSize: Double = 50
    public var firstSliceAngle: Double = 0
    /// Line and scatter: draw point markers unless the series turns them off.
    public var markers = true
    /// Scatter: join the points with lines (every scatter style except "marker").
    public var scatterLines = true
    public var radarFilled = false
    public var labels = ChartLabels()
    public var series: [ChartSeries] = []
    public init(kind: ChartKind) { self.kind = kind }

    public var isStacked: Bool { grouping == "stacked" || grouping == "percentStacked" }
    public var isPercent: Bool { grouping == "percentStacked" }
}

/// Which data labels to show (`dLbls`).
public struct ChartLabels: Sendable, Equatable {
    public var value = false
    public var percent = false
    public var category = false
    public var seriesName = false
    public var numberFormat: String?
    public var position: String?
    /// The label's own text style (`txPr`), if it has one.
    public var fontSize: Double?
    public var bold: Bool?
    public var color: RGBA?
    /// Labels set on single points (`dLbl`). They replace the series' setting for that point, in
    /// either direction: Excel and WPS write "only these points" as off, plus these.
    public var points: [Int: ChartLabels] = [:]
    public init() {}
    public var any: Bool { value || percent || category || seriesName }
    public var anyAtAll: Bool { any || points.values.contains(where: \.any) }
    /// What applies to one point.
    public func at(_ index: Int) -> ChartLabels { points[index] ?? self }
}

public struct ChartSeries: Sendable {
    public var name: ChartText?
    /// Category labels (`cat`), or the x values of a scatter / bubble series (`xVal`).
    public var categories: ChartValues?
    public var values: ChartValues?
    public var bubbleSizes: ChartValues?
    public var fill: RGBA?
    public var noFill = false
    public var line: RGBA?
    public var lineWidth: Double?
    public var noLine = false
    public var dashed = false
    public var marker: String?
    public var markerSize: Double?
    public var smooth = false
    public var pointColors: [Int: RGBA] = [:]
    public var labels: ChartLabels?
    public init() {}
}

/// A reference to cells plus the copy of their values the writer stored (`numCache` /
/// `strCache`), which can be missing — openpyxl and other scripts never write it.
public struct ChartValues: Sendable {
    public var reference: String?
    public var cachedNumbers: [Int: Double] = [:]
    public var cachedText: [Int: String] = [:]
    public var cachedCount = 0
    public var numberFormat: String?
    /// Written as `numRef` / `numLit` (rather than text).
    public var numeric = true
    public init() {}
}

public struct ChartAxis: Sendable {
    public enum Kind: String, Sendable { case category, value, date, series }
    public var id: String
    public var kind: Kind
    /// b, l, r or t.
    public var position = "b"
    public var deleted = false
    public var title: ChartText?
    public var numberFormat: String?
    public var sourceLinked = true
    public var min: Double?
    public var max: Double?
    public var majorUnit: Double?
    public var majorGridlines = false
    public var reversed = false
    public var crossAxis: String?
    public var labelsShown = true
    public var logBase: Double?
    public init(id: String, kind: Kind) { self.id = id; self.kind = kind }
}

public struct ChartLegend: Sendable, Equatable {
    /// r, l, t, b or tr.
    public var position = "r"
    public var overlay = false
    public var hiddenEntries: Set<Int> = []
    public init() {}
}

// MARK: - Resolved

/// Where a chart reads cell values from (a workbook, or nothing — then caches are used).
public protocol ChartDataSource {
    /// Cells of a reference such as `'Sheet 1'!$B$2:$B$9`, row by row, with their display text.
    /// Nil when the reference cannot be followed here.
    func chartCells(_ reference: String) -> [[ChartCell]]?
}

public struct ChartCell: Sendable, Equatable {
    public var number: Double?
    public var text: String
    public var numberFormat: String?
    public init(number: Double?, text: String, numberFormat: String? = nil) { self.number = number; self.text = text; self.numberFormat = numberFormat }
}

public struct ResolvedChart: Sendable {
    public var spec: ChartSpec
    public var title: String?
    public var plots: [ResolvedPlot]
}

public struct ResolvedPlot: Sendable {
    public var plot: ChartPlot
    public var series: [ResolvedSeries]
    /// Labels along the category axis (the longest category list among the series).
    public var categories: [String]
}

public struct ResolvedSeries: Sendable {
    public var series: ChartSeries
    public var name: String
    public var categories: [String]
    public var values: [Double?]
    /// Numeric x values (scatter, bubble), when the categories are numbers.
    public var xValues: [Double?]?
    public var sizes: [Double?]?
    public var numberFormat: String?
    /// Index among all series of the chart, for default colours.
    public var index: Int
}
