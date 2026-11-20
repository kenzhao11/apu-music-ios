#!/usr/bin/env python3
"""Align every song of the website playlist with what the iOS app would ask for.

Both sides are derived independently from their own source of truth:

* the website side follows ``D:\\Projects\\mhub-local\\frontend\\src`` — the
  imported-playlist row, ``utils/track.js`` (``selected_id = item.id``),
  ``App.vue`` (``createPlayback``), ``waitForReady`` and
  ``apis/media-routing.js`` (``audio_url`` for a native task);
* the app side follows ``ApuMusic/PlaybackResolver.swift`` (``PlaybackTarget``
  and ``waitUntilReady``) and ``ApuMusic/Models.swift``
  (``playbackSelectionID``, ``isReadyForNativePlayback``, ``nativeAudioURL``,
  ``PlaybackQuality.preferred``).

Each side posts its own ``POST /api/v1/playbacks`` for every song, waits for a
playable task the way its own code waits, then reads the audio the backend
served (container, real byte size, final domain) with a 4-byte ranged request.

Only the same matched source row is ever requested. The website has no
cross-platform fallback (``core/player/index.js`` marks a failed task
unplayable and skips it), so a second platform is never tried here either.

The start-up guards fail the run when the shipped website or app code no longer
contains the expressions this script models, so a passing report cannot silently
describe code nobody ships.

Usage:
    python scripts/align_report.py                 # full playlist
    python scripts/align_report.py --limit 5       # smoke run
    python scripts/align_report.py --resume        # continue a stopped run
"""

import argparse
import csv
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import parse_qsl, quote, urlencode, urlsplit, urlunsplit

API = "https://kenmusic.kdns.fr/api/v1"
API_HOST = "kenmusic.kdns.fr"
PLAYLIST_ID = "spotify-liked"
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEBSITE_DEFAULT = r"D:\Projects\mhub-local\frontend\src"

# Website defaults, read from stores/status.js and components/player/ListeningSettings.vue.
WEBSITE_QUALITY_DEFAULT = "high"
WEBSITE_LOSSLESS_TIERS = ("lossless", "hires", "hi-res")
WEBSITE_PROGRESSIVE_FORMATS = ("flac", "mp3")

# App side, read from ApuMusic/Models.swift.
APP_QUALITY_DEFAULT = "high"
APP_LOSSLESS_TIERS = ("lossless", "hires", "hi-res")
APP_PROGRESSIVE_FORMATS = ("flac", "mp3")

MIN_REQUEST_INTERVAL = 0.30  # seconds between any two requests, both workers included

# Expressions that must still exist in the shipped code this script models.
APP_SOURCE_CHECKS = {
    "ApuMusic/PlaybackResolver.swift": [
        "self.platform = track.platform",
        "self.query = track.song",
        "self.selectedId = track.playbackSelectionID",
        "self.streamingMode = nil",
        "quality.rawValue",
        "guard track.canPlay else",
        "static func prepare(track: Track, quality: PlaybackQuality) async throws -> PreparedPlayback",
    ],
    "ApuMusic/Models.swift": [
        "var playbackSelectionID: String { selectedId ?? id }",
        "case standard, high, lossless, hires",
        "var isReadyForNativePlayback: Bool",
        "guard let path = audioURL, !path.isEmpty else { return nil }",
    ],
    "ApuMusic/Player.swift": [
        "PlaybackResolver.prepare(track: track, quality: quality)",
        "qualityDisplay",
        "guard track.canPlay else",
    ],
    "ApuMusic/DownloadManager.swift": [
        "PlaybackResolver.prepare(track: track, quality: .preferred)",
        "guard track.canPlay else",
    ],
}
WEBSITE_SOURCE_CHECKS = {
    "App.vue": [
        "selectedId: track.selected_id || track.source_id",
        "query: track.query || track.title",
        "quality: requestTrack.quality",
        "streamingMode: streamingMode || null",
    ],
    "utils/track.js": [
        "selected_id: item.id",
        "source_id: item.source_id || item.id",
    ],
    "stores/status.js": [
        'quality: "high"',
    ],
    "apis/music.js": [
        "quality,",
        "streaming_mode: streamingMode",
        "include_cover: includeCover",
    ],
    "apis/media-routing.js": [
        "? task.alac_source_url",
        ": wasm && task?.streaming_url ? task.streaming_url : task?.audio_url;",
    ],
    "stores/playlists.js": [
        "importedTrack(item, quality)",
    ],
}

