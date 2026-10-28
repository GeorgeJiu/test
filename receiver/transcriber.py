#!/usr/bin/env python3
"""Transcribe received audio on the CPU with SenseVoice (sherpa-onnx) and write one Markdown file per day.

Runs beside receiver.py and shares its SQLite database. Audio files are only read, never changed or deleted.
Transcribed chunks get status 'transcribed' and their sentences (JSON) in the transcript column."""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import threading
import time
from zoneinfo import ZoneInfo

import numpy as np
import sherpa_onnx

SAMPLE_RATE = 16000


class Transcriber:
    def __init__(self, model_dir: Path, vad_model: Path, threads: int, language: str, ffmpeg: str):
        self.recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
            model=str(model_dir / "model.int8.onnx"), tokens=str(model_dir / "tokens.txt"),
            num_threads=threads, use_itn=True, language=language)
        self.vad_config = sherpa_onnx.VadModelConfig()
        self.vad_config.silero_vad.model = str(vad_model)
        self.vad_config.silero_vad.min_silence_duration = 0.5
        self.vad_config.silero_vad.min_speech_duration = 0.25
        self.vad_config.silero_vad.max_speech_duration = 20
        self.vad_config.sample_rate = SAMPLE_RATE
        self.vad_config.num_threads = 1
        self.ffmpeg = ffmpeg

    def decode(self, path: Path) -> np.ndarray:
        pcm = subprocess.run([self.ffmpeg, "-nostdin", "-v", "error", "-i", str(path), "-f", "f32le",
                              "-ac", "1", "-ar", str(SAMPLE_RATE), "-"], check=True, capture_output=True).stdout
        return np.frombuffer(pcm, dtype=np.float32)

    def speech(self, samples: np.ndarray):
        """Yields (start seconds, samples) for each stretch of speech; silence is skipped."""
        vad = sherpa_onnx.VoiceActivityDetector(self.vad_config, buffer_size_in_seconds=120)
        window = self.vad_config.silero_vad.window_size
        found = []

        def drain():
            while not vad.empty():
                found.append((vad.front.start / SAMPLE_RATE, np.array(vad.front.samples, dtype=np.float32)))
                vad.pop()

        for i in range(0, len(samples), window):
            vad.accept_waveform(samples[i:i + window])
            drain()
        vad.flush()
        drain()
        return found

    def transcribe(self, path: Path) -> list[dict]:
        sentences = []
        for start, segment in self.speech(self.decode(path)):
            stream = self.recognizer.create_stream()
            stream.accept_waveform(SAMPLE_RATE, segment)
            self.recognizer.decode_stream(stream)
            text = stream.result.text.strip()
            if text:
                sentences.append({"start": round(start, 2), "end": round(start + len(segment) / SAMPLE_RATE, 2),
                                  "text": text})
        return sentences


