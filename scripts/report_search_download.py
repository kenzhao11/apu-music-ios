#!/usr/bin/env python3
"""Real-API forensics for the App's own search -> playback -> download path.

For each of ~30 tracks found through the App's real search endpoint this script
replays exactly the request the App posts (platform, query=歌名,
selected_id=row id, quality=high, streaming_mode=null, include_cover=false),
long-polls the task like PlaybackResolver.waitUntilReady, then measures the
audio_url response: redirect chain, content-type, total size, and how many
bytes the audio endpoint actually serves while streaming vs after completed.

Everything is written incrementally to reports/search_download_report.csv so a
partial run still leaves evidence. Audio bodies are streamed to disk in 64 KiB
chunks and never held in memory.

Read-only against the live backend. No tests, no simulator, no screenshots.
"""

import binascii
import csv
import json
import os
import random
import sys
import threading
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor, as_completed

import requests

BASE = "https://kenmusic.kdns.fr/api/v1"
UA = {"Accept": "application/json", "User-Agent": "ApuMusic/0.1.0"}
QUALITY = "high"

KEYWORDS = ["周杰伦", "Taylor Swift", "晴天", "Adele", "邓紫棋"]
PER_KEYWORD = 8
MAX_TRACKS = 30
POLL_DEADLINE = 240.0
STREAM_CAP = 24 * 1024 * 1024
FULL_CAP = 220 * 1024 * 1024
DOWNLOAD_DIR = os.path.join("work", "forensics-downloads")
REPORT = os.path.join("reports", "search_download_report.csv")

CSV_FIELDS = [
    "keyword", "rank", "platform", "song", "singer", "track_row_id",
    "selected_id", "playback_id", "http_post_status", "post_retries",
    "status_sequence", "first_status", "final_status", "elapsed_to_ready_s",
    "elapsed_total_s", "failed_error_code", "failed_reason",
    "audio_url_host", "audio_url_path_redacted", "redirect_chain", "redirect_count",
    "audio_http_status", "content_type", "content_length", "content_range",
    "accept_ranges", "streaming_bytes", "streaming_content_length",
    "streaming_capped", "completed_bytes", "completed_capped", "bytes_match_length",
    "magic_hex", "container_guess",
    "blocked_stage", "notes",
]

_thread = threading.local()
_write_lock = threading.Lock()


def session():
    if not hasattr(_thread, "session"):
        s = requests.Session()
        s.headers.update(UA)
        _thread.session = s
    return _thread.session


def best_effort(fn, tries=5, base_wait=1.2):
    last = None
    for attempt in range(tries):
        try:
            return fn(), attempt
        except requests.HTTPError as error:
            last = error
            code = error.response.status_code if error.response is not None else 0
            if code not in (403, 408, 429, 500, 502, 503, 504):
                raise
            time.sleep(base_wait * (2 ** attempt) + random.random() * 0.4)
        except (requests.ConnectionError, requests.Timeout) as error:
            last = error
            time.sleep(base_wait * (2 ** attempt) + random.random() * 0.4)
    raise last


def api_get(path):
    def run():
        response = session().get(BASE + path, timeout=25)
        response.raise_for_status()
        return response.json()
    value, _attempts = best_effort(run)
    return value


def api_post(path, body):
    last = None
    for attempt in range(2):
        try:
            response = session().post(BASE + path, json=body, timeout=30)
            response.raise_for_status()
            return response.json(), attempt, response.status_code
        except (requests.HTTPError, requests.ConnectionError, requests.Timeout) as error:
            last = error
            code = error.response.status_code if isinstance(error, requests.HTTPError) and error.response else 0
            if attempt or (code and code not in (403, 408, 429, 500, 502, 503, 504)):
                raise
            time.sleep(1.0 + random.random() * 0.3)
    raise last


def normalize_search(payload):
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        for key in ("tracks", "songs", "items", "results"):
            value = payload.get(key)
            if isinstance(value, list):
                return value
    return []


def pick_rows(payload):
    """Same rule as the website: selected_id = row id, source_id = row source_id."""
    rows = []
    for row in normalize_search(payload):
        if not isinstance(row, dict):
            continue
        row_id = row.get("id")
        if row_id is None:
            continue
        row_id = str(row_id)
        rows.append({
            "platform": str(row.get("platform") or ""),
            "song": str(row.get("song") or row.get("title") or ""),
            "singer": str(row.get("singer") or row.get("artist") or ""),
            "row_id": row_id,
            "selected_id": row.get("selected_id") or row_id,
            "playable": row.get("playable"),
            "status": row.get("status"),
        })
    return rows