CSV_FIELDS = [
    "index", "song", "singer", "album", "playlist_status", "playlist_platform", "playlist_row_id",
    "web_platform", "web_selected_id", "web_quality", "web_streaming_mode",
    "app_platform", "app_selected_id", "app_quality", "app_streaming_mode", "request_match",
    "web_task_id", "web_task_status", "web_media_platform", "web_track_id", "web_error_code",
    "app_task_id", "app_task_status", "app_media_platform", "app_track_id", "app_error_code",
    "web_audio_domain", "app_audio_domain", "web_url_structure", "app_url_structure",
    "web_actual_format", "web_actual_bitrate_kbps", "web_actual_bytes",
    "app_actual_format", "app_actual_bitrate_kbps", "app_actual_bytes", "probe_shared",
    "web_header_source", "web_header_fallback",
    "source_match", "song_id_match", "quality_match", "domain_match", "format_match", "url_structure_match",
    "result", "difference", "transport_note", "verified_at",
]

RESULT_SAME = "一致"
RESULT_DIFF = "不一致"
RESULT_UNPLAYABLE = "不可播"
RESULT_UNVERIFIED = "未验证"


# ---------------------------------------------------------------- HTTP layer

class RateLimiter:
    """One shared brake: a minimum spacing plus every 429's Retry-After."""

    def __init__(self, interval=MIN_REQUEST_INTERVAL):
        self._lock = threading.Lock()
        self._until = 0.0
        self._next_slot = 0.0
        self._interval = interval
        self.pauses = 0
        self.requests = 0

    def wait(self):
        while True:
            with self._lock:
                now = time.time()
                start = max(now, self._until)
                if start > self._next_slot:
                    self._next_slot = start
                delay = self._next_slot - now
                if delay <= 0:
                    self._next_slot += self._interval
                    self.requests += 1
                    return
            time.sleep(min(delay, 1.0))

    def pause(self, seconds):
        with self._lock:
            self.pauses += 1
            self._until = max(self._until, time.time() + max(seconds, 1))


LIMITER = RateLimiter()
_LOG_LOCK = threading.Lock()


def log(message):
    with _LOG_LOCK:
        print(message, flush=True)


def retry_after_seconds(value):
    text = str(value or "").strip()
    if not text:
        return 5.0
    if text.isdigit():
        return max(1.0, float(text))
    try:
        moment = datetime.datetime.strptime(text, "%a, %d %b %Y %H:%M:%S %Z")
        return max(1.0, moment.timestamp() - time.time())
    except ValueError:
        return 5.0


def read_bytes(path):
    with open(path, "rb") as handle:
        return handle.read()


def parse_headers(raw):
    """Last response block wins; a redirect chain leaves several blocks."""
    headers = {}
    for line in raw.splitlines():
        if line.lower().startswith("http/"):
            headers = {}
            continue
        if ":" not in line:
            continue
        name, _, value = line.partition(":")
        headers[name.strip().lower()] = value.strip()
    return headers


def curl(url, method="GET", body=None, ranged=False, attempts=4, timeout=40):
    """Returns (http_status, headers dict, final_url, body bytes)."""
    last_status = 0
    for attempt in range(attempts):
        LIMITER.wait()
        with tempfile.TemporaryDirectory() as folder:
            body_path = os.path.join(folder, "body")
            head_path = os.path.join(folder, "headers")
            command = ["curl.exe", "--silent", "--show-error", "--location", "--max-time", str(timeout),
                       "-D", head_path, "-o", body_path, "-w", "%{http_code} %{url_effective}"]
            if method == "POST":
                request_path = os.path.join(folder, "request.json")
                with open(request_path, "wb") as handle:
                    handle.write(json.dumps(body, ensure_ascii=False).encode("utf-8"))
                command += ["-H", "Content-Type: application/json", "--data-binary", "@" + request_path]
            if ranged:
                # Two bytes are enough for the container signature and the
                # headers carry the real size; the server never sends a file.
                command += ["-H", "Range: bytes=0-3"]
            command.append(url)
            done = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", errors="replace")
            parts = done.stdout.strip().split(" ")
            status = int(parts[0]) if parts and parts[0].isdigit() else 0
            final_url = parts[1] if len(parts) > 1 else url
            headers = parse_headers(read_bytes(head_path).decode("iso-8859-1", "replace"))
            payload = read_bytes(body_path) if os.path.exists(body_path) else b""
            last_status = status
            if status == 429:
                LIMITER.pause(retry_after_seconds(headers.get("retry-after")))
                continue
            if status >= 500 or status == 0:
                time.sleep(1.5 * (attempt + 1))
                continue
            return status, headers, final_url, payload
    return last_status, {}, url, b""


