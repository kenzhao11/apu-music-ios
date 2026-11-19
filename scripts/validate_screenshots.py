import json
from pathlib import Path
import sys


directory = Path(sys.argv[1])
result_bundle = Path(sys.argv[2])
if not result_bundle.is_dir():
    raise SystemExit(f"XCTest 结果包不存在: {result_bundle}")
pngs = list(directory.rglob("*.png"))
required_screens = [
    "首页", "搜索", "全屏播放", "迷你播放条", "我的收藏", "歌单详情",
]
manifest_path = directory / "manifest.json"
if not manifest_path.is_file():
    raise SystemExit(f"XCTest 截图附件清单不存在: {manifest_path}")
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
records = manifest if isinstance(manifest, list) else manifest.get("attachments", [])
names = [str(record.get("suggestedHumanReadableName", record.get("name", ""))) for record in records]
missing = [screen for screen in required_screens if not any(name.endswith(f"-{screen}") for name in names)]
if missing:
    print(f"缺少页面截图: {', '.join(missing)}")
    raise SystemExit(1)
if len(pngs) < len(required_screens):
    print(f"需要至少 {len(required_screens)} 张 PNG，当前为 {len(pngs)} 张")
    raise SystemExit(1)

for image in pngs:
    if image.stat().st_size < 10_000:
        raise SystemExit(f"截图文件大小异常: {image}")

print(json.dumps({"screenshots": len(pngs), "required_pages": required_screens}, ensure_ascii=False))
