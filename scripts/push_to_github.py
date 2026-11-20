#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把当前目录的源码推送到 GitHub 仓库（不需要 git 客户端）。

为什么不用 git：本机没有 git，也没有 gh CLI。GitHub 的 Git Data API 允许
逐文件上传 blob、组装 tree、创建 commit、再移动分支指针，效果等同于一次
干净的初始提交（或后续快照提交）。

用法：
    set GITHUB_TOKEN=ghp_xxx
    set GITHUB_OWNER=your-login
    set GITHUB_REPO=zcode-ios
    python scripts/push_to_github.py

可选：
    GITHUB_BRANCH=main          # 默认 main
    GITHUB_PRIVATE=true         # 仓库不存在时创建为私有库（默认 true）
    GITHUB_ORGS=my-org          # 仓库归属组织（默认个人账号）
    GITHUB_MESSAGE="..."        # 提交信息

安全：token 只从环境变量读取，绝不写进任何文件、日志或提交内容。
"""

from __future__ import annotations

import base64
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

API = "https://api.github.com"

SKIP_DIRS = {".git", "build", "DerivedData", "Payload", "__pycache__", ".swiftpm", "xcuserdata"}
SKIP_SUFFIXES = {".ipa", ".app", ".xcarchive", ".log", ".p12", ".mobileprovision"}
SKIP_NAMES = {".DS_Store", "_diag.py", "_enc_probe.swift", "cert.p12", "profile.mobileprovision"}


def request(method: str, path: str, token: str, payload: dict | None = None):
    url = path if path.startswith("http") else API + path
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", "zcode-ios-pusher")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = resp.read().decode("utf-8")
            return resp.status, (json.loads(body) if body else None)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(body)
        except json.JSONDecodeError:
            parsed = {"message": body}
        return exc.code, parsed


def collect_files(root: Path) -> list[tuple[str, bytes]]:
    out: list[tuple[str, bytes]] = []
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(root)
        if any(part in SKIP_DIRS for part in rel.parts):
            continue
        if path.name in SKIP_NAMES or path.suffix in SKIP_SUFFIXES:
            continue
        out.append((rel.as_posix(), path.read_bytes()))
    return out


def main() -> int:
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    owner = os.environ.get("GITHUB_OWNER", "").strip()
    repo = os.environ.get("GITHUB_REPO", "").strip()
    branch = os.environ.get("GITHUB_BRANCH", "main").strip() or "main"
    org = os.environ.get("GITHUB_ORGS", "").strip()
    private = os.environ.get("GITHUB_PRIVATE", "true").lower() != "false"
    message = os.environ.get("GITHUB_MESSAGE", "ZCode iOS: workspace-scoped agent client").strip()

    if "--help" in sys.argv or "-h" in sys.argv:
        print(__doc__)
        return 0

    if not token:
        print("ERROR: 缺少 GITHUB_TOKEN（需要 repo 权限的 classic PAT 或 fine-grained token）", file=sys.stderr)
        print("提示：在 https://github.com/settings/tokens 生成 classic token 并勾选 repo 权限。", file=sys.stderr)
        return 2
    if not repo:
        print("ERROR: 缺少 GITHUB_REPO（例如 zcode-ios）", file=sys.stderr)
        return 2

    status, who = request("GET", "/user", token)
    if status != 200:
        print(f"ERROR: token 无效或网络不通（HTTP {status}: {who.get('message') if who else ''}）", file=sys.stderr)
        return 3
    # 没显式给 owner 时用 token 所属账号，少一个必填项。
    if not owner:
        owner = str(who.get("login", "")).strip()
    if not owner:
        print("ERROR: 无法确定 GITHUB_OWNER", file=sys.stderr)
        return 2
    login = who["login"]
    owner = owner or login
    print(f"登录身份：{login}；目标仓库：{owner}/{repo}")

    status, info = request("GET", f"/repos/{owner}/{repo}", token)
    if status == 404:
        create_path = f"/orgs/{org}/repos" if org else "/user/repos"
        status, info = request("POST", create_path, token, {
            "name": repo,
            "private": private,
            "description": "ZCode 的 iOS 移植：选择文件夹作为工作区，Agent 在工作区内读写文件。",
            "has_issues": True,
            "has_wiki": False,
        })
        if status not in (200, 201):
            print(f"ERROR: 创建仓库失败（HTTP {status}: {info.get('message')}）", file=sys.stderr)
            return 4
        print(f"已创建仓库 {owner}/{repo}（private={private}）")
    elif status != 200:
        print(f"ERROR: 读取仓库失败（HTTP {status}: {info.get('message')}）", file=sys.stderr)
        return 4

    # 空仓库上 Git Data API 会返回 409 "Git Repository is empty."，连 blob 都建不了。
    # 先用 Contents API 落一个引导提交，让仓库有可用的 ref；后面的 tree 是全量树
    # （不带 base_tree），所以这个引导文件不会残留在最终提交里。
    status, _ = request("GET", f"/repos/{owner}/{repo}/git/ref/heads/{branch}", token)
    # 空仓库读 ref 会返回 409 "Git Repository is empty."（不是 404），两种都要走引导提交。
    if status in (404, 409):
        status, boot = request("PUT", f"/repos/{owner}/{repo}/contents/.bootstrap", token, {
            "message": "chore: bootstrap empty repository",
            "content": base64.b64encode(b"init\n").decode("ascii"),
        })
        if status not in (200, 201):
            print(f"ERROR: 初始化空仓库失败（HTTP {status}: {boot.get('message')}）", file=sys.stderr)
            return 4
        # 新仓库的默认分支可能是 main 也可能是 master，跟着实际值走。
        status, repo_info = request("GET", f"/repos/{owner}/{repo}", token)
        if status == 200 and repo_info.get("default_branch"):
            branch = str(repo_info["default_branch"])

    root = Path(__file__).resolve().parent.parent
    files = collect_files(root)
    if not files:
        print("ERROR: 没有找到要上传的文件", file=sys.stderr)
        return 5
    print(f"待上传文件：{len(files)} 个")

    tree_entries = []
    for rel, raw in files:
        status, blob = request("POST", f"/repos/{owner}/{repo}/git/blobs", token, {
            "content": base64.b64encode(raw).decode("ascii"),
            "encoding": "base64",
        })
        if status not in (200, 201):
            print(f"ERROR: 上传 {rel} 失败（HTTP {status}: {blob.get('message')}）", file=sys.stderr)
            return 6
        tree_entries.append({
            "path": rel,
            "mode": "100755" if os.access(root / rel, os.X_OK) and rel.endswith(".sh") else "100644",
            "type": "blob",
            "sha": blob["sha"],
        })

    status, tree = request("POST", f"/repos/{owner}/{repo}/git/trees", token, {"tree": tree_entries})
    if status not in (200, 201):
        print(f"ERROR: 创建 tree 失败（HTTP {status}: {tree.get('message')}）", file=sys.stderr)
        return 7

    status, ref = request("GET", f"/repos/{owner}/{repo}/git/ref/heads/{branch}", token)
    parents = []
    if status == 200 and ref:
        parents = [ref["object"]["sha"]]

    status, commit = request("POST", f"/repos/{owner}/{repo}/git/commits", token, {
        "message": message,
        "tree": tree["sha"],
        "parents": parents,
    })
    if status not in (200, 201):
        print(f"ERROR: 创建 commit 失败（HTTP {status}: {commit.get('message')}）", file=sys.stderr)
        return 8

    if parents:
        status, _ = request("PATCH", f"/repos/{owner}/{repo}/git/refs/heads/{branch}", token, {
            "sha": commit["sha"],
            "force": False,
        })
        if status != 200:
            print(f"ERROR: 更新分支 {branch} 失败", file=sys.stderr)
            return 9
    else:
        status, _ = request("POST", f"/repos/{owner}/{repo}/git/refs", token, {
            "ref": f"refs/heads/{branch}",
            "sha": commit["sha"],
        })
        if status not in (200, 201):
            print("ERROR: 创建分支失败（可能是仓库默认分支名不是 main）", file=sys.stderr)
            return 9

    print(f"完成：https://github.com/{owner}/{repo}/tree/{branch}")
    print(f"提交：{commit['sha'][:10]}（{len(files)} 个文件）")
    print("下一步：仓库的 Actions 会自动跑 build-ipa.yml，从 Actions 的 artifacts 下载 ZCode-unsigned.ipa")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())