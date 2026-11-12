import Foundation
import CDuckDB

/// The pinned C ABI is loaded only when opening Parquet. Other viewers pay no startup cost.
/// Keeping the official header avoids hand-maintained C struct layouts across architectures.
final class ParquetLibrary: @unchecked Sendable {
    typealias Open =
        @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<duckdb_database?>?, duckdb_config?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) ->
        duckdb_state
    typealias Close = @convention(c) (UnsafeMutablePointer<duckdb_database?>?) -> Void
    typealias Connect = @convention(c) (duckdb_database?, UnsafeMutablePointer<duckdb_connection?>?) -> duckdb_state
    typealias Disconnect = @convention(c) (UnsafeMutablePointer<duckdb_connection?>?) -> Void
    typealias Interrupt = @convention(c) (duckdb_connection?) -> Void
    typealias CreateConfig = @convention(c) (UnsafeMutablePointer<duckdb_config?>?) -> duckdb_state
    typealias SetConfig = @convention(c) (duckdb_config?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> duckdb_state
    typealias DestroyConfig = @convention(c) (UnsafeMutablePointer<duckdb_config?>?) -> Void
    typealias Prepare = @convention(c) (duckdb_connection?, UnsafePointer<CChar>?, UnsafeMutablePointer<duckdb_prepared_statement?>?) -> duckdb_state
    typealias Bind = @convention(c) (duckdb_prepared_statement?, idx_t, UnsafePointer<CChar>?) -> duckdb_state
    typealias Execute = @convention(c) (duckdb_prepared_statement?, UnsafeMutablePointer<duckdb_result>?) -> duckdb_state
    typealias DestroyPrepare = @convention(c) (UnsafeMutablePointer<duckdb_prepared_statement?>?) -> Void
    typealias PrepareError = @convention(c) (duckdb_prepared_statement?) -> UnsafePointer<CChar>?
    typealias DestroyResult = @convention(c) (UnsafeMutablePointer<duckdb_result>?) -> Void
    typealias ResultError = @convention(c) (UnsafeMutablePointer<duckdb_result>?) -> UnsafePointer<CChar>?
    typealias Count = @convention(c) (UnsafeMutablePointer<duckdb_result>?) -> idx_t
    typealias ChunkCount = @convention(c) (duckdb_result) -> idx_t
    typealias GetChunk = @convention(c) (duckdb_result, idx_t) -> duckdb_data_chunk?
    typealias DestroyChunk = @convention(c) (UnsafeMutablePointer<duckdb_data_chunk?>?) -> Void
    typealias ChunkSize = @convention(c) (duckdb_data_chunk?) -> idx_t
    typealias Vector = @convention(c) (duckdb_data_chunk?, idx_t) -> duckdb_vector?
    typealias VectorData = @convention(c) (duckdb_vector?) -> UnsafeMutableRawPointer?
    typealias Validity = @convention(c) (duckdb_vector?) -> UnsafeMutablePointer<UInt64>?
    typealias Valid = @convention(c) (UnsafeMutablePointer<UInt64>?, idx_t) -> Bool
    typealias StringLength = @convention(c) (duckdb_string_t) -> UInt32
    typealias StringData = @convention(c) (UnsafeMutablePointer<duckdb_string_t>?) -> UnsafePointer<CChar>?
    typealias Free = @convention(c) (UnsafeMutableRawPointer?) -> Void

    let open: Open, close: Close, connect: Connect, disconnect: Disconnect, interrupt: Interrupt
    let createConfig: CreateConfig, setConfig: SetConfig, destroyConfig: DestroyConfig
    let prepare: Prepare, bind: Bind, execute: Execute, destroyPrepare: DestroyPrepare, prepareError: PrepareError
    let destroyResult: DestroyResult, resultError: ResultError, rowCount: Count, columnCount: Count
    let chunkCount: ChunkCount, getChunk: GetChunk, destroyChunk: DestroyChunk, chunkSize: ChunkSize
    let vector: Vector, vectorData: VectorData, validity: Validity, valid: Valid
    let stringLength: StringLength, stringData: StringData, free: Free
    private let handle: UnsafeMutableRawPointer

    static let shared: Result<ParquetLibrary, Error> = Result { try ParquetLibrary() }

    private init() throws {
        var paths: [String] = []
        if let frameworks = Bundle.main.privateFrameworksURL {
            paths.append(frameworks.appendingPathComponent("libduckdb.dylib").path)
        }
        #if DEBUG
            // Only command-line tests use this override; the distributed app uses its own library.
            if let path = ProcessInfo.processInfo.environment["PERLUSTRA_DUCKDB_LIBRARY"] { paths.append(path) }
        #endif
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }),
            let h = dlopen(path, RTLD_NOW | RTLD_LOCAL)
        else { throw ParquetError.unavailable }
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let p = dlsym(h, name) else { throw ParquetError.unavailable }
            return unsafeBitCast(p, to: T.self)
        }
        do {
            open = try symbol("duckdb_open_ext", Open.self)
            close = try symbol("duckdb_close", Close.self)
            connect = try symbol("duckdb_connect", Connect.self)
            disconnect = try symbol("duckdb_disconnect", Disconnect.self)
            interrupt = try symbol("duckdb_interrupt", Interrupt.self)
            createConfig = try symbol("duckdb_create_config", CreateConfig.self)
            setConfig = try symbol("duckdb_set_config", SetConfig.self)
            destroyConfig = try symbol("duckdb_destroy_config", DestroyConfig.self)
            prepare = try symbol("duckdb_prepare", Prepare.self)
            bind = try symbol("duckdb_bind_varchar", Bind.self)
            execute = try symbol("duckdb_execute_prepared", Execute.self)
            destroyPrepare = try symbol("duckdb_destroy_prepare", DestroyPrepare.self)
            prepareError = try symbol("duckdb_prepare_error", PrepareError.self)
            destroyResult = try symbol("duckdb_destroy_result", DestroyResult.self)
            resultError = try symbol("duckdb_result_error", ResultError.self)
            rowCount = try symbol("duckdb_row_count", Count.self)
            columnCount = try symbol("duckdb_column_count", Count.self)
            chunkCount = try symbol("duckdb_result_chunk_count", ChunkCount.self)
            getChunk = try symbol("duckdb_result_get_chunk", GetChunk.self)
            destroyChunk = try symbol("duckdb_destroy_data_chunk", DestroyChunk.self)
            chunkSize = try symbol("duckdb_data_chunk_get_size", ChunkSize.self)
            vector = try symbol("duckdb_data_chunk_get_vector", Vector.self)
            vectorData = try symbol("duckdb_vector_get_data", VectorData.self)
            validity = try symbol("duckdb_vector_get_validity", Validity.self)
            valid = try symbol("duckdb_validity_row_is_valid", Valid.self)
            stringLength = try symbol("duckdb_string_t_length", StringLength.self)
            stringData = try symbol("duckdb_string_t_data", StringData.self)
            free = try symbol("duckdb_free", Free.self)
        } catch {
            dlclose(h)
            throw error
        }
        handle = h
    }

    deinit { dlclose(handle) }
}
