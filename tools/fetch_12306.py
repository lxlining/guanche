# -*- coding: utf-8 -*-
"""从 12306 公开查询接口抓取真实时刻表数据。

只读本地缓存 + 输出到标准输出（持久化由调用方重定向完成）：
  python tools/fetch_12306.py search > tools/cache12306/index.json
  python tools/fetch_12306.py detail >> tools/cache12306/detail.jsonl

阶段 A（search）：search.12306.cn 按车次号前缀枚举全国 G/D 车次。
阶段 B（detail）：读取 index.json 与 detail.jsonl，跳过已抓车次，
逐车调用 kyfw.12306.cn 详情接口，把停站记录按 JSONL 追加到 stdout。
限速：每次请求间隔约 0.3 秒（确定性抖动），连续失败退避中止。
"""
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")
DATE_HYPHEN = "2026-10-29"   # 查询日期（需在预售期内）
DATE_COMPACT = "20261029"
DETAIL_DELAY = 0.30

_CTX_SSL = ssl.create_default_context()
_CTX_NOVERIFY = ssl.create_default_context()
_CTX_NOVERIFY.check_hostname = False
_CTX_NOVERIFY.verify_hostname = False
_CTX = _CTX_SSL
_opener = None


def _build_opener():
    global _opener
    _opener = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(),
        urllib.request.HTTPSHandler(context=_CTX))


_build_opener()


def http_get(url: str, retries: int = 6) -> str:
    global _CTX, _opener
    last_err = None
    for i in range(retries):
        try:
            req = urllib.request.Request(url, headers={
                "User-Agent": UA,
                "Referer": "https://kyfw.12306.cn/otn/leftTicket/init",
                "Accept": "*/*",
            })
            with _opener.open(req, timeout=20) as r:
                return r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            last_err = "HTTP %d" % e.code
            if e.code in (403, 429, 503):
                time.sleep(15.0 + 5.0 * i)  # 限流退避
            else:
                time.sleep(1.5 * (i + 1))
        except ssl.SSLError:
            _CTX = _CTX_NOVERIFY  # 回退：不校验证书重建 opener 重试
            _build_opener()
            last_err = "ssl"
        except Exception as e:  # noqa: BLE001
            last_err = str(e)
            time.sleep(1.5 * (i + 1))
    raise RuntimeError("请求失败 %s: %s" % (url, last_err))


def bootstrap_cookies() -> None:
    """访问一次余票页，让 cookie 处理器持有会话 Cookie。"""
    try:
        http_get("https://kyfw.12306.cn/otn/leftTicket/init")
    except RuntimeError as e:
        print("[警告] cookie 引导失败（可能不影响详情接口）：%s" % e, file=sys.stderr)


def search_keyword(kw: str):
    url = ("https://search.12306.cn/search/v1/train/search?keyword=%s&date=%s"
           % (urllib.parse.quote(kw), DATE_COMPACT))
    d = json.loads(http_get(url))
    items = []
    for x in d.get("data", []):
        items.append({
            "train_no": x.get("train_no", ""),
            "code": x.get("station_train_code", ""),
            "from": x.get("from_station", ""),
            "to": x.get("to_station", ""),
        })
    return {"items": items, "truncated": len(items) >= 200}


def load_search_cache(path: str):
    done = {}
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                    done[rec["key"]] = rec["value"]
                except json.JSONDecodeError:
                    continue
    return done


def phase_search() -> None:
    """把每个关键词的搜索结果按 JSONL 追加到 stdout（调用方重定向持久化）。"""
    cache_path = os.path.join("tools", "cache12306", "search.jsonl")
    done = load_search_cache(cache_path)
    planned = []
    for letter in ("G", "D", "C"):
        for a in range(1, 10):
            kw0 = "%s%d" % (letter, a)
            planned.append(kw0)
    # 先只查第一个未缓存关键词判断是否需要细分（截断时补两位前缀）
    for kw0 in planned:
        if kw0 not in done:
            continue
        if done[kw0].get("truncated"):
            for b in range(0, 10):
                sub = kw0 + str(b)
                if sub not in planned:
                    planned.append(sub)
    for kw in planned:
        if kw in done:
            continue
        try:
            res = search_keyword(kw)
        except RuntimeError as e:
            print("[错误] %s：%s" % (kw, e), file=sys.stderr)
            continue
        json.dump({"key": kw, "value": res}, sys.stdout, ensure_ascii=False)
        print()
        print("[搜索] %s -> %d 条%s" % (kw, len(res["items"]),
              "（截断，需细分）" if res["truncated"] else ""), file=sys.stderr)
        if res["truncated"]:
            for b in range(0, 10):
                sub = kw + str(b)
                if sub not in planned:
                    planned.append(sub)
        time.sleep(0.5)
    print("[搜索] 缓存关键词 %d 个" % (len(done) + 1), file=sys.stderr)


