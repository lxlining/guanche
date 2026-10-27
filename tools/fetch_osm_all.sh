#!/bin/bash
# OSM 线形批量抓取：双 worker（Overpass 政策允许每 IP 2 并发），
# 断点续传（已有非空缓存即跳过）。主跑结束后对失败清单做多轮重试。
cd "$(dirname "$0")/.." || exit 1
OSM=tools/cache12306/osm
LOG="$OSM/fetch.log"
FAIL="$OSM/fetch_fail.txt"
: > "$FAIL"

fetch_one() {
  local id="$1" k="$2" out
  if [ "$k" = "-" ]; then
    out="$OSM/$id.json"
  else
    out="$OSM/$id__$k.json"
  fi
  if [ -s "$out" ]; then return 0; fi
  if [ "$k" = "-" ]; then
    python tools/osm_geometry.py fetch "$id" < "data/lines/$id.json" > "$out" 2>>"$LOG" || {
      rm -f "$out"; echo "$id -" >> "$FAIL"; return 0; }
  else
    python tools/osm_geometry.py fetch "$id" "$k" < "data/lines/$id.json" > "$out" 2>>"$LOG" || {
      rm -f "$out"; echo "$id $k" >> "$FAIL"; return 0; }
  fi
  sleep 1.2
}

run_list() {
  # $1=pick(奇偶) $2=清单文件；逐行 fetch_one
  awk -v p="$1" 'NR%2==p' "$2" | while read -r id k; do
    fetch_one "$id" "$k"
  done
}

echo "[$(date +%T)] fetch start: $(wc -l < "$OSM/worklist.txt") tasks" >> "$LOG"
run_list 1 "$OSM/worklist.txt" & P1=$!
run_list 0 "$OSM/worklist.txt" & P2=$!
wait $P1 $P2

# 失败重试：最多 6 轮，间隔递增；每轮只处理仍缺失的条目
for pass in 1 2 3 4 5 6; do
  [ -s "$FAIL" ] || break
  sleep $((60 * pass))
  cp "$FAIL" "$OSM/retry_$pass.txt"
  : > "$FAIL"
  echo "[$(date +%T)] retry pass $pass: $(wc -l < "$OSM/retry_$pass.txt")" >> "$LOG"
  run_list 1 "$OSM/retry_$pass.txt" & P1=$!
  run_list 0 "$OSM/retry_$pass.txt" & P2=$!
  wait $P1 $P2
done
echo "[$(date +%T)] fetch done, remaining failures: $(wc -l < "$FAIL")" >> "$LOG"
