#!/usr/bin/env bash
# 由上游 Dockerfile 生成构建用临时副本：把源码来源从上游 aria2/aria2 换成 fork 的指定 commit，
# 并在容器内注入 CI 版本串。上游文件一字不改（fork 与上游保持可同步）。
#
# Android 多架构：设 ANDROID_HOST 为 NDK 三元组（aarch64-linux-android / armv7a-linux-androideabi /
# i686-linux-android / x86_64-linux-android），脚本会连带改掉 HOST 行与 OpenSSL 的专用 target；
# 不设则维持上游的 aarch64。
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
# --version 输出里的 fork 版权行：补丁随源码进容器（fetch 下来的就是 fork 仓库，补丁在 ci/fork/patches/）。
# 源码包与容器必须打同一份补丁，否则二进制与「对应源码」对不上（GPL 的 source 义务）。
# 0002 只对 Windows 生效（#ifdef __MINGW32__），android 打上也无副作用 —— 两个平台打同一组补丁，
# 源码包才算完整对应。
FORK_PATCHES = ["ci/fork/patches/0001-version-copyright.patch",
                "ci/fork/patches/0002-windows-ca-store.patch"]
for p in FORK_PATCHES:
    if not os.path.exists(p):
        problems.append("补丁文件缺失：%s" % p)
apply_cmd = " && ".join("git apply %s" % p for p in FORK_PATCHES)
clone_old = r"git clone -b \$ARIA2_VERSION --depth 1 https://github\.com/aria2/aria2"

# Windows 换用 OpenSSL 后端：WinTLS(SChannel) 只请求 TLS 1.1/1.2，连不上只开 TLS 1.3 的站点
# （SChannel 回 SEC_E_UNSUPPORTED_FUNCTION / 80090302）。上游 mingw-config 写死
# --without-openssl，容器内改工作区副本即可，上游文件照旧一字不改。
# 配套：0002 补丁顺手给 crypt32 依赖（OpenSSL 未启用的 WS2_32 族库不会自动带进来）。
mingw_openssl_build = """ENV OPENSSL_VERSION=1.1.1w
RUN curl -L -O --retry 5 --retry-delay 5 --connect-timeout 20 \\
        https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz && \\
    tar xf openssl-$OPENSSL_VERSION.tar.gz && \\
    cd openssl-$OPENSSL_VERSION && \\
    if [ "${HOST%%-*}" = "i686" ]; then OS_TARGET=mingw; else OS_TARGET=mingw64; fi && \\
    ./Configure no-shared no-tests no-asm --prefix=/usr/local/$HOST \\
        --cross-compile-prefix=$HOST- $OS_TARGET && \\
    make -j$(nproc) && make install_sw

"""
# 单引号包住 sed 表达式，$PREFIX 留给容器内的 shell 展开（mingw-config 里就是字面 $PREFIX）
mingw_config_fix = (
    "sed -i 's|--without-openssl|--with-openssl|' mingw-config && "
    'grep -qF -- "--with-openssl" mingw-config && '
    '! grep -qF -- "--without-openssl" mingw-config && '
    """sed -i 's|LDFLAGS="-L$PREFIX/lib"|LDFLAGS="-L$PREFIX/lib -lcrypt32"|' mingw-config && """
    'grep -qF -- "-lcrypt32" mingw-config'
)

# 形态 A：clone 与其后的 cd 在同一条 RUN 里（Dockerfile.mingw）
pat_a = re.compile(clone_old + r" && \\\n[ \t]*cd aria2")
new_a = "%s && %s && %s && %s" % (
    fetch_cmd.format(dir="aria2", fork=fork, sha=sha), sed_inject(), apply_cmd,
    mingw_config_fix)
# 形态 B：clone 独占一行（Dockerfile.android，紧随其后是 WORKDIR）
pat_b = re.compile(clone_old + r"[ \t]*$", re.M)
new_b = "%s && %s && %s" % (
    fetch_cmd.format(dir="/root/build/aria2", fork=fork, sha=sha), sed_inject(), apply_cmd)

text, hits_a = pat_a.subn(lambda _: new_a, text, count=1)
text, hits_b = pat_b.subn(lambda _: new_b, text, count=1)
if hits_a + hits_b != 1:
    problems.append("git clone 行命中 %d 处（期望 1 处）：上游 Dockerfile 结构已变" % (hits_a + hits_b))
if text.count(apply_cmd) != 1:
    problems.append("补丁应用语句命中 %d 处（期望 1 处）" % text.count(apply_cmd))