def collect_tracks():
    chosen = []
    seen = set()
    platforms = set()
    for keyword in KEYWORDS:
        path = "/search?" + urllib.parse.urlencode({"q": keyword, "limit": PER_KEYWORD})
        try:
            rows = pick_rows(api_get(path))
        except Exception as error:  # noqa: BLE001 - reported in the run log
            print(f"[search] {keyword}: {type(error).__name__} {error}", flush=True)
            continue
        print(f"[search] {keyword}: {len(rows)} rows", flush=True)
        for rank, row in enumerate(rows, start=1):
            key = (row["platform"], row["selected_id"])
            if key in seen:
                continue
            seen.add(key)
            row["keyword"] = keyword
            row["rank"] = rank
            # first pass keeps every distinct platform, so a later pass does not
            # starve tencent out of the sample
            chosen.append((row, row["platform"] not in platforms))
            platforms.add(row["platform"])
    chosen.sort(key=lambda item: (not item[1], item[0]["platform"] != "tencent"))
    ordered = [row for row, _ in chosen][:MAX_TRACKS]
    print(f"[search] selected {len(ordered)} tracks over platforms "
          f"{sorted({row['platform'] for row in ordered})}", flush=True)
    return ordered


def sniff_magic(path, count=16):
    with open(path, "rb") as handle:
        return handle.read(count)


def guess_container(magic, content_type):
    lowered = (content_type or "").lower()
    if magic.startswith(b"fLaC"):
        return "flac"
    if len(magic) >= 8 and magic[4:8] == b"ftyp":
        return "m4a/mp4"
    if magic.startswith(b"OggS"):
        return "ogg"
    if magic.startswith(b"ID3"):
        return "mp3(id3)"
    if len(magic) >= 2 and magic[0] == 0xFF and (magic[1] & 0xE0) == 0xE0:
        return "aac/adts" if (magic[1] & 0xF6) == 0xF0 else "mp3"
    if magic.startswith(b"RIFF") and magic[8:12] == b"WAVE":
        return "wav"
    if "flac" in lowered:
        return "flac(ct)"
    if "ogg" in lowered:
        return "ogg(ct)"
    if "mpeg" in lowered or "mp3" in lowered:
        return "mp3(ct)"
    if "mp4" in lowered or "m4a" in lowered or "aac" in lowered:
        return "m4a(ct)"
    return "unknown"


def download_to(path, url, cap, timeout, range_header=None):
    """Stream to disk; retain response headers without signed URL data."""
    received = 0
    capped = False
    content_length = None
    status = None
    chain = []
    headers = {"Accept-Encoding": "identity"}
    if range_header:
        headers["Range"] = range_header
    with session().get(url, headers=headers, stream=True, timeout=timeout, allow_redirects=True) as response:
        status = response.status_code
        for hop in response.history:
            chain.append(f"{hop.status_code}->{urllib.parse.urlsplit(hop.headers.get('Location', '')).netloc}")
        chain.append(f"{response.status_code}->{urllib.parse.urlsplit(response.url).netloc}")
        length_header = response.headers.get("Content-Length")
        if length_header and length_header.isdigit():
            content_length = int(length_header)
        response.raise_for_status()
        if status not in (200, 206):
            raise requests.HTTPError(f"Unexpected audio HTTP {status}", response=response)
        with open(path, "wb") as handle:
            for chunk in response.iter_content(chunk_size=65536):
                if not chunk:
                    continue
                remaining = cap - received
                if len(chunk) >= remaining:
                    handle.write(chunk[:remaining])
                    received += max(remaining, 0)
                    capped = True
                    break
                handle.write(chunk)
                received += len(chunk)
    return {"bytes": received, "content_length": str(content_length or ""), "capped": capped, "status": status, "chain": chain, "content_type": response.headers.get("Content-Type", ""), "content_range": response.headers.get("Content-Range", ""), "accept_ranges": response.headers.get("Accept-Ranges", "")}


def redact_url(url):
    parts = urllib.parse.urlsplit(url)
    return parts.netloc, parts.path


