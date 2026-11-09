#!/usr/bin/env bash
# 定向重建：仅重建给定清单中的线路（幂等：cmp 相同则不动）。
# 用法: bash tools/rebuild_keepold.sh <ids.txt（每行一个线路 id）>
set -u
cd "$(dirname "$0")/.." || exit 1
OSM=tools/cache12306/osm
BAK=tools/cache12306/lines_backup
IDS_FILE="${1:?需要 ids 清单文件}"
ok=0; keep=0; fail=0
for id in $(cat "$IDS_FILE"); do
  f="data/lines/$id.json"
  [ -f "$f" ] || continue
  { cat "$f"; cat "$OSM/$id.json" 2>/dev/null; cat "$OSM/$id"__*.json 2>/dev/null; } \
    | python tools/osm_geometry.py build "$id" > "$f.new" 2>>"$OSM/build.log"
  if [ -s "$f.new" ]; then
    if cmp -s "$f" "$f.new"; then
      keep=$((keep+1)); rm -f "$f.new"
    else
      [ -f "$BAK/$id.json" ] || cp "$f" "$BAK/$id.json"
      mv "$f.new" "$f"
      ok=$((ok+1))
      echo "[rebuild] $id => 采纳"
    fi
  else
    fail=$((fail+1)); rm -f "$f.new"
    echo "[rebuild] $id => 构建失败"
  fi
done
echo "rebuild done: replaced=$ok keep-old=$keep fail=$fail"