def phase_index() -> None:
    """读取 search.jsonl -> 输出全国车次索引 JSON。"""
    cache_path = os.path.join("tools", "cache12306", "search.jsonl")
    done = load_search_cache(cache_path)
    trains = {}
    for kw, res in done.items():
        for item in res.get("items", []):
            if item["train_no"]:
                trains[item["train_no"]] = item
    json.dump(list(trains.values()), sys.stdout, ensure_ascii=False)
    print("[枚举] 全国 G/D 车次 %d 个（来自 %d 个关键词）" % (len(trains), len(done)),
          file=sys.stderr)


def load_detail_cache(path: str):
    """读取已抓取的 JSONL 缓存（不存在返回空 dict）。"""
    done = {}
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                    done[rec["key"]] = rec["value"]
                except json.JSONDecodeError:
                    continue  # 忽略被截断的最后一行
    return done


def load_station_map() -> dict:
    """station_name.js -> {中文名: 电报码}（每次运行现取一次）"""
    txt = http_get("https://kyfw.12306.cn/otn/resources/js/framework/station_name.js")
    mapping = {}
    for m in re.finditer(r"@[^|]*\|([^|]+)\|([A-Z]+)\|", txt):
        mapping[m.group(1)] = m.group(2)
    return mapping


def phase_detail() -> None:
    index_path = os.path.join("tools", "cache12306", "index.json")
    cache_path = os.path.join("tools", "cache12306", "detail.jsonl")
    with open(index_path, encoding="utf-8") as f:
        trains = {x["train_no"]: x for x in json.load(f)}
    done = load_detail_cache(cache_path)
    print("[详情] 索引 %d 个，缓存已有 %d 个" % (len(trains), len(done)), file=sys.stderr)

    name2tc = load_station_map()
    our_names = set()
    for fn in os.listdir(os.path.join("data", "lines")):
        if fn.endswith(".json"):
            ld = json.load(open(os.path.join("data", "lines", fn), encoding="utf-8"))
            our_names.update(s["name"] for s in ld.get("stations", []))

    todo = [t for t in trains.values() if t["train_no"] not in done]
    todo.sort(key=lambda t: 0 if (t["from"] in our_names or t["to"] in our_names) else 1)
    print("[详情] 待抓 %d 个" % len(todo), file=sys.stderr)

    fails = 0
    fetched = 0
    for t in todo:
        tc_from = name2tc.get(t["from"], "")
        tc_to = name2tc.get(t["to"], "")
        rec = None
        if tc_from and tc_to:
            url = ("https://kyfw.12306.cn/otn/czxx/queryByTrainNo?train_no=%s"
                   "&from_station_telecode=%s&to_station_telecode=%s&depart_date=%s"
                   % (urllib.parse.quote(t["train_no"]), urllib.parse.quote(tc_from),
                      urllib.parse.quote(tc_to), DATE_HYPHEN))
            try:
                d = json.loads(http_get(url))
                rec = {"stops": d.get("data", {}).get("data", [])}
            except (RuntimeError, json.JSONDecodeError) as e:
                print("[跳过] %s：%s" % (t["train_no"], e), file=sys.stderr)
                rec = {"error": str(e)}
        else:
            rec = {"error": "unknown endpoint: %s / %s" % (t["from"], t["to"])}
        json.dump({"key": t["train_no"], "value": rec}, sys.stdout, ensure_ascii=False)
        print()  # JSONL 换行
        sys.stdout.flush()  # 逐行落盘，中断后可续传
        fetched += 1
        fails = fails + 1 if "error" in rec else 0
        if fails >= 40:
            print("[中止] 连续失败过多，重跑即可续传", file=sys.stderr)
            break
        if fetched % 200 == 0:
            print("[详情] 进度 %d/%d" % (fetched, len(todo)), file=sys.stderr)
        time.sleep(DETAIL_DELAY + (time.time() % 1) * 0.15)
    print("[详情] 本次抓取 %d 个" % fetched, file=sys.stderr)


def main():
    phase = sys.argv[1] if len(sys.argv) > 1 else "search"
    if phase == "search":
        phase_search()
    elif phase == "index":
        phase_index()
    elif phase == "detail":
        phase_detail()
    else:
        raise SystemExit("用法: python tools/fetch_12306.py [search|index|detail]")


if __name__ == "__main__":
    main()