def api_json(path, method="GET", body=None):
    status, headers, final_url, payload = curl(API + path, method=method, body=body)
    if status != 200:
        return status, None, headers
    try:
        return status, json.loads(payload.decode("utf-8")), headers
    except json.JSONDecodeError:
        return status, None, headers


# ------------------------------------------------------- request derivation

def website_request(item):
    """stores/playlists.js importedTrack() -> utils/track.js -> App.vue createPlayback()."""
    # trackFromSearch: selected_id is the row id, source_id keeps the provider id.
    track = {
        "platform": item.get("platform") or "",
        "song": item.get("song") or "",
        "source_id": item.get("source_id") or item.get("id"),
        "selected_id": item.get("id"),
        "quality": WEBSITE_QUALITY_DEFAULT,
    }
    # requestedStreamingMode(): wasm_alac only for Apple Music lossless tiers.
    lossless = str(track["quality"]).lower() in WEBSITE_LOSSLESS_TIERS
    streaming = "wasm_alac" if track["platform"] == "applemusic" and lossless else None
    return {
        "platform": track["platform"],
        "query": track["song"],
        "selected_id": track["selected_id"] or track["source_id"],
        "quality": track["quality"],
        "streaming_mode": streaming,
        "include_cover": False,
    }


def app_request(item):
    """PlaybackTarget(track:quality:) from ApuMusic/PlaybackResolver.swift."""
    selected = item.get("selected_id") if item.get("selected_id") is not None else str(item["id"])
    return {
        "platform": item.get("platform") or "",
        "query": item.get("song") or "",
        "selected_id": selected,
        "quality": APP_QUALITY_DEFAULT,
        # The app never asks for the WebAssembly packet transport it cannot read.
        "streaming_mode": None,
        "include_cover": False,
    }


def app_can_play(item):
    """Track.canPlay from ApuMusic/Models.swift; the app posts nothing otherwise."""
    if item.get("playable") is False:
        return False
    if (item.get("status") or "") == "missing":
        return False
    return bool(item.get("platform"))


def website_ready(task):
    """App.vue waitForReady(): may this task already feed a native player?"""
    if task.get("status") == "failed":
        return "failed"
    quality = str(task.get("quality") or "").strip().lower()
    container = str(task.get("format") or "").strip().lower()
    progressive = container in WEBSITE_PROGRESSIVE_FORMATS
    needs_completed = task.get("streaming_mode") == "wasm_alac" or (
        quality in WEBSITE_LOSSLESS_TIERS and not progressive)
    if task.get("status") == "completed":
        return "ready"
    if task.get("status") == "streaming" and not needs_completed:
        return "ready"
    return "waiting"


def app_ready(task):
    """PlaybackTask.isReadyForNativePlayback from ApuMusic/Models.swift."""
    if task.get("status") == "failed":
        return "failed"
    if task.get("status") == "completed":
        return "ready"
    if task.get("status") != "streaming":
        return "waiting"
    if task.get("streaming_mode") == "wasm_alac":
        return "waiting"
    quality = str(task.get("quality") or "").strip().lower()
    container = str(task.get("format") or "").strip().lower()
    progressive = container in APP_PROGRESSIVE_FORMATS
    if quality in APP_LOSSLESS_TIERS and not progressive:
        return "waiting"
    return "ready"


