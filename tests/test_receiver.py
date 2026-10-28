import hashlib
import http.client
import json
from pathlib import Path
import socket
import sys
import tempfile
import threading
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "receiver"))
from receiver import Handler, Inbox, Receiver


class ReceiverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.inbox = Inbox(Path(self.temp.name))
        self.server = Receiver(("127.0.0.1", 0), Handler)
        self.server.inbox = self.inbox
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.device = str(uuid.uuid4())

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def upload(self, body=b"test audio", chunk_id=None, started="2026-09-10T12:00:00.000Z", **overrides):
        chunk_id = chunk_id or str(uuid.uuid4())
        headers = {
            "Authorization": "Bearer " + self.inbox.token,
            "X-Device-ID": self.device,
            "X-Started-At": started,
            "X-Duration-Seconds": "60.0",
            "X-Audio-SHA256": hashlib.sha256(body).hexdigest(),
            "Content-Type": "audio/mp4",
        }
        headers.update(overrides)
        client = http.client.HTTPConnection(*self.server.server_address, timeout=5)
        client.request("POST", "/v1/chunks/" + chunk_id, body, headers)
        response = client.getresponse()
        result = response.status, json.loads(response.read()), chunk_id
        client.close()
        return result

    def test_acknowledgment_survives_receiver_restart(self):
        status, receipt, chunk_id = self.upload()
        self.assertEqual(status, 201)
        self.assertTrue(receipt["durable"])
        reopened = Inbox(self.inbox.root)
        row = reopened.receipt(chunk_id)
        self.assertEqual(Path(row["path"]).read_bytes(), b"test audio")
        self.assertEqual(row["sha256"], receipt["sha256"])

    def test_lost_receipt_retry_is_idempotent_even_after_audio_deletion(self):
        _, _, chunk_id = self.upload()
        self.inbox.complete(chunk_id, "A test sentence.")
        status, receipt, _ = self.upload(chunk_id=chunk_id)
        self.assertEqual(status, 200)
        self.assertTrue(receipt["durable"])
        self.assertEqual(self.inbox.status(), {"complete": 1})
        self.assertEqual((self.inbox.root / "life.md").read_text().count("A test sentence."), 1)
        self.assertEqual(list(self.inbox.audio.iterdir()), [])

    def test_id_collision_rejected(self):
        _, _, chunk_id = self.upload()
        status, _, _ = self.upload(body=b"different recording", chunk_id=chunk_id)
        self.assertEqual(status, 409)
        self.assertEqual(Path(self.inbox.receipt(chunk_id)["path"]).read_bytes(), b"test audio")

    def test_checksum_failure_keeps_no_receipt(self):
        status, _, chunk_id = self.upload(**{"X-Audio-SHA256": "0" * 64})
        self.assertEqual(status, 422)
        self.assertIsNone(self.inbox.receipt(chunk_id))
        self.assertEqual(list(self.inbox.audio.iterdir()), [])

    def test_unauthorized_upload_rejected(self):
        status, _, _ = self.upload(**{"Authorization": "Bearer wrong"})
        self.assertEqual(status, 401)
        self.assertEqual(self.inbox.status(), {})

    def test_offline_backlog_is_exported_by_capture_time(self):
        _, _, later = self.upload(started="2026-09-10T16:00:00.000Z")
        self.inbox.complete(later, "Later audio.")
        _, _, earlier = self.upload(started="2026-09-09T16:00:00.000Z")
        self.inbox.complete(earlier, "Earlier audio.")
        text = (self.inbox.root / "life.md").read_text()
        self.assertLess(text.index("Earlier audio."), text.index("Later audio."))
        self.assertTrue((self.inbox.days / "2026-09-09.md").exists())
        self.assertTrue((self.inbox.days / "2026-09-10.md").exists())

    def test_untranscribed_audio_retained(self):
        _, _, chunk_id = self.upload()
        self.inbox.cleanup_completed()
        self.assertTrue(Path(self.inbox.receipt(chunk_id)["path"]).exists())

    def test_bad_metadata_and_path_rejected(self):
        for override in ({"X-Duration-Seconds": "NaN"}, {"X-Duration-Seconds": "601"},
                         {"X-Started-At": "2026-09-10"}, {"X-Device-ID": "../escape"}):
            self.assertEqual(self.upload(**override)[0], 400)
        self.assertEqual(self.upload(chunk_id="../escape")[0], 400)

    def test_concurrent_duplicate_uploads_get_one_receipt(self):
        chunk_id = str(uuid.uuid4())
        responses = []
        jobs = [threading.Thread(target=lambda: responses.append(self.upload(chunk_id=chunk_id)[0])) for _ in range(4)]
        for job in jobs: job.start()
        for job in jobs: job.join()
        self.assertEqual(sorted(responses), [200, 200, 200, 201])
        self.assertEqual(self.inbox.status(), {"pending": 1})

    def test_interrupted_upload_never_acknowledged(self):
        chunk_id = str(uuid.uuid4())
        headers = (f"POST /v1/chunks/{chunk_id} HTTP/1.1\r\nHost: localhost\r\n"
                   f"Authorization: Bearer {self.inbox.token}\r\nX-Device-ID: {self.device}\r\n"
                   "X-Started-At: 2026-09-10T12:00:00.000Z\r\nX-Duration-Seconds: 60\r\n"
                   f"X-Audio-SHA256: {hashlib.sha256(b'abcd').hexdigest()}\r\nContent-Length: 4\r\n\r\nab")
        with socket.create_connection(self.server.server_address) as client:
            client.sendall(headers.encode())
            client.shutdown(socket.SHUT_WR)
            response = client.recv(4096)
        self.assertIn(b"400", response)
        self.assertIsNone(self.inbox.receipt(chunk_id))

    def mark(self, payload, marker_id=None, token=None):
        marker_id = marker_id or str(uuid.uuid4())
        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        headers = {"Authorization": "Bearer " + (token or self.inbox.token), "X-Device-ID": self.device,
                   "Content-Type": "application/json"}
        client = http.client.HTTPConnection(*self.server.server_address, timeout=5)
        client.request("POST", "/v1/markers/" + marker_id, body, headers)
        response = client.getresponse()
        result = response.status, json.loads(response.read()), marker_id
        client.close()
        return result

    def test_marker_is_stored_once_and_retry_is_idempotent(self):
        status, receipt, marker_id = self.mark({"at": "2026-10-28T21:56:07.123+08:00", "note": "重点"})
        self.assertEqual((status, receipt), (201, {"id": marker_id, "durable": True}))
        status, _, _ = self.mark({"at": "2026-10-28T13:56:07.123Z", "note": "重点"}, marker_id=marker_id)
        self.assertEqual(status, 200, "Same moment in another time zone is the same marker")
        with self.inbox.connect() as db:
            rows = db.execute("SELECT at,note FROM markers").fetchall()
        self.assertEqual([tuple(r) for r in rows], [("2026-10-28T13:56:07.123Z", "重点")])

    def test_conflicting_marker_rejected(self):
        _, _, marker_id = self.mark({"at": "2026-10-28T13:56:07Z"})
        status, _, _ = self.mark({"at": "2026-10-28T13:57:00Z"}, marker_id=marker_id)
        self.assertEqual(status, 409)

    def test_bad_markers_rejected(self):
        for payload in ({"at": "2026-10-28T13:56:07"}, {"at": "yesterday"}, {}, [], b"not json",
                        {"at": "2026-10-28T13:56:07Z", "note": "x" * 501}, {"at": "2026-10-28T13:56:07Z", "note": 5}):
            self.assertEqual(self.mark(payload)[0], 400, payload)
        self.assertEqual(self.mark({"at": "2026-10-28T13:56:07Z"}, token="wrong")[0], 401)
        self.assertEqual(self.mark({"at": "2026-10-28T13:56:07Z"}, marker_id="../etc")[0], 400)
        self.assertEqual(self.inbox.marker_count(), 0)


if __name__ == "__main__":
    unittest.main()
