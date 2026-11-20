#!/usr/bin/env python3
"""Strict bounded audio evidence for the ten songs the real website player opened.

Website side: the actual audio URL recorded by Chrome's HAR while clicking the
real site's play buttons (no Python re-derivation of the web request).
App side: the source-guarded PlaybackResolver mirror (Windows cannot run Swift).

Both sides are fetched with a bounded reader: headers are parsed before any
body bytes are read, only `Range: bytes=0-65535` is accepted, a 206 with
`bytes 0-N/total` (N <= 65535) is required, and exactly N+1 bytes are read.
Raw response headers are saved per song so the check is reproducible.
"""

import argparse
import csv
import hashlib
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import align_report as common

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEBSITE = r"D:\Projects\mhub-local\frontend\src"
MAX_BYTES = 65536
FIELDS = [
    "index", "song", "platform", "row_id", "side",
    "request_pattern", "task_id", "audio_url",
    "http_status", "content_range", "content_type", "content_length",
    "bytes_read", "total_bytes", "sha256_first_64k",
    "redirect_chain", "final_302_location", "raw_headers_file", "verdict", "detail",
]
TARGET_IDS = ["1", "2", "3", "10", "47", "159", "69", "77", "49", "79"]
PLATFORM_BY_ID = {"1": "kugou", "2": "tencent", "3": "tencent", "10": "netease",
                  "47": "netease", "159": "kugou", "69": "joox", "77": "joox",
                  "49": "youtubemusic", "79": "youtubemusic"}


