#!/usr/bin/env python3
"""Show what the receiver has stored: chunks, total size, the latest uploads, and bookmarks."""
import argparse
from datetime import datetime, timedelta
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
    try:
        markers = db.execute("SELECT * FROM markers ORDER BY at DESC").fetchall()
    except sqlite3.OperationalError:
        markers = []  # The table appears when an updated receiver starts.
finally:
    db.close()
files = [Path(r["path"]) for r in rows]
present = [f for f in files if f.exists()]
size = sum(f.stat().st_size for f in present)
hours = sum(r["duration"] for r in rows) / 3600
print(f"Chunks: {len(rows)} ({len(present)} audio files on disk, {size / 1e6:.1f} MB, {hours:.2f} h)")
print(f"Audio folder: {args.data_dir / 'audio'}")
transcribed = sum(r["status"] == "transcribed" for r in rows)
retrying = sum(r["status"] == "pending" and r["attempts"] > 0 for r in rows)
waiting = sum(r["status"] == "pending" for r in rows)
print(f"Transcription: {transcribed} done, {waiting} waiting ({retrying} retrying after errors); "
      f"daily files in {args.data_dir / 'transcripts'}")
zone = datetime.now().astimezone().strftime("%Z (UTC%z)")
print(f"Times shown in the server time zone: {zone}")
for r in rows[:args.last]:
    received = datetime.fromtimestamp(r["received"]).strftime("%Y-%m-%d %H:%M:%S")
    recorded = datetime.fromisoformat(r["started"].replace("Z", "+00:00")).astimezone().strftime("%Y-%m-%d %H:%M:%S")
    state = "ok" if Path(r["path"]).exists() else "MISSING"
    print(f"  recorded {recorded}  received {received}  {r['duration']:5.1f}s  {state}  {Path(r['path']).name}")


def utc(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def local(value: str) -> str:
    return utc(value).astimezone().strftime("%Y-%m-%d %H:%M:%S")


print(f"\nMarkers: {len(markers)}")
for m in markers[:args.last]:
    at = utc(m["at"])
    # A marker belongs to the chunk whose recording covers its moment.
    covering = next((r for r in rows
                     if utc(r["started"]) <= at < utc(r["started"]) + timedelta(seconds=r["duration"])), None)
    where = (f"{Path(covering['path']).name} at {(at - utc(covering['started'])).total_seconds():.1f}s"
             if covering else "no uploaded audio covers this moment")
    note = f"  \"{m['note']}\"" if m["note"] else ""
    print(f"  {local(m['at'])}  {where}{note}")
