"""Run real M4A -> HTTPS upload -> local Whisper -> Markdown, using public JFK sample."""
import argparse
import hashlib
import http.client
import json
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "receiver"))
from receiver import Handler, Inbox, Receiver, worker

parser = argparse.ArgumentParser()
parser.add_argument("--model", type=Path, required=True)
parser.add_argument("--sample", type=Path, default=Path("/opt/homebrew/share/whisper-cpp/jfk.wav"))
parser.add_argument("--report", type=Path, required=True)
args = parser.parse_args()

with tempfile.TemporaryDirectory() as scratch:
    root = Path(scratch)
    clip = root / "sample.m4a"
    subprocess.run(["/opt/homebrew/bin/ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", str(args.sample),
                    "-c:a", "aac", "-b:a", "32k", str(clip)], check=True)
    cert, key = root / "test.crt", root / "test.key"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                    "-subj", "/CN=localhost", "-keyout", str(key), "-out", str(cert)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    inbox = Inbox(root / "inbox")
    server = Receiver(("127.0.0.1", 0), Handler)
    server.inbox = inbox
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(cert, key)
    server.socket = tls.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    stop = threading.Event()
    worker_thread = threading.Thread(target=worker, args=(inbox, stop, args.model.resolve(),
        "/opt/homebrew/bin/whisper-cli", "/opt/homebrew/bin/ffmpeg"), daemon=True)
    worker_thread.start()
    chunk_id = str(uuid.uuid4())
    payload = clip.read_bytes()
    sha = hashlib.sha256(payload).hexdigest()
    context = ssl.create_default_context(cafile=str(cert))
    client = http.client.HTTPSConnection("localhost", server.server_port, context=context, timeout=10)
    headers = {"Authorization": "Bearer " + inbox.token, "X-Device-ID": str(uuid.uuid4()),
               "X-Started-At": "1961-01-20T17:00:00.000Z", "X-Duration-Seconds": "11.0",
               "X-Audio-SHA256": sha, "Content-Type": "audio/mp4"}
    began = time.monotonic()
    client.request("POST", "/v1/chunks/" + chunk_id, payload, headers)
    response = client.getresponse()
    receipt = json.loads(response.read())
    assert response.status == 201 and receipt["durable"] and receipt["sha256"] == sha
    client.close()
    deadline = time.monotonic() + 240
    try:
        while time.monotonic() < deadline:
            row = inbox.receipt(chunk_id)
            if row["status"] == "complete":
                break
            if row["attempts"]:
                raise RuntimeError("Transcription failed: " + row["error"])
            time.sleep(0.5)
        else:
            raise RuntimeError("Transcription timed out")
        transcript = (inbox.root / "life.md").read_text()
        assert "country" in transcript.lower() and "ask" in transcript.lower(), transcript
        assert not Path(row["path"]).exists(), "Audio must be deleted only after transcript export"
        # A retry after the sender lost the acknowledgment must not duplicate the transcript.
        retry = http.client.HTTPSConnection("localhost", server.server_port, context=context, timeout=10)
        retry.request("POST", "/v1/chunks/" + chunk_id, payload, headers)
        response = retry.getresponse()
        assert response.status == 200 and json.loads(response.read())["durable"]
        retry.close()
        assert (inbox.root / "life.md").read_text() == transcript
        report = {"https_upload": "passed", "durable_checksum_receipt": "passed",
                  "whisper_model": args.model.name, "compressed_bytes": len(payload),
                  "elapsed_seconds": round(time.monotonic() - began, 2),
                  "retry_after_deletion": "passed", "audio_deleted_after_transcription": "passed",
                  "transcript": row["transcript"], "fixture": "public JFK sample distributed with whisper.cpp",
                  "iphone_recording_tested": False}
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
    finally:
        stop.set()
        worker_thread.join(timeout=10)
        server.shutdown()
        server.server_close()
