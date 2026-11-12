import Foundation
import CDuckDB

public struct ParquetColumn: Sendable, Equatable {
    public let name: String
    public let type: String
    public var isNumeric: Bool {
        let types = ["TINYINT", "SMALLINT", "INTEGER", "BIGINT", "HUGEINT", "UTINYINT", "USMALLINT", "UINTEGER", "UBIGINT", "UHUGEINT", "FLOAT", "DOUBLE"]
        return types.contains(type) || (type.hasPrefix("DECIMAL(") && type.hasSuffix(")"))
    }
}

public struct ParquetPreview: Sendable, Equatable {
    public let rowCount: Int64
    public let rowGroups: Int64
    public let columnCount: Int
    public let columns: [ParquetColumn]
    /// Text conversion happens in the reader, preserving decimal / 64-bit precision and NULL.
    public let rows: [[String?]]
    public let truncatedCells: Bool

    public func copyRows(_ indexes: IndexSet) -> String {
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        }
        let header = columns.map { clean($0.name) }.joined(separator: "\t")
        let lines = indexes.filter { rows.indices.contains($0) }.map { rows[$0].map { clean($0 ?? "") }.joined(separator: "\t") }
        return ([header] + lines).joined(separator: "\n")
    }
}

public enum ParquetError: LocalizedError, Equatable {
    case unavailable, invalid, encrypted, cancelled, timedOut
    case readFailed(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Parquet 读取组件缺失或无法加载，请重新安装应用"
        case .invalid: return "这个文件不是有效的 Parquet 数据表，或文件尚未写完"
        case .encrypted: return "暂不支持需要密钥的加密 Parquet 文件"
        case .cancelled: return "已取消"
        case .timedOut: return "读取超过 20 秒，已停止；请检查文件是否完整，或先拷到本机再打开"
        case .readFailed(let reason): return "无法读取 Parquet：\(reason)"
        }
    }
}

/// The lock also protects connection lifetime: detach waits for an in-flight interrupt.
public final class ParquetCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: ParquetError?
    private var interrupt: (() -> Void)?
    public init() {}
    public func cancel() { stop(.cancelled) }
    func stop(_ error: ParquetError) {
        lock.lock(); defer { lock.unlock() }
        if reason == nil { reason = error }
        interrupt?()
    }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if let reason { throw reason }
    }
    func attach(_ action: (() -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        interrupt = action
        if reason != nil { interrupt?() }
    }
    func pulse() {
        lock.lock(); defer { lock.unlock() }
        if reason != nil { interrupt?() }
    }
}

public enum ParquetReader {
    public static let sampleLimit = 200
    public static let columnLimit = 256
    public static let cellLimit = 16_384

    public static func read(url: URL, cancel: ParquetCancellation = ParquetCancellation()) throws -> ParquetPreview {
        try cancel.check()
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        guard url.isFileURL, !url.path.contains("\0"),
            (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true
        else { throw ParquetError.invalid }
        try validate(url)
        let library = try ParquetLibrary.shared.get()
        let connection = try ParquetConnection(library: library, path: url.path, cancel: cancel)
        return try connection.preview(path: url.path)
    }

    private static func validate(_ url: URL) throws {
        let f = try FileHandle(forReadingFrom: url)
        defer { try? f.close() }
        let head = try f.read(upToCount: 4)
        if head == Data("PARE".utf8) { throw ParquetError.encrypted }
        let size = try f.seekToEnd()
        guard head == Data("PAR1".utf8), size >= 12 else { throw ParquetError.invalid }
        try f.seek(toOffset: size - 8)
        guard let end = try f.read(upToCount: 8), end.count == 8,
            end.suffix(4) == Data("PAR1".utf8)
        else { throw ParquetError.invalid }
        let footer = end.prefix(4).enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
        guard footer > 0, footer <= size - 12 else { throw ParquetError.invalid }
    }
}

final class ParquetConnection {
    let api: ParquetLibrary
    let cancel: ParquetCancellation
    private var database: duckdb_database?
    private var connection: duckdb_connection?
    private var timer: DispatchSourceTimer?

    init(library: ParquetLibrary, path: String, cancel: ParquetCancellation) throws {
        api = library
        self.cancel = cancel
        var config: duckdb_config?
        defer { api.destroyConfig(&config) }
        guard api.createConfig(&config) == DuckDBSuccess else { throw ParquetError.unavailable }
        for (key, value) in [
            "threads": "2", "memory_limit": "256MB", "temp_directory": "",
            "autoinstall_known_extensions": "false", "autoload_known_extensions": "false",
            "allow_community_extensions": "false", "allow_persistent_secrets": "false",
        ] {
            guard api.setConfig(config, key, value) == DuckDBSuccess else { throw ParquetError.unavailable }
        }
        var error: UnsafeMutablePointer<CChar>?
        let rc = api.open(nil, &database, config, &error)
        defer { api.free(error) }
        guard rc == DuckDBSuccess else {
            api.close(&database)
            throw ParquetError.readFailed(error.map { String(cString: $0) } ?? "无法初始化读取组件")
        }
        guard api.connect(database, &connection) == DuckDBSuccess else {
            api.close(&database)
            throw ParquetError.unavailable
        }
        // Quoted values are only used in SET, where bound parameters are not supported.
        // All file reads use bound parameters; external access is restricted to this exact file.
        do {
            let allowed = [path, Self.literalPath(path)].map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ", ")
            _ = try query("SET allowed_paths = [" + allowed + "]")
            _ = try query("SET enable_external_access = false")
            _ = try query("SET TimeZone = 'UTC'")
            _ = try query("SET lock_configuration = true")
        } catch {
            api.disconnect(&connection)
            api.close(&database)
            throw error
        }
        let handle = connection
        cancel.attach { library.interrupt(handle) }
        let deadline = DispatchTime.now() + .seconds(20)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler {
            if DispatchTime.now() >= deadline { cancel.stop(.timedOut) }
            // Repeat after cancellation: an interrupt arriving between queries can be reset
            // by DuckDB when the next query starts.
            cancel.pulse()
        }
        timer.resume()
        self.timer = timer
    }

