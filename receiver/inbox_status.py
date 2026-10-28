#!/usr/bin/env python3
"""Show what the receiver has stored: chunk count, total size, and the latest uploads."""
import argparse
from datetime import datetime
from pathlib import Path
import sqlite3

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--data-dir", type=Path, default=Path("/srv/life-recorder"))
parser.add_argument("--last", type=int, default=10, help="How many recent chunks to list")
args = parser.parse_args()

db_path = args.data_dir / "inbox.sqlite3"
if not db_path.exists():
    raise SystemExit(f"No receiver database at {db_path}")
db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
db.row_factory = sqlite3.Row
try:
    rows = db.execute("SELECT * FROM chunks ORDER BY received DESC").fetchall()
finally:
    db.close()
files = [Path(r["path"]) for r in rows]
present = [f for f in files if f.exists()]
size = sum(f.stat().st_size for f in present)
hours = sum(r["duration"] for r in rows) / 3600
print(f"Chunks: {len(rows)} ({len(present)} audio files on disk, {size / 1e6:.1f} MB, {hours:.2f} h)")
print(f"Audio folder: {args.data_dir / 'audio'}")
zone = datetime.now().astimezone().strftime("%Z (UTC%z)")
print(f"Times shown in the server time zone: {zone}")
for r in rows[:args.last]:
    received = datetime.fromtimestamp(r["received"]).strftime("%Y-%m-%d %H:%M:%S")
    recorded = datetime.fromisoformat(r["started"].replace("Z", "+00:00")).astimezone().strftime("%Y-%m-%d %H:%M:%S")
    state = "ok" if Path(r["path"]).exists() else "MISSING"
    print(f"  recorded {recorded}  received {received}  {r['duration']:5.1f}s  {state}  {Path(r['path']).name}")
