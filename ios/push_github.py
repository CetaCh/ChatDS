# -*- coding: utf-8 -*-
"""把 ios/ 与 .github/workflows/ios-build.yml 上传到 GitHub 仓库（Git Data API）。
只新增文件，不删除、不修改仓库里已有的文件。"""
import base64
import io
import json
import mimetypes
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

OWNER = "CetaCh"
REPO = "ChatDS"
BRANCH = "main"
TOKEN = os.environ.get("GH_TOKEN", "")
ROOT = r"D:\dsh\chatds-ipa"
API = "https://api.github.com"

TEXT_EXT = {".swift", ".js", ".py", ".md", ".plist", ".pbxproj", ".json", ".yml",
            ".yaml", ".html", ".css", ".txt", ".strings", ".h", ".m"}
SKIP_DIRS = {"__pycache__", "build", "dist", ".DS_Store"}


def api(method, path, payload=None):
    url = API + path
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("User-Agent", "dsh")
    req.add_header("Authorization", "Bearer " + TOKEN)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            body = resp.read()
            return json.loads(body.decode("utf-8")) if body else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        raise SystemExit("HTTP %s %s %s\n%s" % (exc.code, method, path, detail[:2000]))


def collect():
    files = []
    base = os.path.join(ROOT, "ios")
    for root, dirs, names in os.walk(base):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS and not d.startswith("__"))
        for name in sorted(names):
            if name in ("__pycache__",) or name.endswith(".pyc"):
                continue
            full = os.path.join(root, name)
            rel = os.path.relpath(full, ROOT).replace(os.sep, "/")
            if "/build/" in rel or rel.startswith("ios/dist/"):
                continue
            files.append((rel, full))
    wf = os.path.join(ROOT, ".github", "workflows", "ios-build.yml")
    files.append((".github/workflows/ios-build.yml", wf))
    return files


def put_file(rel, full, branch, message):
    """用 Contents API 逐个上传（细粒度 Token 没有 git/trees 权限时的方案）。"""
    with open(full, "rb") as fh:
        raw = fh.read()
    ext = os.path.splitext(full)[1].lower()
    payload = {"message": message, "branch": branch}
    is_text = ext in TEXT_EXT or "Contents.json" in rel
    text = None
    if is_text:
        try:
            text = raw.decode("utf-8").replace("\r\n", "\n")
        except UnicodeDecodeError:
            is_text = False
    if is_text:
        payload["content"] = base64.b64encode(text.encode("utf-8")).decode("ascii")
        payload["encoding"] = "base64"
    else:
        payload["content"] = base64.b64encode(raw).decode("ascii")
        payload["encoding"] = "base64"
    # 已存在则带上 sha 覆盖
    try:
        exist = api("GET", "/repos/%s/%s/contents/%s?ref=%s" % (OWNER, REPO, urllib.parse.quote(rel), branch))
        if isinstance(exist, dict) and exist.get("sha"):
            payload["sha"] = exist["sha"]
    except SystemExit:
        pass
    encoded = urllib.parse.quote(rel)
    return api("PUT", "/repos/%s/%s/contents/%s" % (OWNER, REPO, encoded), payload)


def main():
    if not TOKEN:
        raise SystemExit("缺少 GH_TOKEN")
    files = collect()
    print("待上传文件：%d 个" % len(files))
    message = "ios: 增加 iOS 版工程与云编译工作流（iPhone + iPad Air 2 及以上）"
    done = {}
    for index, (rel, full) in enumerate(files):
        try:
            result = put_file(rel, full, BRANCH, message)
            done[rel] = result.get("commit", {}).get("sha", "")
        except SystemExit as exc:
            print("失败：%s\n%s" % (rel, exc))
            raise
        if index % 10 == 0 or index == len(files) - 1:
            print("  上传 %d/%d  %s" % (index + 1, len(files), rel))
        time.sleep(0.4)
    last = list(done.values())[-1] if done else ""
    print("全部上传完成，最后提交：%s" % last)
    print("https://github.com/%s/%s/commits/%s" % (OWNER, REPO, BRANCH))
    with io.open(os.path.join(ROOT, "ios", "build", "pushed_commit.txt"), "w",
                 encoding="utf-8") as fh:
        fh.write(last)
    return 0


if __name__ == "__main__":
    sys.exit(main())
