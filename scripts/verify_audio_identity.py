#!/usr/bin/env python3
"""Ten-song, different-platform check that the app and the website open the same audio.

Both sides post their own real request (derived independently from their own
source), wait with their own ready rule, and then the script follows the
backend's 302 and compares:

  * the 302 Location (including the `rev` generation token),
  * the final audio host/path (signed query tokens are ignored, not printed),
  * Content-Type,
  * total byte size from Content-Range,
  * SHA256 of the first 64 KiB of the served bytes.

No tier is guessed: the request uses `PlaybackQuality.siteQuality` in the Swift
source and the website's `stores/status.js` default. The run starts with a
source guard, so it fails if either client's code no longer matches the logic
being exercised. This is a source-guarded mirror of the Swift resolver, not a
 claim that Swift itself ran on Windows; the exact mirrored expressions are
listed in the report.

Usage:
    python scripts/verify_audio_identity.py --out reports/audio_identity.csv
"""

import argparse
import csv
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import align_report as common  # independent, already source-guarded derivations

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEBSITE = r"D:\Projects\mhub-local\frontend\src"
API = common.API
FIELDS = [
    "index", "song", "singer", "platform", "row_id",
    "web_request", "app_request", "request_identical",
    "web_task_id", "app_task_id", "web_status", "app_status",
    "web_302_location", "app_302_location", "location_identical",
    "web_final_host_path", "app_final_host_path", "host_path_identical",
    "web_content_type", "app_content_type", "content_type_identical",
    "web_total_bytes", "app_total_bytes", "bytes_identical",
    "web_sha256_64k", "app_sha256_64k", "sha256_identical",
    "result", "difference",
]

EXTRA_APP_CHECKS = [
    "self.platform = track.platform",
    "self.query = track.song",
    "self.selectedId = track.playbackSelectionID",
    "self.streamingMode = platform == \"applemusic\" && quality.isLossless ? \"wasm_alac\" : nil",
    "quality.rawValue",
    "guard let path = audioURL, !path.isEmpty else { return nil }",
    "static let siteQuality: PlaybackQuality = .high",
]

PICK = [
    ("tencent", 2), ("netease", 2), ("kugou", 2), ("joox", 2), ("youtubemusic", 2),
]


def guard_sources():
    problems = common.verify_sources(WEBSITE)
    app = open(os.path.join(REPO, "ApuMusic", "PlaybackResolver.swift"), encoding="utf-8").read()
    models = open(os.path.join(REPO, "ApuMusic", "Models.swift"), encoding="utf-8").read()
    for needle in EXTRA_APP_CHECKS:
        if needle not in app and needle not in models:
            problems.append("app source missing: " + needle)
    return problems


def pick_songs(items):
    chosen = []
    for platform, count in PICK:
        candidates = [item for item in items
                      if item.get("platform") == platform and item.get("status") == "matched"]
        chosen.extend(candidates[:count])
    return chosen


def fetch(url, ranged=True):
    """One request without following the redirect: the 302 Location is the identity."""
    common.LIMITER.wait()
    with tempfile.TemporaryDirectory() as folder:
        head_path = os.path.join(folder, "h")
        body_path = os.path.join(folder, "b")
        command = ["curl.exe", "--silent", "--show-error", "--max-time", "40",
                   "-D", head_path, "-o", body_path, "-w", "%{http_code}"]
        if ranged:
            command += ["-H", "Range: bytes=0-65535"]
        command.append(url)
        done = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", errors="replace")
        headers = common.parse_headers(open(head_path, encoding="iso-8859-1", errors="replace").read())
        body = open(body_path, "rb").read()
        return done.stdout.strip(), headers, body


def audio_facts(audio_url):
    status, headers, body = fetch(audio_url)
    location = headers.get("location", "")
    if status == "302" and location:
        # Follow once, keeping the final response headers and the first 64 KiB.
        status2, headers2, body2 = fetch(location)
    else:
        status2, headers2, body2 = status, headers, body
    content_range = headers2.get("content-range", "")
    match = re.search(r"/(\d+)\s*$", content_range)
    total = match.group(1) if match else ""
    parts = urlsplit(location or audio_url)
    host_path = parts.netloc + parts.path
    return {
        "location": location,
        "host_path": host_path,
        "content_type": headers2.get("content-type", ""),
        "total": total,
        "sha256": hashlib.sha256(body2[:65536]).hexdigest(),
        "http": status2,
        "bytes_read": len(body2),
    }


