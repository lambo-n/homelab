"""Run with: python3 -m unittest scripts/llm/test_sd_proxy.py -v

Needs no network or GPU. A local HTTP server stands in for sd-server, answering
with each of its three image response shapes; the proxy runs on an ephemeral
port in front of it, saving into a temporary directory.
"""
import base64
import http.server
import importlib.machinery
import importlib.util
import json
import os
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest import mock

_path = str(Path(__file__).parent / "sd-proxy")
_loader = importlib.machinery.SourceFileLoader("sd_proxy", _path)
_spec = importlib.util.spec_from_loader("sd_proxy", _loader)
sd_proxy = importlib.util.module_from_spec(_spec)
_loader.exec_module(sd_proxy)

PNG = b"\x89PNG\r\n\x1a\n" + b"pixels"
JPG = b"\xff\xd8\xff\xe0" + b"pixels"
B64_PNG = base64.b64encode(PNG).decode()
B64_JPG = base64.b64encode(JPG).decode()
KEY = "k" * 64


class FakeSd(http.server.BaseHTTPRequestHandler):
    def _json(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path == "/v1/images/generations":
            self._json(200, {"data": [{"b64_json": B64_PNG}, {"b64_json": B64_JPG}]})
        elif self.path == "/sdapi/v1/txt2img":
            self._json(200, {"images": [B64_PNG]})
        elif self.path == "/v1/images/bad":
            self._json(400, {"error": "bad request"})
        else:
            self._json(404, {"error": "not found"})

    def do_GET(self):
        if self.path == "/sdcpp/v1/jobs/abcdef1234":
            self._json(200, {"status": "completed", "started": 1000, "completed": 1090,
                             "result": {"images": [{"index": 0, "b64_json": B64_PNG}]}})
        elif self.path == "/sdcpp/v1/jobs/running":
            self._json(200, {"status": "generating", "result": None})
        elif self.path == "/sdcpp/v1/capabilities":
            self._json(200, {"ok": True})
        else:
            self._json(404, {"error": "not found"})

    def log_message(self, *a):
        pass


def _serve(handler):
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


class ProxyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.upstream = _serve(FakeSd)
        port = cls.upstream.server_address[1]
        cls.patches = [
            mock.patch.object(sd_proxy, "UPSTREAM", f"http://127.0.0.1:{port}"),
            mock.patch.object(sd_proxy, "UPSTREAM_PORT", port),
        ]
        for p in cls.patches:
            p.start()
        sd_proxy.Proxy.keys = [KEY, "other" * 13]
        cls.proxy = _serve(sd_proxy.Proxy)
        cls.base = f"http://127.0.0.1:{cls.proxy.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.proxy.shutdown()
        cls.upstream.shutdown()
        for p in cls.patches:
            p.stop()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        p = mock.patch.object(sd_proxy.save_images, "__defaults__", (self.tmp.name,))
        p.start()
        self.addCleanup(p.stop)
        self.addCleanup(self.tmp.cleanup)
        self.stats = tempfile.TemporaryDirectory()
        p = mock.patch.object(sd_proxy, "STATS_DIR", self.stats.name)
        p.start()
        self.addCleanup(p.stop)
        self.addCleanup(self.stats.cleanup)
        sd_proxy._saved_jobs.clear()
        for k in sd_proxy._stats:
            sd_proxy._stats[k] = None if k == "last_seconds" else 0

    def metrics(self):
        with open(os.path.join(self.stats.name, "sd.prom")) as f:
            return dict(line.split() for line in f)

    def call(self, method, path, key=KEY, body=None):
        headers = {"Content-Type": "application/json"}
        if key:
            headers["Authorization"] = f"Bearer {key}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data,
                                     headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, r.headers, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.headers, e.read()

    def files(self):
        return sorted(os.listdir(self.tmp.name))

    def test_no_key_is_401(self):
        status, _, _ = self.call("POST", "/v1/images/generations", key=None, body={})
        self.assertEqual(status, 401)
        self.assertEqual(self.files(), [])

    def test_wrong_key_is_401(self):
        status, _, _ = self.call("GET", "/sdcpp/v1/capabilities", key="x" * 64)
        self.assertEqual(status, 401)

    def test_any_listed_key_works(self):
        status, _, _ = self.call("GET", "/sdcpp/v1/capabilities", key="other" * 13)
        self.assertEqual(status, 200)

    def test_health_needs_no_key(self):
        status, _, body = self.call("GET", "/health", key=None)
        self.assertEqual((status, json.loads(body)), (200, {"status": "ok"}))

    def test_openai_saves_each_image_with_its_type(self):
        status, headers, body = self.call("POST", "/v1/images/generations",
                                          body={"prompt": "a cat"})
        self.assertEqual(status, 200)
        self.assertEqual(len(json.loads(body)["data"]), 2)  # passed through
        files = self.files()
        self.assertEqual([f.rsplit(".", 1)[1] for f in files], ["png", "jpg"])
        self.assertEqual(headers["X-Saved-Images"], " ".join(files))
        with open(os.path.join(self.tmp.name, files[0]), "rb") as f:
            self.assertEqual(f.read(), PNG)

    def test_sync_generation_counted(self):
        self.call("POST", "/v1/images/generations", body={"prompt": "a cat"})
        m = self.metrics()
        self.assertEqual((m["sd_generations_total"], m["sd_images_total"]), ("1", "2"))
        self.assertEqual(m["sd_generations_in_flight"], "0")
        self.assertEqual(m["sd_generation_seconds_count"], "1")
        self.assertIn("sd_last_generation_seconds", m)

    def test_job_counted_once_with_its_own_duration(self):
        for _ in range(3):
            self.call("GET", "/sdcpp/v1/jobs/abcdef1234")
        m = self.metrics()
        self.assertEqual(m["sd_generations_total"], "1")
        self.assertEqual(m["sd_last_generation_seconds"], "90.000")

    def test_failed_generation_counted_as_error(self):
        self.call("POST", "/v1/images/edits", body={})  # fake answers 404
        m = self.metrics()
        self.assertEqual((m["sd_errors_total"], m["sd_generations_total"]), ("1", "0"))
        self.assertEqual(m["sd_generations_in_flight"], "0")

    def test_sdapi_saves(self):
        self.call("POST", "/sdapi/v1/txt2img", body={"prompt": "a cat"})
        self.assertEqual(len(self.files()), 1)

    def test_completed_job_saved_once_across_polls(self):
        for _ in range(3):
            status, _, _ = self.call("GET", "/sdcpp/v1/jobs/abcdef1234")
            self.assertEqual(status, 200)
        files = self.files()
        self.assertEqual(len(files), 1)
        self.assertIn("-abcdef12-0.png", files[0])

    def test_running_job_saves_nothing(self):
        self.call("GET", "/sdcpp/v1/jobs/running")
        self.assertEqual(self.files(), [])

    def test_upstream_error_passes_through(self):
        status, _, body = self.call("POST", "/v1/images/bad", body={})
        self.assertEqual((status, json.loads(body)), (400, {"error": "bad request"}))
        self.assertEqual(self.files(), [])

    def test_upstream_down_is_502(self):
        with mock.patch.object(sd_proxy, "UPSTREAM", "http://127.0.0.1:9"):
            status, _, _ = self.call("GET", "/sdcpp/v1/capabilities")
        self.assertEqual(status, 502)


class AuthorizedTest(unittest.TestCase):
    def test_header_forms(self):
        keys = [KEY]
        self.assertTrue(sd_proxy.authorized(f"Bearer {KEY}", keys))
        self.assertFalse(sd_proxy.authorized(KEY, keys))
        self.assertFalse(sd_proxy.authorized("Bearer ", keys))
        self.assertFalse(sd_proxy.authorized(None, keys))
        self.assertFalse(sd_proxy.authorized(f"Bearer {KEY}", []))


if __name__ == "__main__":
    unittest.main()
