#!/usr/bin/env python3
"""Install the CPU transcriber next to an installed receiver: a private virtualenv with sherpa-onnx,
the SenseVoice int8 and Silero VAD models, a self-test, and a low-priority systemd service.

Run after setup_linux.py --install-service. Needs root, ffmpeg and python3-venv. Safe to re-run."""
import argparse
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import sys
import tarfile
import urllib.request

SERVICE = "life-recorder-transcriber"
SERVICE_USER = "liferecorder"
UNIT_PATH = Path("/etc/systemd/system") / (SERVICE + ".service")
INSTALL_DIR = Path("/opt/life-recorder")
VENV = INSTALL_DIR / "venv"
MODELS = INSTALL_DIR / "models"
SENSE_VOICE = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
RELEASES = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--data-dir", type=Path, default=Path("/srv/life-recorder"))
parser.add_argument("--threads", type=int, default=4, help="CPU threads for recognition")
parser.add_argument("--tz", default="Asia/Shanghai", help="Time zone for the daily transcript files")
parser.add_argument("--pip-index-url", help="e.g. https://pypi.tuna.tsinghua.edu.cn/simple for faster installs in China")
parser.add_argument("--model-base-url", default=RELEASES, help="Where to download the model files from")
args = parser.parse_args()

if os.geteuid() != 0:
    parser.error("run with sudo")
root = args.data_dir.resolve()
if not (root / "inbox.sqlite3").exists():
    sys.exit(f"No receiver at {root}; run setup_linux.py --install-service first")
try:
    pwd.getpwnam(SERVICE_USER)
except KeyError:
    sys.exit("The receiver service user is missing; run setup_linux.py --install-service first")
ffmpeg = shutil.which("ffmpeg")
if not ffmpeg:
    sys.exit("ffmpeg is missing. Install it with: sudo apt install -y ffmpeg")
if not 1 <= args.threads <= 64:
    parser.error("--threads must be between 1 and 64")

if not (VENV / "bin" / "python").exists():
    result = subprocess.run([sys.executable, "-m", "venv", str(VENV)])
    if result.returncode != 0:
        sys.exit("Could not create a virtualenv. Install it with: sudo apt install -y python3-venv")
pip = [str(VENV / "bin" / "pip"), "install", "--quiet", "--upgrade", "sherpa-onnx", "numpy"]
if args.pip_index_url:
    pip += ["--index-url", args.pip_index_url]
print("Installing sherpa-onnx (CPU only, no PyTorch or CUDA)...", flush=True)
subprocess.run(pip, check=True)


def download(url: str, target: Path):
    print(f"Downloading {url.rsplit('/', 1)[-1]} ...", flush=True)
    partial = target.with_name(target.name + ".part")
    with urllib.request.urlopen(url, timeout=60) as response, partial.open("wb") as out:
        total = int(response.headers.get("Content-Length") or 0)
        done, shown = 0, -10
        while block := response.read(1 << 20):
            out.write(block)
            done += len(block)
            percent = done * 100 // total if total else -1
            if percent >= shown + 10:
                shown = percent
                print(f"  {done / 1e6:.0f} MB" + (f" ({percent}%)" if total else ""), flush=True)
    os.replace(partial, target)


MODELS.mkdir(parents=True, exist_ok=True)
model_dir = MODELS / SENSE_VOICE
vad = MODELS / "silero_vad.onnx"
if not vad.exists():
    download(f"{args.model_base_url}/silero_vad.onnx", vad)
wanted = {f"{SENSE_VOICE}/model.int8.onnx", f"{SENSE_VOICE}/tokens.txt", f"{SENSE_VOICE}/test_wavs/zh.wav"}
if not all((MODELS / name).exists() for name in wanted):
    archive = MODELS / (SENSE_VOICE + ".tar.bz2")
    if not archive.exists():
        print("The model archive is about 1 GB. If GitHub is slow from your network, stop with Ctrl+C and\n"
              "download model.int8.onnx, tokens.txt and test_wavs/zh.wav into\n"
              f"  {model_dir}\n"
              "(see docs/vps-deploy.md), then re-run this script.", flush=True)
        download(f"{args.model_base_url}/{SENSE_VOICE}.tar.bz2", archive)
    print("Extracting the int8 model...", flush=True)
    with tarfile.open(archive) as tar:
        members = [m for m in tar.getmembers() if m.name in wanted and m.isfile()]
        if len(members) != len(wanted):
            sys.exit("The model archive is incomplete; delete it and re-run")
        tar.extractall(MODELS, members=members)
    archive.unlink()
for path in [INSTALL_DIR, MODELS, model_dir, model_dir / "test_wavs", *MODELS.rglob("*")]:
    os.chown(path, 0, 0)  # Archives carry their packager's user IDs.
    os.chmod(path, 0o755 if path.is_dir() else 0o644)

target = INSTALL_DIR / "transcriber.py"
shutil.copyfile(Path(__file__).with_name("transcriber.py"), target)
os.chmod(target, 0o644)
command = [str(VENV / "bin" / "python"), str(target), "--model-dir", str(model_dir), "--vad", str(vad),
           "--threads", str(args.threads), "--ffmpeg", ffmpeg]
print("Self-test on the bundled Mandarin sample:", flush=True)
subprocess.run(command + ["--data-dir", str(root), "--file", str(model_dir / "test_wavs" / "zh.wav")], check=True)

unit = f"""[Unit]
Description=Life Recorder transcription (CPU only, idle priority)
After=life-recorder.service

[Service]
User={SERVICE_USER}
Group={SERVICE_USER}
ExecStart={" ".join(command)} --data-dir {root} --tz {args.tz}
Restart=on-failure
RestartSec=30
# Only uses CPU time nothing else wants, so training jobs keep priority. GPUs are never touched.
CPUSchedulingPolicy=idle
Nice=19
IOSchedulingClass=idle
MemoryMax=4G
Environment=CUDA_VISIBLE_DEVICES=
Environment=OMP_NUM_THREADS={args.threads}
UMask=0077
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
PrivateNetwork=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
LockPersonality=yes
ReadWritePaths={root}

[Install]
WantedBy=multi-user.target
"""
if UNIT_PATH.exists() and UNIT_PATH.read_text() != unit:
    sys.exit(f"{UNIT_PATH} already exists with different settings; it was not modified")
UNIT_PATH.write_text(unit)
os.chmod(UNIT_PATH, 0o644)
subprocess.run(["systemctl", "daemon-reload"], check=True)
subprocess.run(["systemctl", "enable", SERVICE], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.run(["systemctl", "restart", SERVICE], check=True)
print(f"\nTranscriber running. Daily transcripts: {root / 'transcripts'}")
print(f"Progress: sudo journalctl -u {SERVICE} -f")