def track_record(row):
    record = {field: "" for field in CSV_FIELDS}
    record.update({
        "keyword": row["keyword"],
        "rank": row["rank"],
        "platform": row["platform"],
        "song": row["song"],
        "singer": row["singer"],
        "track_row_id": row["row_id"],
        "selected_id": str(row["selected_id"]),
    })
    body = {
        "platform": row["platform"],
        "query": row["song"],
        "selected_id": str(row["selected_id"]),
        "quality": QUALITY,
        "streaming_mode": None,
        "include_cover": False,
    }
    started = time.time()
    sequence = []
    try:
        payload, retries, post_status = api_post("/playbacks", body)
        record["http_post_status"] = post_status
    except Exception as error:  # noqa: BLE001
        record["blocked_stage"] = "PlaybackResolver.waitUntilReady"
        record["failed_reason"] = f"POST /playbacks failed: {type(error).__name__}"
        record["notes"] = f"POST request failed: {type(error).__name__}"
        return record
    record["post_retries"] = retries
    task = payload.get("task") or payload.get("playback") or payload
    task_id = str(task.get("id", ""))
    record["playback_id"] = task_id
    status = task.get("status", "")
    record["first_status"] = status
    sequence.append(f"{status}@{time.time() - started:.2f}")
    deadline = started + POLL_DEADLINE
    ready_at = None
    while time.time() < deadline:
        if status == "failed":
            break
        if status == "completed":
            if ready_at is None:
                ready_at = time.time()
            break
        if status == "streaming" and ready_at is None:
            # Sample only a bounded prefix while the backend is streaming,
            # then keep polling until completed before measuring the full file.
            ready_at = time.time()
            audio = task.get("audio_url") or ""
            if audio:
                url = urllib.parse.urljoin(BASE + "/", audio)
                sample = os.path.join(DOWNLOAD_DIR, f"{row['platform']}-{row['rank']}-{task_id}.streaming.part")
                os.makedirs(DOWNLOAD_DIR, exist_ok=True)
                try:
                    observed = download_to(sample, url, 64 * 1024, 120, range_header="bytes=0-65535")
                    record["streaming_bytes"] = observed["bytes"]
                    record["streaming_content_length"] = observed["content_length"]
                    record["streaming_capped"] = observed["capped"]
                    record["audio_http_status"] = observed["status"]
                    record["content_type"] = observed["content_type"]
                    record["content_range"] = observed["content_range"]
                    record["accept_ranges"] = observed["accept_ranges"]
                    record["redirect_chain"] = "|".join(observed["chain"])
                    record["redirect_count"] = max(len(observed["chain"]) - 1, 0)
                except Exception as error:
                    record["notes"] = f"streaming sample failed: {type(error).__name__}"
                finally:
                    try: os.remove(sample)
                    except OSError: pass
        try:
            follow = api_get(f"/playbacks/{task_id}?" + urllib.parse.urlencode(
                {"since": status, "wait_ms": "8000"}))
        except Exception as error:  # noqa: BLE001
            record["notes"] = f"poll failed: {type(error).__name__}"[:300]
            break
        next_task = follow.get("task") or follow.get("playback") or follow
        next_status = next_task.get("status", "")
        if next_status != status:
            sequence.append(f"{next_status}@{time.time() - started:.2f}")
        task, status = next_task, next_status
    record["status_sequence"] = ">".join(sequence)
    record["final_status"] = status
    record["elapsed_total_s"] = f"{time.time() - started:.2f}"
    if ready_at is not None:
        record["elapsed_to_ready_s"] = f"{ready_at - started:.2f}"
    record["failed_error_code"] = task.get("error_code") or ""
    record["failed_reason"] = (task.get("error") or "")[:300]
    if status == "failed":
        record["failed_reason"] = "backend reported this item unplayable"
    # The task's own format/content_type/byte_size are frequently empty, so they
    # are only recorded here as a hint; the authoritative values come from the
    # audio endpoint's headers and the file magic.
    task_hint = {key: task.get(key) for key in ("format", "content_type", "byte_size")}
    if any(value not in (None, "") for value in task_hint.values()):
        record["notes"] = "task fields: " + json.dumps(task_hint, ensure_ascii=False)

    audio = task.get("audio_url") or ""
    if not audio:
        if status == "failed":
            record["blocked_stage"] = "backend failed"
        elif ready_at is None:
            record["blocked_stage"] = "PlaybackResolver.waitUntilReady (timeout)"
        else:
            record["blocked_stage"] = "PlaybackResolver.waitUntilReady (no audio_url)"
        return record
    url = urllib.parse.urljoin(BASE + "/", audio)
    host, path = redact_url(url)
    record["audio_url_host"] = host
    record["audio_url_path_redacted"] = path

    os.makedirs(DOWNLOAD_DIR, exist_ok=True)
    stem = f"{row['platform']}-{row['rank']}-{task_id}"

    # Only tasks first observed as streaming have a streaming-byte measurement.
    if not record["streaming_bytes"]:
        record["streaming_bytes"] = "not observed: task was completed at first observation"

    # 2. Full file once the backend says completed, compared with the length it
    #    declared. A half-written file left behind is deleted either way.
    if status == "completed":
        full_path = os.path.join(DOWNLOAD_DIR, stem + ".completed.part")
        try:
            completed = download_to(full_path, url, FULL_CAP, timeout=1800)
            received, length, capped, status_code = (completed[key] for key in ("bytes", "content_length", "capped", "status"))
            record["audio_http_status"] = status_code
            record["redirect_chain"] = "|".join(completed["chain"])
            record["redirect_count"] = max(len(completed["chain"]) - 1, 0)
            record["content_type"] = completed["content_type"]
            record["content_range"] = completed["content_range"]
            record["accept_ranges"] = completed["accept_ranges"]
            record["completed_bytes"] = received
            record["completed_capped"] = capped
            record["content_length"] = length
            range_total = completed["content_range"].rsplit("/", 1)[-1] if completed["content_range"] else ""
            total = int(range_total) if range_total.isdigit() else (int(length) if str(length).isdigit() else None)
            record["bytes_match_length"] = str(received == total) if total else "no trustworthy total length"
            if status_code >= 400:
                record["blocked_stage"] = "CompatibleAudio.localFile (full fetch " + str(status_code) + ")"
            magic = sniff_magic(full_path)
            record["magic_hex"] = binascii.hexlify(magic).decode()
            record["container_guess"] = guess_container(magic, completed["content_type"])
        except Exception as error:  # noqa: BLE001
            record["blocked_stage"] = "CompatibleAudio.localFile (full fetch failed)"
            record["notes"] = (record["notes"] + " | " if record["notes"] else "") + \
                f"full fetch failed: {type(error).__name__}"[:200]
        finally:
            try:
                os.remove(full_path)
            except OSError:
                pass
    if status == "failed":
        record["blocked_stage"] = "backend failed"
    elif not record["blocked_stage"]:
        record["blocked_stage"] = "none (ready + audio served)"
    return record


