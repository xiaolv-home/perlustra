#!/usr/bin/env python3
"""Synthetic, redistributable Parquet fixtures. Requires pyarrow only for regeneration.

The app and its tests use the checked-in files, never a Python runtime.
"""
from datetime import date, datetime, timezone
from decimal import Decimal
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

root = Path(__file__).resolve().parent.parent / "fixtures/parquet"
root.mkdir(parents=True, exist_ok=True)
table = pa.table({
    "订单号": pa.array([9007199254740993, 9223372036854775807, None], type=pa.int64()),
    "门店": ["北京店", "上海店", None],
    "金额": pa.array([Decimal("1234567890123456.78"), Decimal("-0.01"), None], type=pa.decimal128(20, 2)),
    "营业日": pa.array([date(2026, 11, 12), date(1970, 1, 1), None], type=pa.date32()),
    "时间": pa.array([datetime(2026, 11, 12, 1, 2, 3, 123456, tzinfo=timezone.utc), None, None], type=pa.timestamp("us", tz="UTC")),
    "有效": pa.array([True, False, None]),
    "明细": pa.array([[1, 2], [], None], type=pa.list_(pa.int64())),
    "属性": pa.array([{"城市": "北京", "数量": 2}, None, {"城市": "上海", "数量": None}], type=pa.struct([("城市", pa.string()), ("数量", pa.int32())])),
    '带"引号': ["a\x00b", "", None],
    "二进制": pa.array([b"\x00\x01\xff", b"", None], type=pa.binary()),
    "无符号": pa.array([18446744073709551615, 0, None], type=pa.uint64()),
})
for codec in ("NONE", "snappy", "gzip", "zstd", "brotli", "lz4"):
    pq.write_table(table, root / f"sample-{codec.lower()}.parquet", compression=codec, row_group_size=2)
pq.write_table(table.slice(0, 0), root / "empty.parquet")
pq.write_table(pa.table({"编号": range(513), "名称": [f"门店{i}" for i in range(513)]}), root / "multi-group.parquet", row_group_size=50, data_page_version="2.0")
pq.write_table(pa.table({f"列{i}": [i] for i in range(270)}), root / "wide.parquet")
pq.write_table(pa.table({"正文": ["长" * 20000, "正常"]}), root / "long-cell.parquet")
pq.write_table(pa.table({"值": [1.25, None, -3.5], "数": [1, 2, 3]}), root / "byte-stream.parquet", compression="zstd", use_dictionary=False, use_byte_stream_split=["值"])
pq.write_table(pa.table({"数": [1, 2, 3]}), root / "unsupported-encoding.parquet", use_dictionary=False, use_byte_stream_split=True)
(root / "truncated.parquet").write_bytes((root / "sample-snappy.parquet").read_bytes()[:100])
(root / "broken-footer.parquet").write_bytes(b"PAR1" + b"\x00" * 64 + (64).to_bytes(4, "little") + b"PAR1")
(root / "encrypted.parquet").write_bytes(b"PARE" + b"\x00" * 20)
print(f"Generated {len(list(root.glob('*.parquet')))} fixtures")