def bounded_request(url):
    """Read headers first, then at most 64 KiB; kill curl as soon as done."""
    common.LIMITER.wait()
    process = subprocess.Popen(
        ["curl.exe", "--silent", "--show-error", "--max-time", "30",
         "-D", "-", "-o", "-", "-H", "Range: bytes=0-65535", url],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    headers = []
    while True:
        block = []
        line = b""
        while True:
            chunk = process.stdout.readline()
            if not chunk:
                process.kill()
                return None, None, b"", "no response headers"
            line += chunk
            if line in (b"\r\n", b"\n"):
                break
            block.append(line.decode("iso-8859-1", "replace").rstrip("\r\n"))
            line = b""
        # A proxy CONNECT answer arrives as its own header block; skip it and
        # read the real HTTP answer that follows.
        if block and len(block) == 1 and "Connection established" in block[0]:
            continue
        headers = block
        break
    status = None
    for text in headers:
        match = re.match(r"^HTTP/[\d.]+ (\d{3})", text)
        if match:
            status = int(match.group(1))
    head = {}
    for text in headers:
        name, separator, value = text.partition(":")
        if separator:
            head[name.strip().lower()] = value.strip()
    if status != 206:
        process.kill()
        return status, head, b"", "not a 206 ranged response"
    match = re.fullmatch(r"bytes 0-(\d+)/(\d+)", head.get("content-range", ""))
    if not match:
        process.kill()
        return status, head, b"", "Content-Range is not bytes 0-N/total"
    first, total = int(match.group(1)), int(match.group(2))
    if first >= MAX_BYTES or total <= first:
        process.kill()
        return status, head, b"", "range end outside 0-65535 or bad total"
    body = process.stdout.read(first + 1)
    process.kill()
    if len(body) != first + 1:
        return status, head, body, "read {} bytes, expected {}".format(len(body), first + 1)
    return status, head, body, ""


def probe_audio(url, raw_path):
    chain = [url]
    current = url
    final_location = ""
    result = {}
    for _ in range(4):
        status, headers, body, problem = bounded_request(current)
        if status == 302 and headers and headers.get("location"):
            final_location = headers["location"]
            chain.append(final_location)
            current = final_location
            continue
        with open(raw_path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write("# request: {}\n".format(current))
            if status is not None:
                handle.write("HTTP status: {}\n".format(status))
            if headers:
                for name, value in headers.items():
                    handle.write("{}: {}\n".format(name, value))
            handle.write("bytes_read: {}\n".format(len(body)))
        total_match = re.search(r"/(\d+)$", (headers or {}).get("content-range", ""))
        result = {
            "http_status": status or "",
            "content_range": (headers or {}).get("content-range", ""),
            "content_type": (headers or {}).get("content-type", ""),
            "content_length": (headers or {}).get("content-length", ""),
            "bytes_read": len(body),
            "total_bytes": total_match.group(1) if total_match else "",
            "sha256_first_64k": hashlib.sha256(body).hexdigest() if body else "",
            "redirect_chain": " -> ".join(chain),
            "final_302_location": final_location,
            "verdict": "通过" if not problem else "失败",
            "detail": problem,
        }
        break
    if not result:
        result = {"http_status": "", "content_range": "", "content_type": "", "content_length": "",
                  "bytes_read": 0, "total_bytes": "", "sha256_first_64k": "",
                  "redirect_chain": " -> ".join(chain), "final_302_location": final_location,
                  "verdict": "失败", "detail": "too many redirects"}
    return result


def browser_entries(har_path):
    entries = json.load(open(har_path, encoding="utf-8"))["log"]["entries"]
    posts = {}
    for entry in entries:
        request = entry["request"]
        if request["url"].endswith("/api/v1/playbacks") and request["method"] == "POST":
            try:
                body = json.loads(request["postData"]["text"])
                response = json.loads(entry["response"]["content"].get("text") or "{}")
            except (ValueError, KeyError):
                continue
            posts.setdefault(str(body.get("selected_id")), {
                "body": body, "task": response.get("playback") or {}})
    media = {}
    for entry in entries:
        match = re.search(r"/playbacks/([^/]+)/audio\?v=([^&]+)", entry["request"]["url"])
        if match and match.group(1) not in media:
            media[match.group(1)] = {"url": entry["request"]["url"],
                                     "status": entry["response"]["status"]}
    return posts, media


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--har", default=r"C:\Users\kenzh\hark_tasks\apu_ios\website-real-playback.har")
    parser.add_argument("--out", default=os.path.join(REPO, "reports", "audio_identity_strict.csv"))
    parser.add_argument("--raw", default=os.path.join(REPO, "reports", "audio_identity_raw"))
    arguments = parser.parse_args()

    problems = common.verify_sources(WEBSITE)
    if problems:
        for problem in problems:
            print("SOURCE GUARD: " + problem)
        return 2
    os.makedirs(arguments.raw, exist_ok=True)
    posts, media = browser_entries(arguments.har)

    playlist_status, playlist, _ = common.api_json("/local/imported-playlists/" + common.PLAYLIST_ID)
    if playlist_status != 200 or not playlist:
        print("playlist HTTP {}".format(playlist_status))
        return 2
    items = {str(item["id"]): item for item in playlist.get("items") or []}

    rows = []
    for row_id in TARGET_IDS:
        item = items[row_id]
        browser = posts.get(row_id)
        if not browser or row_id not in media:
            print("{}: browser production evidence missing".format(row_id))
            continue
        web_url = media[row_id]["url"]
        rows.append({"index": item.get("position"), "song": item.get("song"),
                     "platform": PLATFORM_BY_ID[row_id], "row_id": row_id, "side": "website-browser",
                     "request_pattern": json.dumps(browser["body"], ensure_ascii=False, sort_keys=True),
                     "task_id": browser["task"].get("id", ""), "audio_url": web_url})

        # App side: production Swift cannot run on Windows; guarded mirror only.
        app_body = common.app_request(item)
        status, payload, _ = common.api_json("/playbacks", method="POST", body=app_body)
        app_task = "http-{}".format(status)
        app_url = ""
        if status == 200 and payload:
            task, state = common.load_task(common.unwrap_task(payload), common.app_ready)
            app_task = task.get("id", "")
            if state == "ready":
                app_url = common.app_audio_url(task)
        rows.append({"index": item.get("position"), "song": item.get("song"),
                     "platform": PLATFORM_BY_ID[row_id], "row_id": row_id, "side": "app-mirror",
                     "request_pattern": json.dumps(app_body, ensure_ascii=False, sort_keys=True),
                     "task_id": app_task, "audio_url": app_url})

    for row in rows:
        raw_path = os.path.join(arguments.raw, "row{}_{}.txt".format(row["row_id"], row["side"]))
        if row["audio_url"]:
            facts = probe_audio(row["audio_url"], raw_path)
        else:
            facts = {"http_status": "", "content_range": "", "content_type": "", "content_length": "",
                     "bytes_read": 0, "total_bytes": "", "sha256_first_64k": "",
                     "redirect_chain": "", "final_302_location": "", "verdict": "失败",
                     "detail": "no audio url"}
        row.update(facts)
        row["raw_headers_file"] = raw_path
        print("{} {} {} {} bytes={} sha={}".format(row["row_id"], row["side"], row["verdict"], row["detail"],
                                                   row["bytes_read"], row["sha256_first_64k"][:12]), flush=True)
        time.sleep(0.15)

    with open(arguments.out, "w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row.get(key, "") for key in FIELDS})
    print("saved: " + arguments.out)
    print(json.dumps({"rows": len(rows), "passed": sum(r["verdict"] == "通过" for r in rows),
                      "requests": common.LIMITER.requests, "pauses": common.LIMITER.pauses}, ensure_ascii=False))
    return 0 if all(r["verdict"] == "通过" for r in rows) else 1


if __name__ == "__main__":
    sys.exit(main())
