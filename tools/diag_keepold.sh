#!/usr/bin/env bash
# keep-old 批量诊断：DIAG=1 逐线构建，stderr 收集到 keepold_diag.txt
set -u
cd "$(dirname "$0")/.." || exit 1
OSM=tools/cache12306/osm
IDS_FILE="$OSM/keepold_ids.txt"
OUT="$OSM/keepold_diag.txt"
: > "$OUT"
for id in $(cat "$IDS_FILE"); do
  f="data/lines/$id.json"
  [ -f "$f" ] || continue
  { cat "$f"; cat "$OSM/$id.json" 2>/dev/null; cat "$OSM/$id"__*.json 2>/dev/null; } \
    | DIAG=1 python tools/osm_geometry.py build "$id" >/dev/null 2>>"$OUT"
  echo "=== $id done" >> "$OUT"
done
echo "diag written: $OUT"
