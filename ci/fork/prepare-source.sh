#!/usr/bin/env bash
# 构建前置：把 CI 版本串注入 configure.ac，并按上游 release tag 生成 ChangeLog。
# 版本串只改工作区、不产生提交 —— fork 的 master 与上游保持逐字一致，同步时不冲突。
set -euo pipefail

cd "$(dirname "$0")/../.."

usage() {
    echo "usage: $0 inject <version>" >&2
    echo "       $0 changelog <base-tag>" >&2
    exit 2
}

cmd="${1:-}"
arg="${2:-}"

case "$cmd" in
inject)
    [ -n "$arg" ] || usage
    VERSION="$arg" python3 - <<'PY'
import os, re, sys

version = os.environ["VERSION"]
path = "configure.ac"
src = open(path, encoding="utf-8").read()
# 版本串同时决定 aria2c --version、tar 包名、zip 内目录名、man page 里的版本（conf.py.in 取 @PACKAGE_VERSION@），
# 因此必须改 AC_INIT 本身，而不是只改文件名。
new, hits = re.subn(r'^AC_INIT\(\[aria2\],\[[^]]*\]',
                    'AC_INIT([aria2],[%s]' % version, src, count=1, flags=re.M)
if hits != 1:
    sys.exit("configure.ac 的 AC_INIT 命中 %d 处（期望 1 处），结构可能已变" % hits)
open(path, "w", encoding="utf-8").write(new)
PY
    grep -qF "$arg" configure.ac
    echo "configure.ac → $(grep '^AC_INIT' configure.ac)"
    ;;
changelog)
    [ -n "$arg" ] || usage
    # 官方 tar 包里的 ChangeLog 就是这份内容（上游 makerelease 用同一条命令生成）
    git log --pretty=fuller --date=short "refs/tags/$arg..HEAD" >ChangeLog
    echo "ChangeLog: $(wc -l <ChangeLog) 行（$arg..HEAD）"
    ;;
*)
    usage
    ;;
esac
