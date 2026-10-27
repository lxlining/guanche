#!/bin/bash
# OSM 线形批量抓取：双 worker（Overpass 政策允许每 IP 2 并发），
# 断点续传 + 原子写入 + 失败重试到全部完成为止。
# 放停止标记 tools/cache12306/osm/STOP 可随时安全终止；
# 全部完成后写 tools/cache12306/osm/ALL_DONE 标记。
cd "$(dirname "$0")/.." || exit 1
OSM=tools/cache12306/osm
LOG="$OSM/fetch.log"
FAIL="$OSM/fetch_fail.txt"
: > "$FAIL"

fetch_one() {
  local id="$1" k="$2" out tmp
  if [ "$k" = "-" ]; then
    out="$OSM/${id}.json"
  else
    out="$OSM/${id}__${k}.json"
  fi
  if [ -s "$out" ]; then return 0; fi
  # 先写临时文件、成功后原子改名：并发/中断都不会留下半截缓存，
  # 也不会误删已成功的缓存
  tmp="$out.tmp"
  if [ "$k" = "-" ]; then
    python tools/osm_geometry.py fetch "$id" < "data/lines/$id.json" > "$tmp" 2>>"$LOG" || {
      rm -f "$tmp"; echo "$id -" >> "$FAIL"; return 0; }
  else
    python tools/osm_geometry.py fetch "$id" "$k" < "data/lines/$id.json" > "$tmp" 2>>"$LOG" || {
      rm -f "$tmp"; echo "$id $k" >> "$FAIL"; return 0; }
  fi
  mv -f "$tmp" "$out"
  sleep 1.2
}

run_list() {
  # $1=pick(取模余数) $2=模数 $3=清单文件；逐行 fetch_one
  awk -v p="$1" -v m="$2" 'NR%m==p' "$3" | while read -r id k; do
    [ -f "$OSM/STOP" ] && return 0
    fetch_one "$id" "$k"
  done
}

run_all() {
  local list="$1"
  echo "[$(date +%T)] pass start: $(wc -l < "$list") tasks" >> "$LOG"
  run_list 1 2 "$list" & P1=$!
  run_list 0 2 "$list" & P2=$!
  wait $P1 $P2
}

run_all "$OSM/worklist.txt"

# 失败重试：最多 30 轮（每轮只跑仍缺失的条目），间隔递增至 10 分钟封顶；
# 彻底完成后写 ALL_DONE 标记
for pass in $(seq 1 30); do
  [ -f "$OSM/STOP" ] && break
  if [ ! -s "$FAIL" ]; then
    touch "$OSM/ALL_DONE"
    echo "[$(date +%T)] ALL DONE" >> "$LOG"
    break
  fi
  wait_s=$((90 * pass))
  [ "$wait_s" -gt 600 ] && wait_s=600
  sleep "$wait_s"
  cp "$FAIL" "$OSM/retry_last.txt"
  : > "$FAIL"
  echo "[$(date +%T)] retry pass $pass: $(wc -l < "$OSM/retry_last.txt")" >> "$LOG"
  run_all "$OSM/retry_last.txt"
done
echo "[$(date +%T)] fetcher exit, remaining failures: $(wc -l < "$FAIL")" >> "$LOG"
