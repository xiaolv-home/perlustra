#!/usr/bin/env python3
"""Generates fixtures/office/charts.xlsx: every kind of object Perlustra draws over a sheet.

openpyxl writes charts with cell references only (no cached values) — the case that left
sheets blank — so these also check that Perlustra reads the numbers from the cells itself.
Run: python3 scripts/gen-chart-fixtures.py"""
from pathlib import Path

from openpyxl import Workbook
from openpyxl.chart import AreaChart, BarChart, DoughnutChart, LineChart, PieChart, RadarChart, Reference, ScatterChart, Series
from openpyxl.drawing.image import Image
from PIL import Image as PILImage, ImageDraw

root = Path(__file__).resolve().parent.parent
out = root / "fixtures/office/charts.xlsx"
wb = Workbook()

# 1. A report sheet laid out like a generated weekly report: a title, charts anchored over
#    the empty rows below it, and the numbers they plot further down.
ws = wb.active
ws.title = "图表分析"
ws["B2"] = "图表分析 · 示例周报"
regions = ["华东", "华南", "华北", "西南", "西北", "华中"]
ws["B40"] = "— 图表底层数据 —"
ws.append([])
header_row = 41
for c, h in enumerate(["战区", "本周", "上周", "去年同期", "环比", "同比"], start=2):
    ws.cell(header_row, c, h)
for i, r in enumerate(regions):
    row = header_row + 1 + i
    ws.cell(row, 2, r)
    ws.cell(row, 3, 1000 + i * 137)
    ws.cell(row, 4, 950 + i * 121)
    ws.cell(row, 5, 800 + i * 150)
    ws.cell(row, 6, round(0.05 - i * 0.02, 3))
    ws.cell(row, 7, round(-0.03 + i * 0.015, 3))
last = header_row + len(regions)
cats = Reference(ws, min_col=2, min_row=header_row + 1, max_row=last)

bar = BarChart()
bar.title = "图1 · 各战区 GMV 三周对比"
bar.add_data(Reference(ws, min_col=3, max_col=5, min_row=header_row, max_row=last), titles_from_data=True)
bar.set_categories(cats)
# Like the weekly report: no fill on the series, only a thin white edge — the colours come
# from Excel's chart style (12 = shades of accent 2, 13 = shades of accent 3).
bar.style = 12
for s in bar.series:
    s.graphicalProperties.line.solidFill = "F2F2F2"
ws.add_chart(bar, "B4")

stacked = BarChart()
stacked.title = "图2 · 堆积"
stacked.grouping = "stacked"
stacked.overlap = 100
stacked.add_data(Reference(ws, min_col=3, max_col=4, min_row=header_row, max_row=last), titles_from_data=True)
stacked.set_categories(cats)
stacked.style = 13
for s in stacked.series:
    s.graphicalProperties.line.solidFill = "F2F2F2"
ws.add_chart(stacked, "J4")

horizontal = BarChart()
horizontal.type = "bar"
horizontal.title = "图3 · 环比 vs 同比（横向）"
horizontal.add_data(Reference(ws, min_col=6, max_col=7, min_row=header_row, max_row=last), titles_from_data=True)
horizontal.set_categories(cats)
ws.add_chart(horizontal, "B21")

line = LineChart()
line.title = "图4 · 折线 + 柱（副坐标轴）"
line.add_data(Reference(ws, min_col=6, min_row=header_row, max_row=last), titles_from_data=True)
line.y_axis.axId = 200
line.y_axis.crosses = "max"
combo = BarChart()
combo.add_data(Reference(ws, min_col=3, min_row=header_row, max_row=last), titles_from_data=True)
combo.set_categories(cats)
combo += line
ws.add_chart(combo, "J21")

# A chart far to the right of anything in use: needs empty columns made for it.
far = BarChart()
far.title = "远处的图"
far.add_data(Reference(ws, min_col=3, min_row=header_row, max_row=last), titles_from_data=True)
far.set_categories(cats)
ws.add_chart(far, "AB4")

# 2. Every other chart kind on one sheet.
ws2 = wb.create_sheet("各种图表")
months = ["1月", "2月", "3月", "4月", "5月", "6月"]
ws2.append(["月份", "堂食", "外卖", "x", "y"])
for i, m in enumerate(months):
    ws2.append([m, 30 + i * 7, 20 + (i % 3) * 9, i * 1.5, (i - 2) ** 2])
mcats = Reference(ws2, min_col=1, min_row=2, max_row=7)
data2 = Reference(ws2, min_col=2, max_col=3, min_row=1, max_row=7)
specs = [
    (LineChart, "折线", "H2"), (AreaChart, "面积", "Q2"), (PieChart, "饼图", "H20"),
    (DoughnutChart, "环形", "Q20"), (RadarChart, "雷达", "H38"),
]
for cls, title, at in specs:
    ch = cls()
    ch.title = title
    if cls in (PieChart, DoughnutChart):
        ch.add_data(Reference(ws2, min_col=2, min_row=1, max_row=7), titles_from_data=True)
    else:
        ch.add_data(data2, titles_from_data=True)
    ch.set_categories(mcats)
    ws2.add_chart(ch, at)
sc = ScatterChart()
sc.title = "散点"
s = Series(Reference(ws2, min_col=5, min_row=2, max_row=7), Reference(ws2, min_col=4, min_row=2, max_row=7), title="y = (x-2)²")
s.marker.symbol = "circle"
sc.series.append(s)
ws2.add_chart(sc, "Q38")

# 3. A picture over the cells.
img_path = root / "fixtures/office/.chart-fixture-logo.png"
im = PILImage.new("RGB", (160, 90), (240, 236, 228))
d = ImageDraw.Draw(im)
d.rectangle([8, 8, 152, 82], outline=(200, 90, 40), width=4)
d.ellipse([60, 25, 100, 65], fill=(68, 114, 196))
im.save(img_path)
ws3 = wb.create_sheet("图片")
ws3["A1"] = "下面是一张图片"
ws3.add_image(Image(str(img_path)), "B3")

# 4. A chart sheet: no cells, just the chart.
cs = wb.create_chartsheet("整页图表")
whole = BarChart()
whole.title = "整页的柱状图"
whole.add_data(data2, titles_from_data=True)
whole.set_categories(mcats)
cs.add_chart(whole)

wb.save(out)
img_path.unlink()
print(out)
