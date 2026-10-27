#!/bin/bash
# 用已抓取的 OSM 缓存构建全部线路真实线形并原地替换。
# 原始文件首次替换前备份到 tools/cache12306/lines_backup/。
# 校验不过的线路 build 会原样输出旧文档（KEEP-OLD），不会破坏数据。
cd "$(dirname "$0")/.." || exit 1
OSM=tools/cache12306/osm
BAK=tools/cache12306/lines_backup
LOG="$OSM/build.log"
mkdir -p "$BAK"
echo "[$(date +%T)] build start" >> "$LOG"

ok=0; keep=0; fail=0
for f in data/lines/*.json; do
  id=$(basename "$f" .json)
  # stdin = 线路文档 + 该线全部 OSM 文档（整线缓存 + 站对缓存，顺序无关）
  { cat "$f"; cat "$OSM/$id.json" 2>/dev/null; cat "$OSM/$id"__*.json 2>/dev/null; } \
    | python tools/osm_geometry.py build "$id" > "$f.new" 2>>"$LOG"
  if [ -s "$f.new" ]; then
    if cmp -s "$f" "$f.new"; then
      keep=$((keep+1)); rm -f "$f.new"
    else
      [ -f "$BAK/$id.json" ] || cp "$f" "$BAK/$id.json"
      mv "$f.new" "$f"
      ok=$((ok+1))
    fi
  else
    fail=$((fail+1)); echo "[build-fail] $id" >> "$LOG"
  fi
done
echo "[$(date +%T)] build done: replaced=$ok keep-old=$keep fail=$fail (backup: $BAK)" >> "$LOG"
echo "replaced=$ok keep-old=$keep fail=$fail"
