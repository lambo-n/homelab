"""Run with: python3 -m unittest discover -s scripts/llm/tools -v

No network, no poppler/Tesseract: ocr._run (the sandbox call) is replaced by a
fake that records each step, so these tests check the flow and the limits.
"""
import http.server
import sys
import threading
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
import fetch  # noqa: E402
import ocr  # noqa: E402

BIG = b'x' * (ocr.MAX_BYTES + 10)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ctype = {'/doc.pdf': 'application/pdf', '/pic.png': 'image/png',
                 '/page': 'text/html', '/big.pdf': 'application/pdf'}.get(self.path)
        if ctype is None:
            self.send_response(404)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        body = BIG if self.path == '/big.pdf' else b'%PDF-fake'
        self.send_response(200)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


class FakeSandbox:
    """Stands in for ocr._run. `pdf_text` is what pdftotext returns."""

    def __init__(self, pages=3, pdf_text='', fail=None):
        self.pages, self.pdf_text, self.fail, self.calls = pages, pdf_text, fail, []

    def __call__(self, tool, args, data):
        self.calls.append((tool, args))
        if tool == self.fail:
            raise ocr.OcrError(f'{tool}-failed: boom')
        if tool == 'pdfinfo':
            return b'Title: x\nPages:          %d\n' % self.pages
        if tool == 'pdftotext':
            return self.pdf_text.encode()
        if tool == 'pdf-ocr-page':
            return b'scanned ' + args[0].encode()
        return b'  picture   text '


class OcrTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        cls.base = 'http://127.0.0.1:%d' % cls.srv.server_port
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.p = mock.patch.object(fetch, '_is_public', lambda ip: ip == '127.0.0.1')
        cls.p.start()

    @classmethod
    def tearDownClass(cls):
        cls.p.stop()
        cls.srv.shutdown()

    def run_ocr(self, path, sandbox, **kw):
        with mock.patch.object(ocr, '_run', sandbox):
            return ocr.ocr(self.base + path, **kw)

    def test_pdf_with_text_layer_skips_ocr(self):
        sb = FakeSandbox(pages=2, pdf_text='word ' * 100)
        out = self.run_ocr('/doc.pdf', sb)
        self.assertEqual((out['method'], out['pages'], out['truncated']), ('text-layer', 2, False))
        self.assertEqual([c[0] for c in sb.calls], ['pdfinfo', 'pdftotext'])

    def test_scanned_pdf_is_rasterised_per_page_and_ocrd(self):
        sb = FakeSandbox(pages=3, pdf_text='')
        out = self.run_ocr('/doc.pdf', sb)
        self.assertEqual(out['method'], 'ocr')
        self.assertEqual(out['text'], 'scanned 1 scanned 2 scanned 3')
        self.assertEqual([c[0] for c in sb.calls].count('pdf-ocr-page'), 3)

    def test_max_pages_limits_and_flags_truncation(self):
        sb = FakeSandbox(pages=30)
        out = self.run_ocr('/doc.pdf', sb, max_pages=2)
        self.assertEqual([c[0] for c in sb.calls].count('pdf-ocr-page'), 2)
        self.assertEqual((out['pages'], out['truncated']), (30, True))
        sb = FakeSandbox(pages=30)
        self.run_ocr('/doc.pdf', sb, max_pages=999)
        self.assertEqual([c[0] for c in sb.calls].count('pdf-ocr-page'), ocr.MAX_PAGES)

    def test_image_goes_straight_to_tesseract_and_whitespace_is_squashed(self):
        sb = FakeSandbox()
        out = self.run_ocr('/pic.png', sb)
        self.assertEqual(out['text'], 'picture text')
        self.assertEqual([c[0] for c in sb.calls], ['tesseract'])

    def test_max_chars_truncates(self):
        out = self.run_ocr('/pic.png', FakeSandbox(), max_chars=4)
        self.assertEqual((out['text'], out['truncated']), ('pict', True))

    def test_html_is_not_ocrd(self):
        sb = FakeSandbox()
        out = self.run_ocr('/page', sb)
        self.assertEqual(out['error'], 'unsupported-content-type: text/html')
        self.assertEqual(sb.calls, [])

    def test_oversize_download_is_refused_before_parsing(self):
        sb = FakeSandbox()
        out = self.run_ocr('/big.pdf', sb)
        self.assertTrue(out['error'].startswith('too-large'))
        self.assertEqual(sb.calls, [])

    def test_parser_failure_is_reported_as_data(self):
        out = self.run_ocr('/doc.pdf', FakeSandbox(fail='pdfinfo'))
        self.assertEqual(out['error'], 'pdfinfo-failed: boom')
        self.assertIsNone(out['text'])

    def test_private_address_is_blocked(self):
        out = ocr.ocr('http://192.168.50.107:8081/x.pdf')
        self.assertEqual(out['error'], 'blocked-address: 192.168.50.107')

    def test_missing_sandbox_is_reported_not_raised(self):
        with mock.patch('subprocess.run', side_effect=FileNotFoundError('sudo')):
            out = ocr.ocr(self.base + '/pic.png')
        self.assertTrue(out['error'].startswith('sandbox-unavailable'))

    def test_tools_run_only_through_the_sandbox_wrapper(self):
        fake = mock.Mock(return_value=mock.Mock(returncode=0, stdout=b'ok', stderr=b''))
        with mock.patch('subprocess.run', fake):
            ocr._run('tesseract', ['stdin', 'stdout'], b'img')
        self.assertEqual(fake.call_args.args[0][:4], ['sudo', '-n', ocr.SANDBOX, 'tesseract'])


if __name__ == '__main__':
    unittest.main()
