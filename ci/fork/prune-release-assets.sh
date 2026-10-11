#!/usr/bin/env bash
# 滚动页（固定 tag）只保留最近 KEEP_GROUPS 组资产。组 = 资产名里的 r<日期>.<短号> 段，
# 同一次构建的 6 个资产共用一个组标识 ⇒ 清理按组整批进行，不会留下半组。
set -euo pipefail

: "${CI_TAG:?CI_TAG 未设置}"
: "${KEEP_GROUPS:?KEEP_GROUPS 未设置}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY 未设置}"

RELEASE_ID=$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$CI_TAG" --jq '.id')

gh api --paginate "repos/$GITHUB_REPOSITORY/releases/$RELEASE_ID/assets" \
    --jq '.[] | "\(.id)\t\(.name)"' >/tmp/ci-assets.tsv

KEEP_GROUPS="$KEEP_GROUPS" python3 - <<'PY' >/tmp/ci-assets-delete.txt
import os, re, sys

keep = int(os.environ["KEEP_GROUPS"])
groups = {}
for line in open("/tmp/ci-assets.tsv", encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    asset_id, name = line.split("\t", 1)
    m = re.search(r"\.r(\d{8})\.([0-9a-f]{7,40})", name)
    if not m:
        print("::warning::资产名里没有版本组标识，跳过：%s" % name, file=sys.stderr)
        continue
    groups.setdefault(m.group(0)[1:], []).append((asset_id, name))

ordered = sorted(groups)
print("滚动页现有 %d 组：%s" % (len(ordered), ", ".join(ordered)), file=sys.stderr)
for key in ordered[:-keep] if keep > 0 else ordered:
    for asset_id, name in groups[key]:
        print("%s\t%s" % (asset_id, name))
PY

if [ ! -s /tmp/ci-assets-delete.txt ]; then
    echo "无需清理（保留组数 $KEEP_GROUPS）"
    exit 0
fi

while IFS=$'\t' read -r id name; do
    echo "  删除旧组资产: $name"
    gh api -X DELETE "repos/$GITHUB_REPOSITORY/releases/assets/$id" >/dev/null
done </tmp/ci-assets-delete.txt
