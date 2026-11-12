# Sourced by test.sh / build-app.sh. Pin both the archive and the extracted library;
# cache outside SwiftPM's disposable .build folder. No download takes place in the app.
duckdb_version=1.5.4
duckdb_archive_sha=3f3c52970ad1407ec5037062e1a5e575b24bd5b993c889f89fe5876eff47782c
duckdb_library_sha=4890e5b4a340aae7d5fc207d267b9ac78a1578abbc6eec9061a56d086fee93de
duckdb_dir="$PWD/build/dependencies/duckdb-$duckdb_version"
duckdb_valid() {
  [[ -f "$1" ]] && [[ "$(shasum -a 256 "$1" | cut -d ' ' -f 1)" == "$2" ]]
}
if ! duckdb_valid "$duckdb_dir/libduckdb.dylib" "$duckdb_library_sha"; then
  mkdir -p "$duckdb_dir"
  duckdb_tmp="$(mktemp -d "$duckdb_dir/download.XXXXXX")"
  if ! curl --fail --location --retry 3 --connect-timeout 20 --max-time 600 \
    "https://github.com/duckdb/duckdb/releases/download/v$duckdb_version/libduckdb-osx-universal.zip" \
    -o "$duckdb_tmp/duckdb.zip" \
    || ! duckdb_valid "$duckdb_tmp/duckdb.zip" "$duckdb_archive_sha" \
    || ! unzip -q "$duckdb_tmp/duckdb.zip" libduckdb.dylib -d "$duckdb_tmp" \
    || ! duckdb_valid "$duckdb_tmp/libduckdb.dylib" "$duckdb_library_sha"; then
    rm -rf "$duckdb_tmp"
    echo 'Parquet 读取库下载或校验失败' >&2
    exit 1
  fi
  mv "$duckdb_tmp/libduckdb.dylib" "$duckdb_dir/libduckdb.dylib"
  rm -rf "$duckdb_tmp"
fi
export PERLUSTRA_DUCKDB_LIBRARY="$duckdb_dir/libduckdb.dylib"