def content_type_probe(url, timeout=45):
    """Headers only, with the same redirect chain the App would follow."""
    with session().get(url, stream=True, timeout=timeout, allow_redirects=True) as response:
        chain = [f"{hop.status_code}->{urllib.parse.urlsplit(hop.headers.get('Location', '')).netloc}"
                 for hop in response.history]
        chain.append(f"{response.status_code}->{urllib.parse.urlsplit(response.url).netloc}")
        return {
            "status": response.status_code,
            "content_type": response.headers.get("Content-Type", ""),
            "content_length": response.headers.get("Content-Length", ""),
            "content_range": response.headers.get("Content-Range", ""),
            "accept_ranges": response.headers.get("Accept-Ranges", ""),
            "chain": "|".join(chain),
        }


def main():
    os.makedirs("reports", exist_ok=True)
    rows = collect_tracks()
    if not rows:
        print("no tracks found; nothing to report", flush=True)
        return 1
    pending = rows
    write_header = True
    handle = open(REPORT, "w", newline="", encoding="utf-8")
    writer = csv.DictWriter(handle, fieldnames=CSV_FIELDS)
    if write_header:
        writer.writeheader()
        handle.flush()
    print(f"[run] {len(pending)} tracks, report {REPORT}", flush=True)
    done = 0
    with ThreadPoolExecutor(max_workers=3) as pool:
        futures = {pool.submit(track_record, row): row for row in pending}
        for future in as_completed(futures):
            row = futures[future]
            try:
                record = future.result()
            except Exception as error:  # noqa: BLE001
                record = {field: "" for field in CSV_FIELDS}
                record.update({"keyword": row["keyword"], "rank": row["rank"],
                               "platform": row["platform"], "song": row["song"],
                               "selected_id": str(row["selected_id"]),
                               "blocked_stage": "script error",
                               "notes": f"{type(error).__name__}: {error}"[:300]})
            # header-only pass for the audio endpoint: content-type is recorded
            # even when the body download was capped or failed
            if record.get("audio_url_host") and not record.get("content_type"):
                url = urllib.parse.urljoin(
                    BASE + "/", f"/playbacks/{record['playback_id']}/audio")
                try:
                    header = content_type_probe(url)
                    record["content_type"] = header["content_type"]
                    record["content_range"] = header["content_range"]
                    record["accept_ranges"] = header["accept_ranges"]
                    if not record.get("content_length"):
                        record["content_length"] = header["content_length"]
                    if not record.get("redirect_chain"):
                        record["redirect_chain"] = header["chain"]
                except Exception as error:  # noqa: BLE001
                    record["notes"] = (record["notes"] + " | " if record["notes"] else "") + \
                        f"header probe: {type(error).__name__}"[:200]
            with _write_lock:
                writer.writerow(record)
                handle.flush()
            done += 1
            print(f"[{done}/{len(pending)}] {row['platform']} {row['song'][:28]} "
                  f"-> {record['final_status'] or 'n/a'} / {record['blocked_stage']}", flush=True)
    handle.close()
    print(f"[done] {done} rows appended to {REPORT}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
