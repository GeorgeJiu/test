#!/usr/bin/env python3
"""Prepare the receiver on an Ubuntu/Debian server: token, pinned self-signed certificate,
iPhone pairing link, and (with --install-service) a hardened systemd service.

Safe to re-run: existing tokens, certificates and audio are kept, and an existing
service file that differs is never overwritten."""
import argparse
import hashlib
import http.client
import ipaddress
import os
from pathlib import Path
import pwd
import shutil
import socket
import ssl
import subprocess
import sys
import time
from urllib.parse import urlencode

from receiver import Inbox

SERVICE = "life-recorder"
SERVICE_USER = "liferecorder"
UNIT_PATH = Path("/etc/systemd/system") / (SERVICE + ".service")
INSTALL_DIR = Path("/opt/life-recorder")

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--address", required=True, help="Public IP or hostname the iPhone will connect to")
parser.add_argument("--port", type=int, default=8765)
parser.add_argument("--listen", default="0.0.0.0",
                    help="Interface to listen on; use 127.0.0.1 behind a tunnel such as frp")
parser.add_argument("--data-dir", type=Path, default=Path("/srv/life-recorder"))
parser.add_argument("--install-service", action="store_true",
                    help="Create the service user and a systemd service, then start it (needs root)")
args = parser.parse_args()

try:
    ip = ipaddress.ip_address(args.address)
except ValueError:
    ip = None
    if not args.address or any(c in args.address for c in "/:@?# "):
        parser.error("--address must be a bare IP address or hostname")
if not 0 < args.port < 65536:
    parser.error("--port is out of range")
try:
    if ipaddress.ip_address(args.listen).version != 4:
        raise ValueError
except ValueError:
    parser.error("--listen must be an IPv4 address such as 0.0.0.0 or 127.0.0.1")
if args.install_service and os.geteuid() != 0:
    parser.error("--install-service must be run with sudo")

root = args.data_dir.resolve()
if root.exists() and any(root.iterdir()) and not (root / "receiver.token").exists():
    sys.exit(f"{root} already contains other files; choose an empty or new --data-dir")
os.umask(0o077)
inbox = Inbox(root)

cert, key = root / "receiver.crt", root / "receiver.key"
if not cert.exists() or not key.exists():
    san = f"IP:{ip}" if ip else f"DNS:{args.address}"
    # 825 days is the longest validity iOS accepts for TLS server certificates.
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:3072", "-nodes", "-sha256", "-days", "825",
                    "-subj", "/CN=Life Recorder", "-addext", "subjectAltName=" + san,
                    "-addext", "extendedKeyUsage=serverAuth", "-keyout", str(key), "-out", str(cert)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
pin = hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.read_text())).hexdigest()
host = f"[{ip}]" if ip and ip.version == 6 else args.address
url = f"https://{host}:{args.port}"
pair = "liferecorder://pair?" + urlencode({"url": url, "token": inbox.token, "pin": pin})


def port_in_use(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind(("0.0.0.0", port))
        except OSError:
            return True
    return False


def health() -> str:
    context = ssl.create_default_context(cafile=str(cert))
    context.check_hostname = False  # The certificate names the public address; this checks over loopback.
    connection = http.client.HTTPSConnection("127.0.0.1", args.port, context=context, timeout=5)
    try:
        connection.request("GET", "/health", headers={"Authorization": "Bearer " + inbox.token})
        response = connection.getresponse()
        return f"{response.status} {response.read().decode()}"
    finally:
        connection.close()


def hand_over_to_service_user():
    shutil.chown(root, SERVICE_USER, SERVICE_USER)
    for path in root.rglob("*"):
        shutil.chown(path, SERVICE_USER, SERVICE_USER)


def service_user_exists() -> bool:
    try:
        pwd.getpwnam(SERVICE_USER)
        return True
    except KeyError:
        return False


# A sudo re-run without --install-service must not leave root-owned files the service cannot write.
if (os.geteuid() == 0 and not args.install_service and service_user_exists()
        and root.stat().st_uid == pwd.getpwnam(SERVICE_USER).pw_uid):
    hand_over_to_service_user()

if args.install_service:
    if not service_user_exists():
        subprocess.run(["useradd", "--system", "--no-create-home", "--shell", "/usr/sbin/nologin", SERVICE_USER],
                       check=True)
    INSTALL_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(INSTALL_DIR, 0o755)
    target = INSTALL_DIR / "receiver.py"
    shutil.copyfile(Path(__file__).with_name("receiver.py"), target)
    os.chmod(target, 0o644)
    hand_over_to_service_user()
    command = (f"/usr/bin/python3 {target} --data-dir {root} --host {args.listen} --port {args.port}"
               f" --cert {cert} --key {key}")
    unit = f"""[Unit]
Description=Life Recorder audio receiver
After=network-online.target
Wants=network-online.target

[Service]
User={SERVICE_USER}
Group={SERVICE_USER}
# No --model: audio is only stored, never transcribed or deleted by the receiver.
ExecStart={command}
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LockPersonality=yes
ReadWritePaths={root}

[Install]
WantedBy=multi-user.target
"""
    if UNIT_PATH.exists() and UNIT_PATH.read_text() != unit:
        sys.exit(f"{UNIT_PATH} already exists with different settings; it was not modified")
    running = subprocess.run(["systemctl", "is-active", "--quiet", SERVICE]).returncode == 0
    if not running and port_in_use(args.port):
        sys.exit(f"Port {args.port} is already used by another program; choose another --port")
    UNIT_PATH.write_text(unit)
    os.chmod(UNIT_PATH, 0o644)
    subprocess.run(["systemctl", "daemon-reload"], check=True)
    subprocess.run(["systemctl", "enable", SERVICE], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["systemctl", "restart", SERVICE], check=True)
    for _ in range(10):
        time.sleep(1)
        try:
            print("Health check:", health())
            break
        except OSError as error:
            last = error
    else:
        print(f"Health check failed: {last}. See: journalctl -u {SERVICE} -n 50")

print(f"\nReceiver address: {url}")
print(f"Certificate fingerprint: {pin}")
print(f"Audio is stored in: {root / 'audio'}")
print("\nThe pairing link below contains your private token. Do not paste it into chats or share it.")
if shutil.which("qrencode"):
    subprocess.run(["qrencode", "-t", "ANSIUTF8", pair], check=False)
    print("Scan this QR code with the iPhone Camera app to pair Life Recorder.")
else:
    print("Install qrencode (sudo apt install qrencode) and re-run to get a QR code, or open this link on the iPhone:")
print(pair)
ufw = shutil.which("ufw")
if ufw and os.geteuid() == 0:
    status = subprocess.run([ufw, "status"], capture_output=True, text=True).stdout
    if status.startswith("Status: active") and f"{args.port}/tcp" not in status:
        print(f"\nThe ufw firewall is active. Allow the port with: sudo ufw allow {args.port}/tcp")
print(f"Also allow TCP port {args.port} in your cloud provider's security group if it has one.")
