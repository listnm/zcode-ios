#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""下载最近一次成功运行产出的 IPA 到 dist/ 目录。

GitHub 的 artifact 接口返回的是 zip（里面是 .ipa），这里解包并落盘。
"""

from __future__ import annotations

import io
import json
import os
import sys
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

API = "https://api.github.com"
TOKEN = os.environ.get("GITHUB_TOKEN", "").strip()
OWNER = os.environ.get("GITHUB_OWNER", "").strip()
REPO = os.environ.get("GITHUB_REPO", "").strip()


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """不自动跟随重定向。

    artifact 的 zip 接口会 302 到 Azure Blob 的 SAS 地址，而 SAS 地址**不接受**
    Authorization 头；urllib 默认跟随重定向时会把头一起带过去，于是拿到 401。
    这里先拿到 Location，再不带任何认证头去取。
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D401
        return None


def get(url: str) -> bytes:
    request = urllib.request.Request(url)
    request.add_header("Authorization", f"Bearer {TOKEN}")
    request.add_header("Accept", "application/vnd.github+json")
    request.add_header("User-Agent", "zcode-ipa")
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        with opener.open(request, timeout=300) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.code not in (301, 302, 303, 307, 308):
            raise
        location = error.headers.get("Location")
        if not location:
            raise
        # SAS 地址自带签名，不能再带 Authorization。
        with urllib.request.urlopen(location, timeout=300) as response:
            return response.read()


def main() -> int:
    if not TOKEN or not OWNER or not REPO:
        print("ERROR: 需要 GITHUB_TOKEN / GITHUB_OWNER / GITHUB_REPO", file=sys.stderr)
        return 2

    payload = json.loads(get(f"{API}/repos/{OWNER}/{REPO}/actions/artifacts?per_page=20"))
    artifacts = [a for a in payload.get("artifacts", []) if not a.get("expired")]
    if not artifacts:
        print("ERROR: 没有可下载的 artifact（可能还没跑过成功构建）", file=sys.stderr)
        return 3

    # 接口返回顺序不保证是最新在前（实测按 id 升序），所以显式按 created_at 取最新。
    candidates = [a for a in artifacts if a["name"].startswith("ZCode")]
    if not candidates:
        candidates = artifacts
    artifact = max(candidates, key=lambda a: a["created_at"])
    print(f"artifact: {artifact['name']} ({artifact['size_in_bytes']} bytes, id={artifact['id']})")

    archive = zipfile.ZipFile(io.BytesIO(get(f"{API}/repos/{OWNER}/{REPO}/actions/artifacts/{artifact['id']}/zip")))
    target = Path("dist")
    target.mkdir(exist_ok=True)
    written = []
    for name in archive.namelist():
        if not name.lower().endswith((".ipa", ".app", ".zip")):
            continue
        data = archive.read(name)
        destination = target / Path(name).name
        destination.write_bytes(data)
        written.append((destination, len(data)))

    if not written:
        print("ERROR: zip 里没有 .ipa", file=sys.stderr)
        return 4
    for path, size in written:
        print(f"写出 {path}（{size} 字节）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())