if text.count(mingw_config_fix) != hits_a:
    problems.append("mingw-config 改写语句命中 %d 处（期望 %d 处，应与形态 A 一致）"
                    % (text.count(mingw_config_fix), hits_a))

# Windows 侧补 OpenSSL 交叉编译：插在 ARG ARIA2_VERSION 之前（依赖已装完）。用 ./mingw-config
# 判定文件身份，Dockerfile.android 不含该串因而不会中招。
if "./mingw-config" in text:
    anchor = "ARG ARIA2_VERSION=master"
    if text.count(anchor) != 1:
        problems.append("mingw 的 %s 锚点命中 %d 处（期望 1 处）：上游结构已变"
                        % (anchor, text.count(anchor)))
    else:
        text = text.replace(anchor, mingw_openssl_build + anchor, 1)

# ADD 行是 Docker 层缓存的哨兵（mingw 有、android 没有）。上游写的是 /git/$ARIA2_REF，
# 而 /git/{sha} 不是 GitHub 的端点（404）—— 必须换成 /commits/{sha}。
text, hits_add = re.subn(r"api\.github\.com/repos/aria2/aria2/git/",
                         "api.github.com/repos/%s/commits/" % fork_slug, text)
if hits_add > 1:
    problems.append("ADD 缓存哨兵命中 %d 处（期望 0 或 1 处）" % hits_add)
if had_sentinel and ("api.github.com/repos/%s/commits/$ARIA2_REF" % fork_slug) not in text:
    problems.append("ADD 缓存哨兵未改成 /commits/$ARIA2_REF 形态")

# gmplib.org 从 CI 侧连不上（实测单个源 TCP 超时 135s，其余五个源都正常），换成 GNU 官方镜像的
# 同版本 tarball；文件名不变，后续 tar xf / configure 步骤无需跟着改。
text, hits_gmp = re.subn(r"https://gmplib\.org/download/gmp/", "https://ftp.gnu.org/gnu/gmp/", text)
if hits_gmp > 1 or "gmplib.org" in text:
    problems.append("gmp 下载源未按预期换成 GNU 镜像（命中 %d 处，残留 %s）"
                    % (hits_gmp, "gmplib.org" in text))

# 给依赖下载的 curl 补重试与连接超时：默认连接超时会让一次抖动拖满两分钟才失败，白烧整轮构建
before_curls = text.count("curl -L -O http")
text, hits_curl = re.subn(r"curl -L -O http",
                          "curl -L -O --retry 5 --retry-delay 5 --connect-timeout 20 http", text)
if hits_curl != before_curls:
    problems.append("curl 加固命中 %d 处（期望 %d 处）" % (hits_curl, before_curls))

# Android 的架构在 Dockerfile 里是写死的两处：HOST（CC / CXX 由它派生）与 OpenSSL 的专用 target。
# OpenSSL 的 Android target 名与 NDK 三元组不同名，必须显式映射；其余依赖与 aria2 自己都吃
# --host=$HOST，会自动跟随。ANDROID_HOST 缺省时维持上游的 aarch64 行为。
ANDROID_OPENSSL_TARGET = {
    "aarch64-linux-android": "android-arm64",
    "armv7a-linux-androideabi": "android-arm",
    "i686-linux-android": "android-x86",
    "x86_64-linux-android": "android-x86_64",
}
if "HOST=aarch64-linux-android" in text:
    android_host = os.environ.get("ANDROID_HOST", "").strip() or "aarch64-linux-android"
    openssl_target = ANDROID_OPENSSL_TARGET.get(android_host)
    if openssl_target is None:
        problems.append("ANDROID_HOST=%s 不在已知架构表里（缺 OpenSSL target 映射）" % android_host)
    else:
        text, hits_host = re.subn(re.escape("HOST=aarch64-linux-android"),
                                  "HOST=%s" % android_host, text)
        text, hits_ssl = re.subn(re.escape("--prefix=$PREFIX android-arm64"),
                                 "--prefix=$PREFIX %s" % openssl_target, text)
        if hits_host != 1:
            problems.append("android HOST 行命中 %d 处（期望 1 处）：上游 Dockerfile 结构已变" % hits_host)
        if hits_ssl != 1:
            problems.append("OpenSSL android target 命中 %d 处（期望 1 处）：上游 Dockerfile 结构已变" % hits_ssl)
        if android_host != "aarch64-linux-android" and "aarch64" in text:
            problems.append("替换后仍残留 aarch64（架构未改全）")
        if "CC=$TOOLCHAIN/bin/$HOST$API-clang" not in text:
            problems.append("CC 派生行被改动（CC / CXX 必须继续由 $HOST 派生）")

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
