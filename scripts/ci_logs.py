#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""下载最近一次 GitHub Actions 运行的日志，摘出编译错误。

用法：
    set GITHUB_TOKEN=...
    python scripts/ci_logs.py [--all] [--run-id 12345]

默认只打印包含 error:/BUILD FAILED/undefined 等关键字的行与末尾若干行；
--all 把完整日志写到 build-ci.log 便于细看。
"""

from __future__ import annotations

import io
import json
import os
import re
import sys
import urllib.error
import urllib.request
import zipfile

API = "https://api.github.com"
TOKEN = os.environ.get("GITHUB_TOKEN", "").strip()
OWNER = os.environ.get("GITHUB_OWNER", "").strip()
REPO = os.environ.get("GITHUB_REPO", "").strip()

KEYWORDS = re.compile(
    r"error:|BUILD FAILED|The following build commands failed|"
    r"xcodegen|xcrun:|fatal error|Undefined symbol|Command CompileSwift failed|"
    r"warning: .*deprecat",
    re.IGNORECASE,
)


def get(url: str) -> bytes:
    request = urllib.request.Request(url)
    request.add_header("Authorization", f"Bearer {TOKEN}")
    request.add_header("Accept", "application/vnd.github+json")
    request.add_header("User-Agent", "zcode-ci-logs")
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def main() -> int:
    if not TOKEN or not OWNER or not REPO:
        print("ERROR: 需要 GITHUB_TOKEN / GITHUB_OWNER / GITHUB_REPO", file=sys.stderr)
        return 2

    args = sys.argv[1:]
    run_id = None
    if "--run-id" in args:
        run_id = args[args.index("--run-id") + 1]

    if run_id is None:
        runs = json.loads(get(f"{API}/repos/{OWNER}/{REPO}/actions/runs?per_page=1"))
        run = runs["workflow_runs"][0]
        run_id = str(run["id"])
        print(f"run #{run['run_number']} status={run['status']} conclusion={run.get('conclusion')}")

    try:
        blob = get(f"{API}/repos/{OWNER}/{REPO}/actions/runs/{run_id}/logs")
    except urllib.error.HTTPError as error:
        print(f"ERROR: 下载日志失败 HTTP {error.code}", file=sys.stderr)
        return 3

    archive = zipfile.ZipFile(io.BytesIO(blob))
    combined: list[str] = []
    for name in archive.namelist():
        text = archive.read(name).decode("utf-8", "replace")
        combined.append(f"===== {name} =====")
        combined.append(text)

    if "--all" in args:
        with open("build-ci.log", "w", encoding="utf-8") as handle:
            handle.write("\n".join(combined))
        print("已写出 build-ci.log")

    lines = "\n".join(combined).splitlines()
    hits = [line for line in lines if KEYWORDS.search(line)]
    print(f"总行数 {len(lines)}，命中 {len(hits)} 行")
    for line in hits[:120]:
        print(line)
    print("---- 末尾 30 行 ----")
    for line in lines[-30:]:
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())