def website_audio_url(task):
    """apis/media-routing.js playbackAudioUrl() for a native (non wasm) task."""
    if task.get("status") == "completed" and task.get("alac_source_url") and task.get("streaming_mode") == "wasm_alac":
        endpoint = task["alac_source_url"]
    elif task.get("streaming_mode") == "wasm_alac" and task.get("streaming_url"):
        endpoint = task["streaming_url"]
    else:
        endpoint = task.get("audio_url") or ""
    return absolute_audio_url(endpoint, task.get("id"))


def app_audio_url(task):
    """PlaybackTask.nativeAudioURL(relativeTo:) from ApuMusic/Models.swift.

    The app plays `audio_url` only; `alac_source_url` belongs to the packet
    transport it never requests.
    """
    if task.get("status") not in ("completed", "streaming"):
        return ""
    return absolute_audio_url(task.get("audio_url") or "", task.get("id"))


def absolute_audio_url(endpoint, task_id):
    if not endpoint:
        return ""
    if endpoint.startswith("http://") or endpoint.startswith("https://"):
        parts = urlsplit(endpoint)
        query = [(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True) if k != "v"]
        if task_id is not None:
            query.append(("v", str(task_id)))
        return urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(query), parts.fragment))
    if not endpoint.startswith("/"):
        endpoint = "/" + endpoint
    base_path = "/api/v1"
    path = endpoint if endpoint.startswith(base_path + "/") else base_path + endpoint
    parts = urlsplit("https://" + API_HOST + path)
    query = [(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True) if k != "v"]
    if task_id is not None:
        query.append(("v", str(task_id)))
    return urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(query), parts.fragment))


def load_task(created, ready_predicate):
    """POST already answered; poll while the client's own rule still waits."""
    task = created
    for _ in range(12):
        state = ready_predicate(task)
        if state in ("ready", "failed"):
            return task, state
        identifier = task.get("id")
        if identifier is None:
            return task, "failed"
        status, payload, _ = api_json("/playbacks/{}?since={}&wait_ms=8000".format(
            quote(str(identifier), safe=""), quote(str(task.get("status") or ""), safe="")))
        if status != 200 or not payload:
            return task, "unverified"
        task = unwrap_task(payload) or task
    return task, ready_predicate(task)


def unwrap_task(payload):
    if not isinstance(payload, dict):
        return None
    for key in ("playback", "task"):
        value = payload.get(key)
        if isinstance(value, dict):
            return value
    return payload


# --------------------------------------------------------------- audio probe

class ProbeCache:
    def __init__(self):
        self._lock = threading.Lock()
        self._cache = {}

    def get(self, url):
        with self._lock:
            return self._cache.get(url)

    def put(self, url, value):
        with self._lock:
            self._cache[url] = value


PROBES = ProbeCache()


def probe_audio(url):
    """4 bytes + headers of the real audio the backend serves."""
    if not url:
        return None
    cached = PROBES.get(url)
    if cached is not None:
        value = dict(cached)
        value["shared"] = True
        return value
    status, headers, final_url, payload = curl(url, ranged=True, timeout=30)
    parts = urlsplit(final_url)
    mime = headers.get("content-type", "").lower()
    content_range = headers.get("content-range", "")
    total = None
    match = re.search(r"/(\d+)\s*$", content_range)
    if match:
        total = int(match.group(1))
    signature = payload[:4]
    if signature == b"fLaC" or "flac" in mime:
        container = "FLAC"
    elif signature.startswith(b"ID3") or "mpeg" in mime or "mp3" in mime:
        container = "MP3"
    elif "mp4" in mime or "aac" in mime or "m4a" in mime:
        container = "AAC"
    elif len(signature) >= 2 and signature[0] == 0xFF and (signature[1] & 0xE0) == 0xE0:
        # MPEG audio and ADTS share the sync word; the layer bits separate them.
        container = "AAC" if (signature[1] & 0x06) == 0 else "MP3"
    elif mime:
        container = mime.replace("audio/", "").upper()
    else:
        container = ""
    # A total size only counts when the server really answered the ranged read.
    sized = status == 206 and total is not None
    value = {
        "ok": status in (200, 206),
        "http": status,
        "domain": parts.netloc.lower(),
        "path": parts.path,
        "format": container,
        "bytes": total if sized else None,
        "bitrate": None,
        "source": headers.get("x-mhub-source", ""),
        "fallback": headers.get("x-mhub-fallback", ""),
        "shared": False,
    }
    PROBES.put(url, dict(value))
    return value


