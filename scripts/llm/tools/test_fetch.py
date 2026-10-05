"""Run with: python3 -m unittest scripts/llm/tools/test_fetch.py -v

Needs no network. A local HTTP server stands in for the web; _is_public and
_resolve are patched so 127.0.0.1 counts as public for the transport tests,
while test_is_public checks the real classification table.
"""
import http.server
import sys
import threading
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
import fetch  # noqa: E402

BIG = b'a' * (fetch.MAX_BYTES + 5000)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        p = self.path
        if p == '/page':
            self._send(200, b'<html><head><title>T</title><script>x()</script></head>'
                            b'<body><p>hello   world</p></body></html>', 'text/html')
        elif p == '/latin1':
            self._send(200, 'caf\xe9'.encode('latin-1'), 'text/html; charset=iso-8859-1')
        elif p == '/meta':
            self._send(200, b'<meta charset="windows-1252"><p>\x93hi\x94</p>', 'text/html')
        elif p == '/big':
            self._send(200, BIG, 'text/plain')
        elif p == '/pdf':
            self._send(200, b'%PDF-1.4', 'application/pdf')
        elif p == '/404':
            self._send(404, b'nope', 'text/html')
        elif p == '/hop':
            self._redirect('/page')
        elif p == '/loop':
            self._redirect('/loop')
        elif p == '/to-private':
            self._redirect('http://127.0.0.2:%d/page' % self.server.server_port)
        else:
            self._send(404, b'', 'text/plain')

    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _redirect(self, to):
        self.send_response(302)
        self.send_header('Location', to)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def log_message(self, *a):
        pass


class FetchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        cls.base = 'http://127.0.0.1:%d' % cls.srv.server_port
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        # Only 127.0.0.1 counts as public here; 127.0.0.2 stays blocked.
        cls.patches = [
            mock.patch.object(fetch, '_is_public', lambda ip: ip == '127.0.0.1'),
        ]
        for p in cls.patches:
            p.start()

    @classmethod
    def tearDownClass(cls):
        for p in cls.patches:
            p.stop()
        cls.srv.shutdown()

    def test_extracts_text_and_title_and_skips_script(self):
        r = fetch.fetch(self.base + '/page')
        self.assertEqual(r['title'], 'T')
        self.assertEqual(r['text'], 'hello world')
        self.assertFalse(r['truncated'])

    def test_max_chars_truncates(self):
        r = fetch.fetch(self.base + '/page', max_chars=5)
        self.assertEqual(r['text'], 'hello')
        self.assertTrue(r['truncated'])

    def test_body_is_capped_not_read_whole(self):
        r = fetch.fetch(self.base + '/big', max_chars=10_000_000)
        self.assertTrue(r['truncated'])
        self.assertEqual(len(r['text']), fetch.MAX_BYTES)

    def test_charset_from_header(self):
        self.assertEqual(fetch.fetch(self.base + '/latin1')['text'], 'caf\xe9')

    def test_charset_from_meta(self):
        self.assertEqual(fetch.fetch(self.base + '/meta')['text'], '“hi”')

    def test_unknown_charset_falls_back(self):
        self.assertEqual(fetch._decode(b'ok', 'text/html; charset=nonsense'), 'ok')

    def test_pdf_is_unsupported(self):
        self.assertEqual(fetch.fetch(self.base + '/pdf')['error'],
                         'unsupported-content-type: application/pdf')

    def test_http_error(self):
        self.assertTrue(fetch.fetch(self.base + '/404')['error'].startswith('http-error: 404'))

    def test_follows_redirect_and_reports_final_url(self):
        r = fetch.fetch(self.base + '/hop')
        self.assertEqual(r['text'], 'hello world')
        self.assertEqual(r['url'], self.base + '/page')

    def test_redirect_loop_is_bounded(self):
        self.assertEqual(fetch.fetch(self.base + '/loop')['error'], 'too-many-redirects')

    def test_redirect_to_private_address_is_blocked(self):
        r = fetch.fetch(self.base + '/to-private')
        self.assertEqual(r['error'], 'blocked-address: 127.0.0.2')

    def test_unsupported_schemes(self):
        for u in ('file:///etc/passwd', 'ftp://example.com/x', 'gopher://x', 'http:///nohost'):
            self.assertEqual(fetch.fetch(u)['error'], 'unsupported-scheme', u)


class RealClassification(unittest.TestCase):
    def test_is_public(self):
        blocked = ['127.0.0.1', '10.0.0.5', '172.16.0.1', '192.168.50.107', '169.254.169.254',
                   '100.64.0.1', '0.0.0.0', '224.0.0.1', '::1', 'fe80::1', 'fc00::1',
                   '::ffff:127.0.0.1', '::ffff:192.168.1.1']
        allowed = ['8.8.8.8', '93.184.216.34', '2606:4700:4700::1111']
        for ip in blocked:
            self.assertFalse(fetch._is_public(ip), ip)
        for ip in allowed:
            self.assertTrue(fetch._is_public(ip), ip)

    def test_any_private_answer_blocks_the_host(self):
        with mock.patch.object(fetch, '_resolve', return_value=['8.8.8.8', '10.0.0.1']):
            with self.assertRaises(fetch.Blocked):
                fetch._pick_address('rebind.example', 80)

    def test_unpatched_loopback_and_lan_are_blocked_end_to_end(self):
        for u in ('http://127.0.0.1:8081/health', 'http://localhost/',
                  'http://192.168.50.107:8081/health', 'http://[::1]/',
                  'http://169.254.169.254/latest/meta-data/'):
            self.assertTrue(fetch.fetch(u)['error'].startswith('blocked-address'), u)

    def test_connection_is_pinned_to_the_checked_address(self):
        with mock.patch.object(fetch, '_resolve', return_value=['93.184.216.34']), \
                mock.patch('socket.create_connection', side_effect=OSError('stop')) as cc:
            r = fetch.fetch('http://pinned.example/')
        self.assertEqual(cc.call_args[0][0], ('93.184.216.34', 80))
        self.assertTrue(r['error'].startswith('network-error'))


if __name__ == '__main__':
    unittest.main()
