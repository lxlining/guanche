#!/usr/bin/env bash
# keep-old 站级补抓：为清单内线路逐站抓 OSM（<id>__s<k>.json，构建脚本
# 的 __*.json 通配会自动并入）。双 worker（Overpass 政策允许每 IP 2 并发），
# 3 轮重试 + tmp/mv 原子写，断点续传。
set -u
cd "$(dirname "$0")/.." || exit 1
OSM=tools/cache12306/osm
LOG="$OSM/fetch.log"
IDS_FILE="$OSM/keepold_ids.txt"
TASKS="$OSM/station_tasks.txt"

python tools/gen_station_tasks.py < "$IDS_FILE" > "$TASKS"
total=$(wc -l < "$TASKS")
echo "[fetch_keepold] 任务 $total 个（双 worker）"

fetch_worker() {
  local list="$1"
  while read -r id k; do
    out="$OSM/${id}__${k}.json"
    if [ -s "$out" ]; then continue; fi
    tmp="$out.tmp.$$"
    if python tools/osm_geometry.py fetch "$id" "$k" < "data/lines/$id.json" > "$tmp" 2>>"$LOG"; then
      mv "$tmp" "$out"
    else
      rm -f "$tmp"
    fi
  done < "$list"
}

for pass in 1 2 3 4 5 6 7 8 9 10; do
  todo=0
  while read -r id k; do
    [ -s "$OSM/${id}__${k}.json" ] || todo=$((todo+1))
  done < "$TASKS"
  echo "[$(date +%T)] [fetch_keepold] 第 $pass 轮：待抓 $todo / $total"
  if [ "$todo" -eq 0 ]; then
    echo "[fetch_keepold] 全部完成"
    break
  fi
  # 单双分半，双 worker 并行
  grep -n "" "$TASKS" | awk 'NR%2==1{sub(/^[0-9]+:/,""); print}' > "$TASKS.a"
  grep -n "" "$TASKS" | awk 'NR%2==0{sub(/^[0-9]+:/,""); print}' > "$TASKS.b"
  fetch_worker "$TASKS.a" &
  PA=$!
  fetch_worker "$TASKS.b" &
  PB=$!
  wait $PA $PB
  # Overpass 故障窗口退避：10 分钟后再试下一轮
  sleep 600
done
rm -f "$TASKS.a" "$TASKS.b"
echo "[fetch_keepold] done"