def url_structure(probe):
    """scheme/host/path template: signatures and ids are not part of it."""
    if not probe:
        return ""
    segments = []
    for segment in probe["path"].split("/"):
        if not segment:
            continue
        if re.fullmatch(r"\d{8,}", segment):
            segments.append("{date}")
        elif re.fullmatch(r"[0-9a-fA-F]{16,}", segment):
            segments.append("{id}")
        elif re.fullmatch(r"[a-z]+--.*--[a-z]+", segment):
            segments.append("{playback}")
        elif len(segment) > 40:
            segments.append("{token}")
        else:
            segments.append(segment)
    if segments and "." in segments[-1]:
        stem, _, extension = segments[-1].rpartition(".")
        if len(stem) > 12:
            segments[-1] = "{file}." + extension
    extension = os.path.splitext(probe["path"])[1].lower()
    return "https://{}/{} | ext={}".format(probe["domain"], "/".join(segments), extension or "-")


# ------------------------------------------------------------- source guards

def file_digest(path):
    try:
        return hashlib.sha256(read_bytes(path)).hexdigest()[:16]
    except OSError:
        return ""


def verify_sources(website_root):
    problems = []
    for relative, needles in APP_SOURCE_CHECKS.items():
        path = os.path.join(REPO, relative)
        if not os.path.exists(path):
            problems.append("missing app file " + path)
            continue
        text = read_bytes(path).decode("utf-8", "replace")
        for needle in needles:
            if needle not in text:
                problems.append("{}: missing `{}`".format(relative, needle))
    for relative, needles in WEBSITE_SOURCE_CHECKS.items():
        path = os.path.join(website_root, relative)
        if not os.path.exists(path):
            problems.append("missing website file " + path)
            continue
        text = read_bytes(path).decode("utf-8", "replace")
        for needle in needles:
            if needle not in text:
                problems.append("{}: missing `{}`".format(relative, needle))
    return problems


def source_digests(website_root):
    digests = {}
    for relative in list(APP_SOURCE_CHECKS) :
        digests["app:" + relative] = file_digest(os.path.join(REPO, relative))
    for relative in list(WEBSITE_SOURCE_CHECKS):
        digests["website:" + relative] = file_digest(os.path.join(website_root, relative))
    return digests


# ------------------------------------------------------------------ one song

def quality_state(probe):
    """(format, kbps) only when the real audio was measurable from a ranged read."""
    if not probe or not probe.get("ok"):
        return None
    if not probe.get("format"):
        return None
    if not probe.get("bitrate"):
        # Format known but size/length missing: the actual quality is unknown,
        # and unknown must never be treated as equal.
        return None
    return (probe["format"], probe["bitrate"])


