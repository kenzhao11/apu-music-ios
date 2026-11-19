from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
import argparse
import json
import math
import struct


TRACKS = [
    {"id": "2138", "platform": "tencent", "song": "Hello", "singer": "Adele",
     "album": "Hello", "duration": 295, "cover": "", "source_id": "002Il7Ya1tZ6UZ",
     "playable": True},
    {"id": "35847388", "platform": "netease", "song": "Hello", "singer": "Adele",
     "album": "Hello", "duration": 295, "cover": "", "source_id": "35847388",
     "playable": True},
    {"id": "unavailable", "platform": "", "song": "Unavailable", "singer": "Unknown",
     "status": "missing", "playable": False},
]
PLAYLIST = {
    "id": "spotify-liked", "name": "Spotify 喜欢的歌曲", "cover": "",
    "track_count": 2, "matched": 2, "unmatched": 0, "updatedAt": 0,
}
PLAYLIST_DETAIL = {
    "id": "spotify-liked", "name": "Spotify 喜欢的歌曲", "cover": "",
    "items": [{**track, "status": "matched"} for track in TRACKS[:2]],
}


def silent_wav():
    sample_rate = 8000
    frame_count = sample_rate * 4
    data = bytes(frame_count * 2)
    return b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " + struct.pack(
        "<IHHIIHH", 16, 1, 1, sample_rate, sample_rate * 2, 2, 16
    ) + b"data" + struct.pack("<I", len(data)) + data


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def send_json(self, payload, status=200):
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self):
        self.send_json({})

    def do_GET(self):
        url = urlparse(self.path)
        route = url.path
        if route == "/health" or route == "/api/v1/health":
            return self.send_json({"ok": True})
        if route == "/api/v1/auth/config":
            return self.send_json({"enabled": False})
        if route == "/api/v1/platforms":
            return self.send_json([
                {"id": "applemusic", "label": "全部曲库"},
                {"id": "tencent", "label": "QQ 音乐"},
                {"id": "netease", "label": "网易云音乐"},
                {"id": "kugou", "label": "酷狗音乐"},
                {"id": "joox", "label": "JOOX"},
                {"id": "youtubemusic", "label": "YouTube Music"},
            ])
        if route == "/api/v1/search/mode":
            return self.send_json({"mode": "multi"})
        if route == "/api/v1/search":
            term = parse_qs(url.query).get("q", [""])[0].lower()
            return self.send_json([track for track in TRACKS if term in track["song"].lower()])
        if route.startswith("/api/v1/recommendations/home"):
            return self.send_json({"tracks": TRACKS, "mood": "精选", "playlists": []})
        if route == "/api/v1/local/imported-playlists":
            return self.send_json({"playlists": [PLAYLIST]})
        if route.startswith("/api/v1/local/imported-playlists/"):
            return self.send_json(PLAYLIST_DETAIL)
        if route.startswith("/api/v1/tracks/"):
            return self.send_json(TRACKS[0])
        if route.endswith("/loudness"):
            return self.send_json({"available": False})
        if route.startswith("/api/v1/lyrics"):
            return self.send_json({"available": True, "plain": "Hello\nHow are you?", "words": [
                {"start": 0, "end": 30, "words": [[0, 2, "Hello"]]},
            ]})
        if route.startswith("/api/v1/playbacks/") and route.endswith("/audio"):
            data = silent_wav()
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            return self.wfile.write(data)
        if route.startswith("/api/v1/playbacks/") and route.endswith("/lyrics"):
            return self.send_json({"available": True, "plain": "Hello", "words": []})
        if route.startswith("/api/v1/playbacks/"):
            task_id = route.rsplit("/", 1)[-1]
            return self.send_json({"id": task_id, "status": "completed", "audio_url": f"/api/v1/playbacks/{task_id}/audio"})
        return self.send_json({"detail": f"unknown route {route}"}, 404)

    def do_POST(self):
        route = urlparse(self.path).path
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        if route == "/api/v1/playbacks":
            track = next((item for item in TRACKS if item["id"] == str(body.get("selected_id"))), TRACKS[0])
            return self.send_json({
                "id": f"test-playback-{track['id']}", "status": "completed", "audio_url":
                f"/api/v1/playbacks/test-playback-{track['id']}/audio",
                "platform": track["platform"], "selected_id": track["id"],
                "track_id": track["source_id"], "query": track["song"], "artist": track["singer"],
            })
        if route == "/api/v1/recommendations/continue":
            return self.send_json({"tracks": [], "station": "test-station"})
        if route == "/api/v1/collections/match":
            return self.send_json({"items": [], "matched_count": 0})
        return self.send_json({"detail": "unknown route"}, 404)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18765)
    server = ThreadingHTTPServer(("127.0.0.1", parser.parse_args().port), Handler)
    server.serve_forever()
