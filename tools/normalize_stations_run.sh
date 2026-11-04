#!/bin/bash
# 共享车站坐标归一：对全部线路文件应用 station_fixes.json。
# Python 零文件 I/O：stdin 传修正表，stdout 重定向落盘。
cd "$(dirname "$0")/.." || exit 1
OSM=tools/cache12306/osm
FIXES="$OSM/station_fixes.json"
[ -s "$FIXES" ] || { echo "no fixes file"; exit 1; }

cnt=0
for f in data/lines/*.json; do
  { cat "$f"; cat "$FIXES"; } | python tools/normalize_stations.py apply > "$f.new" 2>/dev/null
  if [ -s "$f.new" ]; then
    if cmp -s "$f" "$f.new"; then
      rm -f "$f.new"
    else
      mv "$f.new" "$f"
      cnt=$((cnt+1))
    fi
  else
    rm -f "$f.new"
  fi
done
echo "normalized files: $cnt"
