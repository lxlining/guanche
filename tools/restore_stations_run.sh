#!/bin/bash
# 还原被构建错误拖拽的车站坐标（对照 lines_backup，偏差 >25km）。
# 幂等：重跑无变化。
cd "$(dirname "$0")/.." || exit 1
OSM=tools/cache12306/osm
python tools/restore_stations.py plan > "$OSM/restore_fixes.json"
cnt=0
for f in data/lines/*.json; do
  { cat "$f"; cat "$OSM/restore_fixes.json"; } | \
    python tools/restore_stations.py apply > "$f.new" 2>/dev/null
  if [ -s "$f.new" ]; then
    if ! cmp -s "$f" "$f.new"; then
      mv "$f.new" "$f"
      cnt=$((cnt+1))
    else
      rm -f "$f.new"
    fi
  else
    rm -f "$f.new"
  fi
done
echo "restored files: $cnt"