    deinit {
        timer?.cancel()
        cancel.attach(nil)
        api.disconnect(&connection)
        api.close(&database)
    }

    func preview(path: String) throws -> ParquetPreview {
        let path = Self.literalPath(path)
        let metadata = try query("SELECT num_rows::VARCHAR, num_row_groups::VARCHAR FROM parquet_file_metadata(?)", path: path)
        guard metadata.count == 1, metadata[0].count == 2,
            let count = metadata[0][0].flatMap(Int64.init), let groups = metadata[0][1].flatMap(Int64.init)
        else { throw ParquetError.invalid }
        let schema = try query("DESCRIBE SELECT * FROM read_parquet(?, hive_partitioning = false)", path: path)
        let columns = try schema.prefix(ParquetReader.columnLimit).map { row -> ParquetColumn in
            guard row.count >= 2, let name = row[0], let type = row[1] else { throw ParquetError.invalid }
            return ParquetColumn(name: name, type: type)
        }
        // Project before scanning, so wide files don't materialize thousands of hidden columns.
        let projection = columns.map {
            "LEFT(CAST(\"" + $0.name.replacingOccurrences(of: "\"", with: "\"\"") + "\" AS VARCHAR), \(ParquetReader.cellLimit + 1))"
        }.joined(separator: ", ")
        let raw =
            columns.isEmpty
            ? [] : try query("SELECT \(projection) FROM read_parquet(?, hive_partitioning = false) LIMIT \(ParquetReader.sampleLimit)", path: path)
        var truncated = false
        let rows = raw.map { row in
            row.map { value -> String? in
                guard let value, value.unicodeScalars.count > ParquetReader.cellLimit else { return value }
                truncated = true
                return String(String.UnicodeScalarView(value.unicodeScalars.prefix(ParquetReader.cellLimit))) + "…[内容过长，已截断]"
            }
        }
        try cancel.check()
        return ParquetPreview(rowCount: count, rowGroups: groups, columnCount: schema.count, columns: columns, rows: rows, truncatedCells: truncated)
    }

    /// DuckDB's file functions expand globs even for existing files. Escape the pattern,
    /// and allow both its spelling and the actual file because DuckDB checks both.
    private static func literalPath(_ path: String) -> String {
        path.map { c in
            switch c {
            case "[": return "[[]"
            case "*": return "[*]"
            case "?": return "[?]"
            default: return String(c)
            }
        }.joined()
    }

    func query(_ sql: String, path: String? = nil) throws -> [[String?]] {
        try cancel.check()
        var statement: duckdb_prepared_statement?
        defer { api.destroyPrepare(&statement) }
        guard api.prepare(connection, sql, &statement) == DuckDBSuccess else {
            try cancel.check()
            throw ParquetError.readFailed(api.prepareError(statement).map { String(cString: $0) } ?? "无法读取字段")
        }
        if let path, api.bind(statement, 1, path) != DuckDBSuccess { throw ParquetError.invalid }
        try cancel.check()
        var result = duckdb_result()
        defer { api.destroyResult(&result) }
        guard api.execute(statement, &result) == DuckDBSuccess else {
            try cancel.check()
            throw ParquetError.readFailed(api.resultError(&result).map { String(cString: $0) } ?? "读取失败")
        }
        var rows: [[String?]] = []
        for index in 0..<api.chunkCount(result) {
            var chunk = api.getChunk(result, index)
            defer { api.destroyChunk(&chunk) }
            guard chunk != nil else { throw ParquetError.readFailed("数据块读取失败") }
            for row in 0..<api.chunkSize(chunk) {
                try cancel.check()
                var cells: [String?] = []
                for col in 0..<api.columnCount(&result) {
                    let vector = api.vector(chunk, col)
                    if let validity = api.validity(vector), !api.valid(validity, row) { cells.append(nil); continue }
                    guard let values = api.vectorData(vector)?.assumingMemoryBound(to: duckdb_string_t.self) else { throw ParquetError.invalid }
                    let s = values.advanced(by: Int(row))
                    guard let data = api.stringData(s) else { throw ParquetError.invalid }
                    // Length-bearing vectors preserve embedded NUL; the legacy C value getters don't.
                    cells.append(String(decoding: UnsafeRawBufferPointer(start: data, count: Int(api.stringLength(s.pointee))), as: UTF8.self))
                }
                rows.append(cells)
            }
        }
        try cancel.check()
        return rows
    }
}
