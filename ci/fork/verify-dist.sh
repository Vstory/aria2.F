#!/usr/bin/env bash
# 源码包门禁：缺 sphinx / 缺 rst2html 时上游 Makefile 会静默退化成空 stub（不报错），
# 出包前必须把这种退化抓出来，否则发布出去的源码包是残缺的。
set -euo pipefail

cd "$(dirname "$0")/../.."

VERSION="${1:?usage: verify-dist.sh <version> [allow-stub-man]}"
ALLOW_STUB_MAN="${2:-false}"

fail() { echo "::error::$*"; exit 1; }

for ext in tar.gz tar.bz2 tar.xz; do
    f="aria2-$VERSION.$ext"
    [ -f "$f" ] || fail "缺源码包：$f"
    size=$(stat -c%s "$f")
    [ "$size" -gt 500000 ] || fail "$f 只有 $size 字节，疑似空包"
    top=$(tar -tf "$f" | head -1)
    [ "$top" = "aria2-$VERSION/" ] || fail "$f 首层目录是 $top，期望 aria2-$VERSION/"
    echo "  ✅ $f ($size 字节, 顶层 $top)"
done

[ -f README.html ] || fail "缺 README.html"
grep -q "Readme has not been built" README.html && fail "README.html 是 rst2html 缺失时的占位文件"
echo "  ✅ README.html ($(stat -c%s README.html) 字节)"

for lang in en ru pt; do
    man="doc/manual-src/$lang/_build/man/aria2c.1"
    [ -f "$man" ] || fail "缺 man page：$man"
    size=$(stat -c%s "$man")
    if [ "$size" -lt 10240 ]; then
        msg="man page $man 只有 $size 字节，是 sphinx 缺失时的空 stub"
        if [ "$ALLOW_STUB_MAN" = "true" ]; then
            echo "  ⚠️  $msg（ALLOW_STUB_MAN=true，按警告放行）"
        else
            fail "$msg（修 sphinx 版本，或显式把 ALLOW_STUB_MAN 设为 true）"
        fi
    else
        echo "  ✅ $man ($size 字节)"
    fi
done
