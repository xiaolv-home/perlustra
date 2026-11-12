#!/usr/bin/env python3
"""Keeps the layers apart. The rules are documented in docs/ARCHITECTURE.md; fails the build if a
file reaches into a layer it should not know about.

A reference means using a top-level type declared in another folder. Names nested inside a type
and names in comments or string literals do not count."""
import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
MAX_FILE_LINES = 600

# Folder → folders it may use. PerlustraCore's Spreadsheet, Formula, Drawing and Chart are one engine:
# a sheet holds formulas and drawings, and those read cells back.
ENGINE = {"Spreadsheet", "Formula", "Drawing", "Chart"}
CORE_LAYERS = {
    "Support": set(),
    "Security": set(),
    "Detection": {"Support"},
    "Text": {"Support", "Detection"},
    "Archive": {"Support", "Detection"},
    "SQLite": {"Support"},
    "Parquet": {"Support"},
    **{name: {"Support", "Detection", "Text", "Archive"} | ENGINE for name in ENGINE},
    "AI": {"Support", "Security", "Detection", "Text", "Archive"} | ENGINE,
}
APP_LAYERS = {
    "DesignSystem": set(),
    "Base": set(),
    "Services": {"DesignSystem", "Base"},
    "Renderers": {"DesignSystem", "Base", "Services", "AI/Tools"},
    "AI/Tools": {"Base", "Services", "Renderers", "AI/Core"},
    "AI/Core": {"Base", "Services", "Renderers", "AI/Tools"},
    "AI/UI": {"DesignSystem", "Base", "Services", "Renderers", "AI/Tools", "AI/Core", "Shell", "App"},
    "Shell": {"DesignSystem", "Base", "Services", "Renderers", "AI/Tools", "AI/Core", "AI/UI", "App"},
    "App": {"DesignSystem", "Base", "Services", "Renderers", "AI/Tools", "AI/Core", "AI/UI", "Shell"},
}
# Only the registry (and the debug-only automation) may name a particular kind of renderer.
RENDERER_USERS_OK = {"Renderers", "App/AppAutomation+Debug.swift"}
UI_FRAMEWORKS = re.compile(r"^import (AppKit|SwiftUI|WebKit|Quartz|PDFKit|AVKit|AVFoundation|CoreText)\b", re.M)
DECLARATION = re.compile(
    r"^(?:@\w+(?:\([^)]*\))?\s+)*(?:public |internal |final |open |indirect )*"
    r"(?:struct|class|enum|protocol|typealias|actor)\s+([A-Z]\w+)", re.M)
STRING = re.compile(r'"""[\s\S]*?"""|#"(?:[^"\n]|"(?!#))*"#|"(?:[^"\\\n]|\\.)*"')
COMMENT = re.compile(r"//[^\n]*|/\*[\s\S]*?\*/")
IDENTIFIER = re.compile(r"\b[A-Z]\w+\b")


def strip(source: str) -> str:
    """Removes strings and comments, keeping line numbers."""
    def blank(match: re.Match) -> str:
        return re.sub(r"[^\n]", " ", match.group(0))
    return COMMENT.sub(blank, STRING.sub(blank, source))


def layer_of(relative: Path, target: str) -> str:
    parts = relative.parts
    if target == "PerlustraApp" and parts[0] == "AI":
        if len(parts) > 2 and parts[1] in ("Tools", "UI"):
            return f"AI/{parts[1]}"
        return "AI/Core"
    return parts[0]


def scan(target: str) -> tuple[dict[str, str], list[tuple[Path, str, str]]]:
    owners: dict[str, str] = {}
    files = []
    folder = ROOT / "Sources" / target
    for path in sorted(folder.rglob("*.swift")):
        relative = path.relative_to(folder)
        if len(relative.parts) < 2:
            continue
        source = path.read_text(encoding="utf-8")
        layer = layer_of(relative, target)
        files.append((path, layer, strip(source)))
        for name in DECLARATION.findall(source):
            owners.setdefault(name, layer)
    return owners, files


def check_layers(target: str, rules: dict[str, set[str]], problems: list[str]) -> None:
    owners, files = scan(target)
    for path, layer, code in files:
        if layer not in rules:
            problems.append(f"{path.relative_to(ROOT)}：目录「{layer}」不在分层规则里")
            continue
        allowed = rules[layer] | {layer}
        seen = set()
        for number, line in enumerate(code.split("\n"), 1):
            for name in IDENTIFIER.findall(line):
                owner = owners.get(name)
                if owner and owner not in allowed and (name, owner) not in seen:
                    seen.add((name, owner))
                    problems.append(f"{path.relative_to(ROOT)}:{number}：{layer} 不该用 {owner} 里的 {name}")


def check_renderer_names(problems: list[str]) -> None:
    folder = ROOT / "Sources/PerlustraApp"
    concrete = set()
    for path in (folder / "Renderers").rglob("*.swift"):
        concrete |= {n for n in DECLARATION.findall(path.read_text(encoding="utf-8")) if n.endswith("Renderer") and n != "Renderer"}
    for path in sorted(folder.rglob("*.swift")):
        relative = path.relative_to(folder)
        if relative.parts[0] in RENDERER_USERS_OK or str(relative) in RENDERER_USERS_OK:
            continue
        for number, line in enumerate(strip(path.read_text(encoding="utf-8")).split("\n"), 1):
            for name in set(IDENTIFIER.findall(line)) & concrete:
                problems.append(f"{path.relative_to(ROOT)}:{number}：外壳和 AI 不该认识具体的 {name}，加一个协议")


def check_core_is_headless(problems: list[str]) -> None:
    for path in sorted((ROOT / "Sources/PerlustraCore").rglob("*.swift")):
        match = UI_FRAMEWORKS.search(path.read_text(encoding="utf-8"))
        if match:
            problems.append(f"{path.relative_to(ROOT)}：PerlustraCore 不能依赖界面框架（{match.group(1)}）")


def check_theme_colours(problems: list[str]) -> None:
    """A theme colour's cgColor resolves against the current appearance, not the view's, so a layer
    set up that way can stay light in the black theme. Use NSView.resolved(_:) or SurfaceView."""
    for path in sorted((ROOT / "Sources/PerlustraApp").rglob("*.swift")):
        code = strip(path.read_text(encoding="utf-8"))
        for number, line in enumerate(code.split("\n"), 1):
            if re.search(r"\bTheme\.\w+\.cgColor\b", line):
                problems.append(f"{path.relative_to(ROOT)}:{number}：主题色别直接取 cgColor，用 resolved(_:)")


def check_file_sizes(problems: list[str]) -> None:
    for path in sorted((ROOT / "Sources").rglob("*.swift")):
        count = path.read_text(encoding="utf-8").count("\n")
        if count > MAX_FILE_LINES:
            problems.append(f"{path.relative_to(ROOT)}：{count} 行，超过 {MAX_FILE_LINES} 行，该拆了")


def main() -> int:
    problems: list[str] = []
    check_layers("PerlustraCore", CORE_LAYERS, problems)
    check_layers("PerlustraApp", APP_LAYERS, problems)
    check_renderer_names(problems)
    check_core_is_headless(problems)
    check_theme_colours(problems)
    check_file_sizes(problems)
    for problem in problems:
        print(problem)
    print(f"架构检查：{len(problems)} 个问题" if problems else "架构检查通过")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
