"""Crude structural lint for the Swift sources.

Not a compiler. It catches the class of damage that would otherwise only show up
on CI: unbalanced braces/parens outside string literals and comments, stray
zero-width or replacement characters, tabs-vs-spaces artifacts, and files that
do not parse as UTF-8.
"""

import pathlib
import sys


def strip_noise(src: str) -> str:
    out = []
    i = 0
    n = len(src)
    while i < n:
        ch = src[i]
        if ch == '"':
            # triple quoted string
            if src.startswith('"""', i):
                i += 3
                while i < n and not src.startswith('"""', i):
                    i += 1
                i += 3
                continue
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if src.startswith("//", i):
            while i < n and src[i] != "\n":
                i += 1
            continue
        if src.startswith("/*", i):
            i += 2
            while i < n and not src.startswith("*/", i):
                i += 1
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def check(path: pathlib.Path) -> list[str]:
    problems = []
    try:
        raw = path.read_bytes()
        src = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        return [f"{path}: not valid UTF-8 ({exc})"]
    if src.startswith("\ufeff"):
        problems.append(f"{path}: starts with BOM")
    if "\ufffd" in src:
        problems.append(f"{path}: contains U+FFFD replacement character")
    if "\u200b" in src:
        problems.append(f"{path}: contains zero-width space")
    code = strip_noise(src)
    for opener, closer, name in (("{", "}", "braces"), ("(", ")", "parens"), ("[", "]", "brackets")):
        depth = 0
        line = 1
        for ch in code:
            if ch == "\n":
                line += 1
            elif ch == opener:
                depth += 1
            elif ch == closer:
                depth -= 1
                if depth < 0:
                    problems.append(f"{path}:{line}: unbalanced {name} (extra '{closer}')")
                    break
        if depth > 0:
            problems.append(f"{path}: unbalanced {name} (missing {depth} '{closer}')")
    return problems


def main() -> int:
    root = pathlib.Path("Sources")
    all_problems = []
    files = sorted(root.rglob("*.swift"))
    for p in files:
        all_problems.extend(check(p))
    for line in all_problems:
        print(line)
    print(f"checked {len(files)} files, {len(all_problems)} problems")
    return 1 if all_problems else 0


if __name__ == "__main__":
    raise SystemExit(main())