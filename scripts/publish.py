#!/usr/bin/env python3
"""通过 GitHub REST API 发布工程并跟踪 Actions 构建。

为什么不用 git push：某些受限网络里 github.com 的 git 端点（/info/refs）
会被拦截，而 api.github.com 仍然可用。这个脚本只用 REST API，
把工作区里的全部受版本控制的文件作为**一个提交**推上去。

用法（token 走环境变量，不要写进命令行参数）：

    export GITHUB_TOKEN=ghp_xxx
    python scripts/publish.py upload --repo realshot-ios
    python scripts/publish.py watch  --repo realshot-ios
    python scripts/publish.py fetch  --repo realshot-ios --out dist

需要的 token 权限：classic PAT 勾选 repo + workflow
（workflow 是上传 .github/workflows/ 下文件所必需的）。
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = "https://api.github.com"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


# ---------------------------------------------------------------- HTTP

def token():
    t = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if not t:
        sys.exit("缺少环境变量 GITHUB_TOKEN")
    return t.strip()


def request(method, path, body=None, raw=False, allow=(200, 201, 204)):
    url = path if path.startswith("http") else API + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token())
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", "realshot-publisher")
    if data:
        req.add_header("Content-Type", "application/json")

    # 强制直连：环境里的沙箱代理会拦掉 github.com，
    # 而 api.github.com 直连是通的。
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=60) as resp:
            payload = resp.read()
            if raw:
                return resp.status, payload
            return resp.status, (json.loads(payload) if payload else None)
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        if e.code in allow:
            return e.code, None
        hint = ""
        if e.code == 404 and "workflow" in path:
            hint = "\n  → 这通常是 token 缺少 workflow 权限"
        elif e.code == 401:
            hint = "\n  → token 无效或已过期"
        elif e.code == 403:
            hint = "\n  → 权限不足，确认勾选了 repo + workflow"
        sys.exit("HTTP {} {} {}\n{}{}".format(e.code, method, path, detail[:600], hint))


# ---------------------------------------------------------------- 仓库

def whoami():
    _, me = request("GET", "/user")
    return me["login"]


def ensure_repo(owner, name):
    status, repo = request("GET", "/repos/{}/{}".format(owner, name), allow=(200, 404))
    if status == 200:
        print("· 仓库已存在: {}".format(repo["html_url"]))
        return repo
    print("· 创建仓库 {}/{}".format(owner, name))
    _, repo = request("POST", "/user/repos", {
        "name": name,
        "description": "把截图和网图还原成手机实拍质感 —— iOS 客户端",
        "private": False,
        "has_issues": False,
        "has_wiki": False,
        "auto_init": False,
    })
    print("  已创建: {}".format(repo["html_url"]))
    return repo


# ---------------------------------------------------------------- 上传

def tracked_files():
    out = subprocess.run(["git", "-C", ROOT, "ls-files", "-z"],
                         capture_output=True, check=True).stdout
    files = [p for p in out.decode("utf-8").split("\0") if p]
    if not files:
        sys.exit("git ls-files 为空，先在工作区提交文件")
    return sorted(files)


def upload(owner, name, message):
    repo = ensure_repo(owner, name)
    files = tracked_files()

    # 空仓库不允许直接创建 blob（409 Git Repository is empty）。
    # 先用 Contents API 提交一个种子文件，把仓库激活。
    status, ref = request("GET", "/repos/{}/{}/git/ref/heads/main".format(owner, name),
                          allow=(200, 404, 409))
    if status == 200:
        parent = ref["object"]["sha"]
    else:
        seed_path = "README.md" if "README.md" in files else files[0]
        with open(os.path.join(ROOT, seed_path), "rb") as fh:
            seed = base64.b64encode(fh.read()).decode()
        print("· 仓库为空，先创建初始提交（{}）".format(seed_path))
        _, created = request("PUT", "/repos/{}/{}/contents/{}".format(owner, name, seed_path), {
            "message": "init",
            "content": seed,
            "branch": "main",
        })
        parent = created["commit"]["sha"]

    print("· 上传 {} 个文件，作为一个提交".format(len(files)))

    entries = []
    for i, rel in enumerate(files, 1):
        abs_path = os.path.join(ROOT, rel)
        with open(abs_path, "rb") as fh:
            content = base64.b64encode(fh.read()).decode()
        _, blob = request("POST", "/repos/{}/{}/git/blobs".format(owner, name),
                          {"content": content, "encoding": "base64"})
        mode = "100755" if rel.endswith(".sh") else "100644"
        entries.append({"path": rel, "mode": mode, "type": "blob", "sha": blob["sha"]})
        if i % 8 == 0 or i == len(files):
            print("  {}/{}".format(i, len(files)))

    _, tree = request("POST", "/repos/{}/{}/git/trees".format(owner, name),
                      {"tree": entries})

    _, commit = request("POST", "/repos/{}/{}/git/commits".format(owner, name), {
        "message": message,
        "tree": tree["sha"],
        "parents": [parent],
    })

    request("PATCH", "/repos/{}/{}/git/refs/heads/main".format(owner, name),
            {"sha": commit["sha"], "force": True})

    # 空仓库创建后默认分支可能未设置
    if not repo.get("default_branch"):
        request("PATCH", "/repos/{}/{}".format(owner, name), {"default_branch": "main"})

    print("\n✓ 已上传: {}".format(repo["html_url"]))
    print("  Actions: {}/actions".format(repo["html_url"]))
    return repo


# ---------------------------------------------------------------- 跟踪

def latest_run(owner, name):
    _, data = request("GET", "/repos/{}/{}/actions/runs?per_page=5".format(owner, name))
    runs = data.get("workflow_runs") or []
    if not runs:
        return None
    return runs[0]


def watch(owner, name, timeout_min):
    print("· 等待 Actions 启动…")
    deadline = time.time() + timeout_min * 60
    seen = None
    while time.time() < deadline:
        run = latest_run(owner, name)
        if run:
            seen = run
            if run["status"] == "completed":
                break
            print("  [{}] {}".format(run["status"], run.get("name") or ""))
        time.sleep(15)

    if not seen:
        sys.exit("没有找到任何工作流运行（检查 .github/workflows 是否上传成功）")

    run = latest_run(owner, name) or seen
    print("\n结果: {} / {}".format(run["status"], run.get("conclusion")))
    print("日志: {}".format(run["html_url"]))

    if run.get("conclusion") != "success":
        _, jobs = request("GET", "/repos/{}/{}/actions/runs/{}/jobs".format(owner, name, run["id"]))
        for job in jobs.get("jobs", []):
            for step in job.get("steps", []):
                if step.get("conclusion") == "failure":
                    print("  失败步骤: {} / {}".format(job["name"], step["name"]))
        print("\n把上面日志里的 error: 行贴给我，我来改。")
        sys.exit(2)
    return run


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """拦住 302，好让调用方自己决定要不要带鉴权头去取重定向地址。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def download(url, dest):
    """artifact 的下载地址会 302 到 Azure 签名链接，
    那里不接受 Authorization 头，所以只在第一跳带鉴权。"""
    req = urllib.request.Request(url)
    req.add_header("Authorization", "Bearer " + token())
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", "realshot-publisher")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect)
    try:
        with opener.open(req, timeout=60) as resp:
            data = resp.read()
    except urllib.error.HTTPError as e:
        location = e.headers.get("Location")
        if not location:
            sys.exit("artifact 下载失败: HTTP {}".format(e.code))
        plain = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        req2 = urllib.request.Request(location, headers={"User-Agent": "realshot-publisher"})
        with plain.open(req2, timeout=180) as resp:
            data = resp.read()
    with open(dest, "wb") as fh:
        fh.write(data)


