#!/usr/bin/env bash
# 航空数据抓取编排：python 零文件 I/O，落盘由本脚本 bash 重定向完成。
# 原子写（tmp+mv）+ 断网可用缓存重跑。产物 data/air/aviation.json。
set -u
cd "$(dirname "$0")/.." || exit 1

CACHE="tools/cacheair"
OUT="data/air/aviation.json"
mkdir -p "$CACHE" data/air

fetch_one() {  # fetch_one <key> <cache 文件> <最小字节数>
  local key="$1" dest="$2" min_bytes="$3"
  if [ -f "$dest" ] && [ "$(stat -c%s "$dest" 2>/dev/null || echo 0)" -ge "$min_bytes" ]; then
    echo "[fetch_air] $key 缓存命中 ($(du -h "$dest" | cut -f1))"
    return 0
  fi
  local tmp="$dest.tmp.$$"
  if python tools/fetch_air.py --fetch "$key" > "$tmp"; then
    mv "$tmp" "$dest"
    echo "[fetch_air] $key 抓取完成 ($(du -h "$dest" | cut -f1))"
    return 0
  fi
  rm -f "$tmp"
  echo "[fetch_air] $key 抓取失败（无缓存可用）"
  return 1
}

fetch_one airports "$CACHE/airports.cache" 1000000 || exit 1
fetch_one airlines "$CACHE/airlines.cache" 100000 || exit 1
fetch_one routes   "$CACHE/routes.cache"   400000 || exit 1

TMP="$OUT.tmp.$$"
if python tools/fetch_air.py --build "$CACHE/airports.cache" "$CACHE/airlines.cache" "$CACHE/routes.cache" > "$TMP"; then
  mv "$TMP" "$OUT"
  echo "[fetch_air] 构建完成 → $OUT ($(du -h "$OUT" | cut -f1))"
else
  rm -f "$TMP"
  echo "[fetch_air] 构建失败"
  exit 1
fi
