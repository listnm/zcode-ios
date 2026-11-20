#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""轮询 GitHub Actions 的运行状态，结束后打印结论与失败步骤。

只读：不发任何写请求，token 从环境变量读取。
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request

API = "https://api.github.com"
TOKEN = os.environ.get("GITHUB_TOKEN", "").strip()
OWNER = os.environ.get("GITHUB_OWNER", "").strip()
REPO = os.environ.get("GITHUB_REPO", "").strip()
TIMEOUT = int(os.environ.get("GITHUB_WAIT_SECONDS", "1500"))


def get(path: str):
    req = urllib.request.Request(API + path, method="GET")
    req.add_header("Authorization", f"Bearer {TOKEN}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", "zcode-ci-watch")
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return response.status, json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", "replace")
        try:
            return error.code, json.loads(body)
        except json.JSONDecodeError:
            return error.code, {"message": body[:200]}


def main() -> int:
    if not TOKEN or not OWNER or not REPO:
        print("ERROR: 需要 GITHUB_TOKEN / GITHUB_OWNER / GITHUB_REPO", file=sys.stderr)
        return 2

    deadline = time.time() + TIMEOUT
    last = None
    while time.time() < deadline:
        status, data = get(f"/repos/{OWNER}/{REPO}/actions/runs?per_page=1")
        if status != 200:
            print(f"ERROR: 读取运行列表失败 HTTP {status}: {data.get('message')}", file=sys.stderr)
            return 3
        runs = data.get("workflow_runs") or []
        if not runs:
            print("还没有任何运行（可能 workflow 未触发）。")
            return 4
        run = runs[0]
        line = f"{run['name']} #{run['run_number']} status={run['status']} conclusion={run.get('conclusion')}"
        if line != last:
            print(line, flush=True)
            last = line
        if run["status"] == "completed":
            print(f"URL: {run['html_url']}")
            print(f"CONCLUSION: {run['conclusion']}")
            _, jobs = get(f"/repos/{OWNER}/{REPO}/actions/runs/{run['id']}/jobs")
            for job in jobs.get("jobs", []):
                print(f"- job {job['name']}: {job['status']}/{job.get('conclusion')}")
                for step in job.get("steps", []):
                    if step.get("conclusion") not in (None, "success", "skipped"):
                        print(f"    FAILED STEP: {step['name']} ({step.get('conclusion')})")
            return 0 if run["conclusion"] == "success" else 1
        time.sleep(20)
    print("超时未结束", file=sys.stderr)
    return 5


if __name__ == "__main__":
    raise SystemExit(main())