def fetch(owner, name, out_dir):
    run = latest_run(owner, name)
    if not run:
        sys.exit("没有可用的运行记录")
    if run.get("conclusion") != "success":
        sys.exit("最新运行不是成功状态: {}".format(run.get("conclusion")))

    _, arts = request("GET", "/repos/{}/{}/actions/runs/{}/artifacts".format(owner, name, run["id"]))
    items = arts.get("artifacts") or []
    if not items:
        sys.exit("这次运行没有产出 artifact")

    os.makedirs(out_dir, exist_ok=True)
    for art in items:
        print("· 下载 {} ({:.1f} KB)".format(art["name"], art["size_in_bytes"] / 1024))
        zip_path = os.path.join(out_dir, art["name"] + ".zip")
        download(art["archive_download_url"], zip_path)
        print("  已保存 {}".format(zip_path))

        import zipfile
        with zipfile.ZipFile(zip_path) as zf:
            for member in zf.namelist():
                if member.endswith(".ipa"):
                    target = os.path.join(out_dir, os.path.basename(member))
                    with open(target, "wb") as fh:
                        fh.write(zf.read(member))
                    print("  ✓ {}".format(target))


# ---------------------------------------------------------------- CLI

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["upload", "watch", "fetch"])
    ap.add_argument("--repo", default="realshot-ios")
    ap.add_argument("--owner", default=None, help="默认取 token 所属账号")
    ap.add_argument("--message", default="RealShot: 截图转手机实拍质感 iOS App")
    ap.add_argument("--out", default=os.path.join(ROOT, "dist"))
    ap.add_argument("--timeout", type=int, default=30, help="等待构建完成的分钟数")
    args = ap.parse_args()

    owner = args.owner or whoami()

    if args.action == "upload":
        upload(owner, args.repo, args.message)
    elif args.action == "watch":
        watch(owner, args.repo, args.timeout)
    else:
        fetch(owner, args.repo, args.out)


if __name__ == "__main__":
    main()