def one_side(item, prefix):
    body = common.website_request(item) if prefix == "web" else common.app_request(item)
    ready = common.website_ready if prefix == "web" else common.app_ready
    url_builder = common.website_audio_url if prefix == "web" else common.app_audio_url
    status, payload, _ = common.api_json("/playbacks", method="POST", body=body)
    if status != 200 or not payload:
        return body, {"status": "http-{}".format(status)}, {}
    task = common.unwrap_task(payload)
    task, state = common.load_task(task, ready)
    if state != "ready":
        return body, {"status": "{}/{}".format(task.get("status"), task.get("error_code") or "")}, task
    url = url_builder(task)
    if not url:
        return body, {"status": "no-audio-url"}, task
    return body, audio_facts(url), task


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=os.path.join(REPO, "reports", "audio_identity.csv"))
    parser.add_argument("--only", default="", help="comma separated playlist indexes")
    arguments = parser.parse_args()

    problems = guard_sources()
    if problems:
        for problem in problems:
            print("SOURCE GUARD: " + problem)
        return 2

    status, payload, _ = common.api_json("/local/imported-playlists/" + common.PLAYLIST_ID)
    if status != 200 or not payload:
        print("playlist HTTP {}".format(status))
        return 2
    items = pick_songs(payload.get("items") or [])
    if arguments.only:
        positions = {int(value) for value in arguments.only.split(",") if value.strip()}
        items = [item for item in items if int(item.get("position", -1)) in positions]
    print("songs: " + ", ".join("{}:{}".format(i["position"], i["platform"]) for i in items), flush=True)

    rows = []
    for item in items:
        web_body, web, web_task = one_side(item, "web")
        app_body, app, app_task = one_side(item, "app")
        row = {field: "" for field in FIELDS}
        row.update({
            "index": item.get("position"), "song": item.get("song") or "",
            "singer": item.get("singer") or "", "platform": item.get("platform") or "",
            "row_id": item.get("id") or "",
            "web_request": json.dumps(web_body, ensure_ascii=False, sort_keys=True),
            "app_request": json.dumps(app_body, ensure_ascii=False, sort_keys=True),
            "request_identical": str(web_body == app_body),
            "web_task_id": str(web_task.get("id") or ""), "app_task_id": str(app_task.get("id") or ""),
            "web_status": str(web_task.get("status") or web.get("status") or ""),
            "app_status": str(app_task.get("status") or app.get("status") or ""),
        })
        names = {"location": "302_location", "host_path": "final_host_path",
                 "content_type": "content_type", "total": "total_bytes",
                 "sha256": "sha256_64k"}
        for key, column in names.items():
            row["web_" + column] = web.get(key, "")
            row["app_" + column] = app.get(key, "")
        equalities = {
            "location_identical": web.get("location") and web.get("location") == app.get("location"),
            "host_path_identical": web.get("host_path") and web.get("host_path") == app.get("host_path"),
            "content_type_identical": web.get("content_type") and web.get("content_type") == app.get("content_type"),
            "bytes_identical": web.get("total") and web.get("total") == app.get("total"),
            "sha256_identical": web.get("sha256") and web.get("sha256") == app.get("sha256"),
        }
        for key, value in equalities.items():
            row[key] = str(bool(value))
        row["result"] = "一致" if all(equalities.values()) and web_body == app_body else "不一致"
        row["difference"] = "；".join(key for key, value in equalities.items() if not value)
        if web_body != app_body:
            row["difference"] += "；请求参数不同"
        rows.append(row)
        print("{} {} {} {}".format(row["index"], row["platform"], row["result"], row["difference"]), flush=True)
        time.sleep(0.2)

    os.makedirs(os.path.dirname(os.path.abspath(arguments.out)), exist_ok=True)
    with open(arguments.out, "w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)
    print("saved: " + arguments.out)
    print(json.dumps({"songs": len(rows), "identical": sum(r["result"] == "一致" for r in rows),
                      "requests": common.LIMITER.requests, "pauses": common.LIMITER.pauses},
                     ensure_ascii=False))
    return 0 if all(row["result"] == "一致" for row in rows) else 1


if __name__ == "__main__":
    sys.exit(main())
