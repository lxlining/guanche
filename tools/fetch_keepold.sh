#!/usr/bin/env bash
# keep-old 宽幅站对补抓：单 worker + 25s 间隔（避免 Overpass 软限流——
# 实测爆发式双 worker 全被空结果拒绝而单发成功）。
# 宽幅缓存命名 <id>__w<k>.json（构建的 __*.json 通配自动并入），
# 不覆盖既有站对缓存。OSM_PAD=0.35 扩大包围盒补走廊缺口。
set -u
cd "$(dirname "$0")/.." || exit 1
OSM=tools/cache12306/osm
LOG="$OSM/fetch.log"
IDS_FILE="$OSM/keepold_ids.txt"
TASKS="$OSM/pair_tasks.txt"
export OSM_PAD=0.35

python tools/gen_pair_tasks.py < "$IDS_FILE" > "$TASKS"
total=$(wc -l < "$TASKS")
echo "[fetch_keepold] 宽幅站对任务 $total 个（单 worker + 25s 间隔）"

for pass in 1 2 3 4 5 6; do
  todo=0
  while read -r id k; do
    [ -s "$OSM/${id}__w${k}.json" ] || todo=$((todo+1))
  done < "$TASKS"
  echo "[$(date +%T)] [fetch_keepold] 第 $pass 轮：待抓 $todo / $total"
  if [ "$todo" -eq 0 ]; then
    echo "[fetch_keepold] 全部完成"
    break
  fi
  while read -r id k; do
    out="$OSM/${id}__w${k}.json"
    if [ -s "$out" ]; then continue; fi
    tmp="$out.tmp.$$"
    if python tools/osm_geometry.py fetch "$id" "$k" < "data/lines/$id.json" > "$tmp" 2>>"$LOG"; then
      mv "$tmp" "$out"
    else
      rm -f "$tmp"
    fi
    sleep 25
  done < "$TASKS"
done
echo "[fetch_keepold] done"