def utc(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def atomic_write(path: Path, text: str):
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


class Store:
    def __init__(self, root: Path, zone: ZoneInfo):
        self.db_path = root / "inbox.sqlite3"
        self.out = root / "transcripts"
        self.out.mkdir(exist_ok=True, mode=0o700)
        self.zone = zone

    def connect(self):
        db = sqlite3.connect(self.db_path, timeout=30)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA synchronous=FULL")
        return db

    def next_pending(self):
        with self.connect() as db:
            return db.execute("SELECT * FROM chunks WHERE status='pending' AND retry_at<=? ORDER BY started,id LIMIT 1",
                              (time.time(),)).fetchone()

    def save(self, chunk_id: str, sentences: list[dict]):
        with self.connect() as db:
            db.execute("UPDATE chunks SET status='transcribed',transcript=?,error=NULL WHERE id=? AND status='pending'",
                       (json.dumps(sentences, ensure_ascii=False), chunk_id))

    def failed(self, row, error: Exception):
        attempts = row["attempts"] + 1
        with self.connect() as db:
            # Error type only: tool output could contain private content.
            db.execute("UPDATE chunks SET attempts=?,retry_at=?,error=? WHERE id=?",
                       (attempts, time.time() + min(3600, 30 * 2 ** min(attempts, 7)), type(error).__name__, row["id"]))

    def local_days(self, row) -> set:
        start = utc(row["started"]).astimezone(self.zone)
        end = start + timedelta(seconds=row["duration"])
        return {start.date(), end.date()}

    def export_day(self, day):
        """Rewrites one day's Markdown from the database, with markers interleaved as ⭐ lines."""
        begin = datetime.combine(day, datetime.min.time(), self.zone)
        end = begin + timedelta(days=1)
        lines = []
        with self.connect() as db:
            rows = db.execute("SELECT started,transcript FROM chunks WHERE status='transcribed' AND started>=? AND started<?",
                              (self.iso(begin - timedelta(minutes=15)), self.iso(end))).fetchall()
            try:
                markers = db.execute("SELECT at FROM markers WHERE at>=? AND at<?",
                                     (self.iso(begin), self.iso(end))).fetchall()
            except sqlite3.OperationalError:
                markers = []
        for row in rows:
            for sentence in json.loads(row["transcript"] or "[]"):
                moment = utc(row["started"]) + timedelta(seconds=sentence["start"])
                if begin <= moment < end:
                    lines.append((moment, 1, sentence["text"]))
        for marker in markers:
            lines.append((utc(marker["at"]), 0, None))
        lines.sort(key=lambda item: (item[0], item[1]))
        body, hour = [], None
        for moment, _, text in lines:
            local = moment.astimezone(self.zone)
            if local.hour != hour:
                hour = local.hour
                body.append(f"\n## {hour:02d}:00\n")
            stamp = local.strftime("%H:%M:%S")
            body.append(f"- ⭐ **{stamp} 重点标记**" if text is None else f"- {stamp} {text}")
        header = f"# {day.isoformat()}（{self.zone.key}）\n"
        atomic_write(self.out / f"{day.isoformat()}.md", header + "\n".join(body) + "\n")

    @staticmethod
    def iso(moment: datetime) -> str:
        return moment.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--model-dir", type=Path, required=True, help="Folder with model.int8.onnx and tokens.txt")
    parser.add_argument("--vad", type=Path, required=True, help="silero_vad.onnx")
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--language", default="zh", help="zh, en, yue, ja, ko or auto")
    parser.add_argument("--tz", default="Asia/Shanghai", help="Time zone for daily files")
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--once", action="store_true", help="Transcribe the current backlog, then exit")
    parser.add_argument("--file", type=Path, help="Transcribe one audio file and print it (self-test)")
    args = parser.parse_args()
    os.umask(0o077)
    transcriber = Transcriber(args.model_dir, args.vad, args.threads, args.language, args.ffmpeg)
    if args.file:
        for sentence in transcriber.transcribe(args.file):
            print(f"[{sentence['start']:7.2f}s] {sentence['text']}")
        return
    store = Store(args.data_dir.resolve(), ZoneInfo(args.tz))
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    print(f"Transcriber ready: {args.threads} threads, daily files in {store.out}", flush=True)
    while not stop.is_set():
        row = store.next_pending()
        if row is None:
            if args.once:
                break
            stop.wait(15)
            continue
        began = time.time()
        try:
            sentences = transcriber.transcribe(Path(row["path"]))
            store.save(row["id"], sentences)
            for day in store.local_days(row):
                store.export_day(day)
            print(f"Transcribed {row['id'][:8]} ({row['duration']:.0f}s audio, {len(sentences)} sentences) "
                  f"in {time.time() - began:.1f}s", flush=True)
        except Exception as error:  # Keep going; the chunk is retried later with backoff.
            store.failed(row, error)
            print(f"Failed {row['id'][:8]}: {type(error).__name__}", flush=True)


if __name__ == "__main__":
    main()
