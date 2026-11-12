import Foundation

/// Broad family a file belongs to. Renderers are chosen per family.
public enum FormatFamily: String, Sendable, CaseIterable {
    case pdf, image, svg, video, audio
    case text, code, markdown, json, plist, csv, html
    case font, archive, iwork, office, quicklook, sqlite
    case directory, binary

    /// Visual category used for badges and tints.
    public var category: FormatCategory {
        switch self {
        case .pdf, .iwork, .office: return .document
        case .image, .svg: return .image
        case .video, .audio: return .media
        case .text, .code, .markdown: return .code
        case .json, .plist, .csv, .sqlite: return .data
        case .html: return .web
        case .font: return .font
        case .archive, .directory: return .archive
        case .quicklook, .binary: return .other
        }
    }
}

public enum FormatCategory: String, Sendable {
    case document, image, media, code, data, web, font, archive, other
}

public enum IWorkKind: String, Sendable {
    case pages, keynote, numbers

    public var bundleID: String {
        switch self {
        case .pages: return "com.apple.Pages"
        case .keynote: return "com.apple.Keynote"
        case .numbers: return "com.apple.Numbers"
        }
    }

    public var appName: String {
        switch self {
        case .pages: return "Pages"
        case .keynote: return "Keynote"
        case .numbers: return "Numbers"
        }
    }
}

/// How the format was determined.
public enum DetectionSource: String, Sendable {
    case magic, `extension`, sniff, directory
}

public struct DetectedFormat: Sendable, Equatable {
    public var family: FormatFamily
    /// Canonical short type token shown in the badge ("PDF", "PNG", "SWIFT" …).
    public var token: String
    /// Human readable Chinese description ("PDF 文档").
    public var label: String
    /// Syntax language for text/code families.
    public var language: String?
    public var iwork: IWorkKind?
    /// Field delimiter for CSV/TSV.
    public var delimiter: UInt8?
    /// True if the extension contradicts the content.
    public var extensionMismatch: Bool
    public var source: DetectionSource

    public init(
        family: FormatFamily, token: String, label: String, language: String? = nil,
        iwork: IWorkKind? = nil, delimiter: UInt8? = nil,
        extensionMismatch: Bool = false, source: DetectionSource
    ) {
        self.family = family
        self.token = token
        self.label = label
        self.language = language
        self.iwork = iwork
        self.delimiter = delimiter
        self.extensionMismatch = extensionMismatch
        self.source = source
    }
}