def compare(item):
    row = {field: "" for field in CSV_FIELDS}
    row.update({
        "index": item.get("position", ""),
        "song": item.get("song") or "",
        "singer": item.get("singer") or "",
        "album": item.get("album") or "",
        "playlist_status": item.get("status") or "",
        "playlist_platform": item.get("platform") or "",
        "playlist_row_id": item.get("id") or "",
    })

    web_body = website_request(item)
    app_body = app_request(item)
    for prefix, body in (("web", web_body), ("app", app_body)):
        row[prefix + "_platform"] = body["platform"]
        row[prefix + "_selected_id"] = body["selected_id"]
        row[prefix + "_quality"] = body["quality"]
        row[prefix + "_streaming_mode"] = body["streaming_mode"] or ""
    row["request_match"] = str(web_body == app_body)
    notes = []
    if web_body["streaming_mode"] != app_body["streaming_mode"]:
        notes.append("传输参数不同（网站 wasm_alac / App null）：Apple Music 无损需要网站的 WebAssembly 解码器，"
                     "App 改用同一任务的兼容音频，音源与档位不变，真机未验证")
    row["transport_note"] = "；".join(notes)

    sides = {}
    for prefix, body, ready_predicate, url_builder in (
        ("web", web_body, website_ready, website_audio_url),
        ("app", app_body, app_ready, app_audio_url),
    ):
        if prefix == "app" and not app_can_play(item):
            # Track.canPlay is false, so PlaybackResolver.prepare() never posts
            # and DownloadManager refuses: record the skip, not a request.
            row["app_task_status"] = "skipped-canPlay-false"
            sides[prefix] = {"state": "skipped", "error": "canPlay=false"}
            continue
        status, payload, _ = api_json("/playbacks", method="POST", body=body)
        if status != 200 or not payload:
            row[prefix + "_task_status"] = "http-{}".format(status)
            sides[prefix] = {"error": "http-{}".format(status)}
            continue
        created = unwrap_task(payload)
        if not created:
            row[prefix + "_task_status"] = "no-task"
            sides[prefix] = {"error": "no-task"}
            continue
        task, state = load_task(created, ready_predicate)
        row[prefix + "_task_id"] = str(task.get("id") or "")
        row[prefix + "_task_status"] = str(task.get("status") or "")
        row[prefix + "_media_platform"] = str(task.get("platform") or "")
        row[prefix + "_track_id"] = str(task.get("track_id") or task.get("selected_id") or "")
        row[prefix + "_error_code"] = str(task.get("error_code") or "")
        if state in ("failed", "unverified"):
            sides[prefix] = {"state": state, "task": task,
                             "error": task.get("error_code") or task.get("error") or state}
            continue
        sides[prefix] = {"state": "ready", "task": task, "url": url_builder(task)}

    web = sides.get("web", {})
    app = sides.get("app", {})

    duration = None
    for side in (web, app):
        task = side.get("task") or {}
        if task.get("duration"):
            duration = float(task["duration"])
            break
    if duration is None and item.get("duration"):
        duration = float(item["duration"])

    for prefix, side in (("web", web), ("app", app)):
        if side.get("state") != "ready":
            continue
        probe = probe_audio(side.get("url"))
        if not probe or not probe.get("ok"):
            side["state"] = "unverified"
            side["error"] = "audio-http-{}".format((probe or {}).get("http", 0))
            continue
        if probe.get("bytes") and duration:
            probe["bitrate"] = int(round(probe["bytes"] * 8 / duration / 1000))
        side["probe"] = probe
        row[prefix + "_audio_domain"] = probe["domain"]
        row[prefix + "_url_structure"] = url_structure(probe)
        row[prefix + "_actual_format"] = probe.get("format") or ""
        row[prefix + "_actual_bitrate_kbps"] = str(probe.get("bitrate") or "")
        row[prefix + "_actual_bytes"] = str(probe.get("bytes") or "")
        if prefix == "web":
            row["web_header_source"] = probe.get("source") or ""
            row["web_header_fallback"] = probe.get("fallback") or ""
        if prefix == "app":
            row["probe_shared"] = str(bool(probe.get("shared")))

    web_ready_state = web.get("state") == "ready"
    app_ready_state = app.get("state") == "ready"
    web_failed = web.get("state") == "failed"
    app_failed = app.get("state") == "failed"
    web_unverified = web.get("state") == "unverified" or not web
    app_unverified = app.get("state") == "unverified" or not app
    app_skipped = app.get("state") == "skipped"

    if web_ready_state and app_ready_state:
        web_quality = quality_state(web["probe"])
        app_quality = quality_state(app["probe"])
        row["source_match"] = str((web["task"].get("platform") or "") == (app["task"].get("platform") or ""))
        row["song_id_match"] = str(str(web["task"].get("track_id") or "") == str(app["task"].get("track_id") or ""))
        row["domain_match"] = str(web["probe"]["domain"] == app["probe"]["domain"])
        row["format_match"] = str(web["probe"].get("format") == app["probe"].get("format"))
        row["url_structure_match"] = str(row["web_url_structure"] == row["app_url_structure"])
        quality_known = web_quality is not None and app_quality is not None
        row["quality_match"] = str(quality_known and web_quality == app_quality)
        differences = []
        if row["request_match"] != "True":
            differences.append("请求参数不同")
        if row["source_match"] != "True":
            differences.append("音源不同 {}/{}".format(web["task"].get("platform"), app["task"].get("platform")))
        if row["song_id_match"] != "True":
            differences.append("歌曲ID不同 {}/{}".format(web["task"].get("track_id"), app["task"].get("track_id")))
        if row["domain_match"] != "True":
            differences.append("播放域名不同 {}/{}".format(web["probe"]["domain"], app["probe"]["domain"]))
        if row["format_match"] != "True":
            differences.append("实际格式不同 {}/{}".format(web["probe"].get("format"), app["probe"].get("format")))
        if row["url_structure_match"] != "True":
            differences.append("播放URL结构不同")
        if not quality_known:
            row["result"] = RESULT_UNVERIFIED
            row["difference"] = "实际音质无法判定（缺少 206/Content-Range 或时长）：web={} app={}".format(
                web_quality or "未知", app_quality or "未知")
            row["verified_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
            return row
        if row["quality_match"] != "True":
            differences.append("实际音质不同 {}k/{}k".format(web_quality[1], app_quality[1]))
        row["difference"] = "；".join(differences)
        row["result"] = RESULT_SAME if not differences else RESULT_DIFF
    elif app_skipped and web_failed:
        row["result"] = RESULT_UNPLAYABLE
        row["difference"] = "两端都不可播：网站发起请求后失败（{}），App 按 canPlay=false 直接不入队".format(web.get("error"))
    elif app_skipped and web_ready_state:
        row["result"] = RESULT_DIFF
        row["difference"] = "网站可播但 App 预判不可播（canPlay=false），需要复核"
    elif app_skipped:
        row["result"] = RESULT_UNVERIFIED
        row["difference"] = "未完成验证：网站侧 {}，App 按 canPlay=false 未请求".format(
            web.get("state") or web.get("error") or "missing")
    elif web_failed and app_failed:
        row["result"] = RESULT_UNPLAYABLE
        row["difference"] = "两端均不可播：{}/{}".format(web.get("error"), app.get("error"))
    elif web_unverified or app_unverified:
        row["result"] = RESULT_UNVERIFIED
        row["difference"] = "未完成验证：web={} app={}".format(
            web.get("state") or web.get("error") or "missing", app.get("state") or app.get("error") or "missing")
    else:
        row["result"] = RESULT_DIFF
        row["difference"] = "可播状态不一致：web={} app={}".format(
            web.get("state") or web.get("error"), app.get("state") or app.get("error"))
    row["verified_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    return row


# -------------------------------------------------------------------- driver

def fetch_playlist():
    status, payload, _ = api_json("/local/imported-playlists/" + PLAYLIST_ID)
    if status != 200 or not payload:
        raise SystemExit("playlist request failed with HTTP {}".format(status))
    items = payload.get("items") or []
    if not items:
        raise SystemExit("playlist returned no items")
    return payload.get("name") or PLAYLIST_ID, items


def load_done(path):
    done = {}
    if not os.path.exists(path):
        return done
    with open(path, "r", encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            if row.get("result") and row.get("result") != RESULT_UNVERIFIED:
                done[row["index"]] = row
    return done


def write_csv(path, rows):
    with open(path, "w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=CSV_FIELDS)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: row.get(field, "") for field in CSV_FIELDS})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--limit", type=int, default=0, help="only the first N songs")
    parser.add_argument("--start", type=int, default=0, help="skip the first N songs")
    parser.add_argument("--concurrency", type=int, default=2, help="parallel songs (max 2 by policy)")
    parser.add_argument("--only", default="", help="comma separated playlist indexes")
    parser.add_argument("--out", default=os.path.join(REPO, "reports"))
    parser.add_argument("--website-src", default=WEBSITE_DEFAULT)
    parser.add_argument("--resume", action="store_true", help="keep rows from a previous run")
    parser.add_argument("--skip-guard", action="store_true", help="skip shipped-code checks (testing only)")
    arguments = parser.parse_args()

    os.makedirs(arguments.out, exist_ok=True)
    report_path = os.path.join(arguments.out, "align_report.csv")
    unplayable_path = os.path.join(arguments.out, "align_unplayable.csv")
    summary_path = os.path.join(arguments.out, "align_summary.json")

    if not arguments.skip_guard:
        problems = verify_sources(arguments.website_src)
        if problems:
            for problem in problems:
                log("SOURCE GUARD: " + problem)
            raise SystemExit("shipped code no longer matches what this script models")
        log("source guard: app and website expressions verified")

    name, items = fetch_playlist()
    log("playlist: {} ({} songs)".format(name, len(items)))

    if arguments.only:
        positions = {int(value) for value in arguments.only.split(",") if value.strip()}
        wanted = [item for item in items if int(item.get("position", -1)) in positions]
    else:
        wanted = items[arguments.start:]
        if arguments.limit:
            wanted = wanted[:arguments.limit]

    done = load_done(report_path) if arguments.resume else {}
    rows = [done[str(item.get("position"))] for item in items if str(item.get("position")) in done]
    pending = [item for item in wanted if str(item.get("position")) not in done]
    log("to do: {} songs, kept: {}".format(len(pending), len(rows)))

    concurrency = max(1, min(arguments.concurrency, 2))
    started = time.time()
    finished = 0

    def work(item):
        nonlocal finished
        try:
            row = compare(item)
        except Exception as error:  # a single song must never kill the run
            row = {field: "" for field in CSV_FIELDS}
            row.update({"index": item.get("position", ""), "song": item.get("song") or "",
                        "singer": item.get("singer") or "", "result": RESULT_UNVERIFIED,
                        "difference": "脚本异常：{}".format(error),
                        "verified_at": time.strftime("%Y-%m-%dT%H:%M:%S")})
        finished += 1
        if finished % 10 == 0 or finished == len(pending):
            log("  {} songs done ({:.1f}s elapsed, requests={}, pauses={})".format(
                finished, time.time() - started, LIMITER.requests, LIMITER.pauses))
        return row

    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        for row in pool.map(work, pending):
            rows.append(row)

    rows.sort(key=lambda row: int(row.get("index") or 0))
    write_csv(report_path, rows)
    write_csv(unplayable_path, [row for row in rows if row.get("result") == RESULT_UNPLAYABLE])

    counts = {}
    for row in rows:
        counts[row.get("result") or "未知"] = counts.get(row.get("result") or "未知", 0) + 1
    summary = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "playlist": name,
        "playlist_id": PLAYLIST_ID,
        "songs": len(rows),
        "counts": counts,
        "website_quality": WEBSITE_QUALITY_DEFAULT,
        "app_quality": APP_QUALITY_DEFAULT,
        "concurrency": concurrency,
        "min_request_interval_ms": int(MIN_REQUEST_INTERVAL * 1000),
        "requests_sent": LIMITER.requests,
        "rate_limit_pauses": LIMITER.pauses,
        "elapsed_seconds": round(time.time() - started, 1),
        "report": report_path,
        "unplayable_report": unplayable_path,
        "source_digests": source_digests(arguments.website_src),
        "notes": [
            "音源/歌曲ID 取自 POST /api/v1/playbacks 返回的 platform、track_id。",
            "实际音质取自 /playbacks/{id}/audio 重定向后真实响应的容器与 Content-Range 总字节数，按歌曲时长换算平均码率；缺任一条件记未验证，不用请求档位代替。",
            "播放URL 只比较 scheme/host/路径模板/后缀，签名与动态 id 不比较。",
            "网站侧按 App.vue/music.js/track.js/status.js/media-routing.js 推导；App 侧按 ApuMusic/PlaybackResolver.swift 与 Models.swift 推导，两侧代码互相独立。",
            "Apple Music 无损：网站请求 streaming_mode=wasm_alac（需要其 WebAssembly 解码器），App 固定 null（用同一任务的兼容音频）。默认档位 high 下两者都为 null；出现差异的行在 transport_note 与 request_match 中单独标出，不视为等价。",
            "一首歌只请求其已匹配的那一行，不跨平台换源（与网站核心播放器一致）。",
        ],
    }
    with open(summary_path, "w", encoding="utf-8", newline="") as handle:
        json.dump(summary, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    log("报告：{}".format(report_path))
    log("不可播：{}".format(unplayable_path))
    log("汇总：{}".format(summary_path))
    log(json.dumps({"counts": counts, "songs": len(rows)}, ensure_ascii=False))


if __name__ == "__main__":
    sys.exit(main())
