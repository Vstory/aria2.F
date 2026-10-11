#!/usr/bin/env bash
# 由上游 Dockerfile 生成构建用临时副本：把源码来源从上游 aria2/aria2 换成 fork 的指定 commit，
# 并在容器内注入 CI 版本串。上游文件一字不改（fork 与上游保持可同步）。
#
# 上游改动 Dockerfile 里这几行时本脚本会直接 fail —— 这是刻意的「响铃」：
# 静默失配会构建出「其实是上游源码 / 版本号没带短号」的假货，比 CI 报红危险得多。
set -euo pipefail

SRC="${1:?usage: patch-dockerfile.sh <src-dockerfile> <dst-dockerfile>}"
DST="${2:?usage: patch-dockerfile.sh <src-dockerfile> <dst-dockerfile>}"
: "${FORK_REPO:?FORK_REPO 未设置}"
: "${ARIA2_SHA:?ARIA2_SHA 未设置}"
: "${VERSION:?VERSION 未设置}"

SRC="$SRC" DST="$DST" python3 - <<'PY'
import os, re, sys
from urllib.parse import urlparse

src_path, dst_path = os.environ["SRC"], os.environ["DST"]
fork = os.environ["FORK_REPO"].rstrip("/")
fork_slug = urlparse(fork).path.strip("/")
sha, version = os.environ["ARIA2_SHA"], os.environ["VERSION"]

text = open(src_path, encoding="utf-8").read()
problems = []
had_sentinel = "api.github.com/repos/aria2/aria2/git/" in text


def sed_inject(prefix=""):
    return (
        '%ssed -i "s|^AC_INIT(\\[aria2\\],\\[[^]]*\\]|AC_INIT([aria2],[%s]|" '
        'configure.ac && grep -qF "%s" configure.ac'
        % ("%s && " % prefix if prefix else "", version, version)
    )


# 按 commit 取源码，而不是按分支名：版本串里的短号与实际编进产物的源码必须同源，
# 否则 dispatch 后到容器 clone 之间上游（或本 fork）再前进一次就会静默错位。
fetch_cmd = (
    "git init -q {dir} && cd {dir} && git remote add origin {fork} && "
    "git fetch -q --depth 1 origin {sha} && git checkout -q FETCH_HEAD"
)
clone_old = r"git clone -b \$ARIA2_VERSION --depth 1 https://github\.com/aria2/aria2"

# 形态 A：clone 与其后的 cd 在同一条 RUN 里（Dockerfile.mingw）
pat_a = re.compile(clone_old + r" && \\\n[ \t]*cd aria2")
new_a = "%s && %s" % (fetch_cmd.format(dir="aria2", fork=fork, sha=sha), sed_inject())
# 形态 B：clone 独占一行（Dockerfile.android，紧随其后是 WORKDIR）
pat_b = re.compile(clone_old + r"[ \t]*$", re.M)
new_b = "%s && %s" % (fetch_cmd.format(dir="/root/build/aria2", fork=fork, sha=sha), sed_inject())

text, hits_a = pat_a.subn(lambda _: new_a, text, count=1)
text, hits_b = pat_b.subn(lambda _: new_b, text, count=1)
if hits_a + hits_b != 1:
    problems.append("git clone 行命中 %d 处（期望 1 处）：上游 Dockerfile 结构已变" % (hits_a + hits_b))

# ADD 行是 Docker 层缓存的哨兵（mingw 有、android 没有）。上游写的是 /git/$ARIA2_REF，
# 而 /git/{sha} 不是 GitHub 的端点（404）—— 必须换成 /commits/{sha}。
text, hits_add = re.subn(r"api\.github\.com/repos/aria2/aria2/git/",
                         "api.github.com/repos/%s/commits/" % fork_slug, text)
if hits_add > 1:
    problems.append("ADD 缓存哨兵命中 %d 处（期望 0 或 1 处）" % hits_add)
if had_sentinel and ("api.github.com/repos/%s/commits/$ARIA2_REF" % fork_slug) not in text:
    problems.append("ADD 缓存哨兵未改成 /commits/$ARIA2_REF 形态")

for stale in ("github.com/aria2/aria2", "api.github.com/repos/aria2/aria2"):
    if stale in text:
        problems.append("替换后仍残留上游地址 %s" % stale)
# 注入语句固定含版本串两处（sed 的替换段 + grep 的字面量），少一处就是语句被改坏
if text.count(version) != 2 or ('grep -qF "%s" configure.ac' % version) not in text:
    problems.append("替换后版本串 %s 出现 %d 次（期望 2 次），注入语句可能不完整"
                    % (version, text.count(version)))
if fork not in text:
    problems.append("替换后未出现 fork 地址 %s" % fork)
if text.count("git fetch -q --depth 1 origin %s" % sha) != 1:
    problems.append("未按 commit %s 取源码" % sha)

if problems:
    for p in problems:
        print("::error::" + p, file=sys.stderr)
    sys.exit(1)

open(dst_path, "w", encoding="utf-8").write(text)
PY

echo "--- $DST 的构建入口（改后）---"
grep -nE "git (init|clone|fetch|checkout)|ADD .*api\.github" "$DST"
