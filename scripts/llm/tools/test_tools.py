"""Run with: python3 -m unittest discover -s scripts/llm/tools -v

Loads tools.py exactly as `llm --functions` does (exec in an empty namespace)
against a mock SearXNG, and checks the tool surface llm will register.
"""
import http.server
import json
import os
import threading
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).parent
RESULTS = [{'title': f'R{i}', 'url': f'https://example.com/{i}', 'content': 'x' * 500}
           for i in range(12)] + [{'title': 'no url', 'content': 'dropped'}]


class SearxHandler(http.server.BaseHTTPRequestHandler):
    seen = []

    def do_GET(self):
        SearxHandler.seen.append(self.path)
        if 'q=boom' in self.path:
            self.send_response(500)
            self.end_headers()
            return
        body = json.dumps({'results': RESULTS}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def load_like_llm(env):
    ns = {}
    with mock.patch.dict(os.environ, env):
        exec((HERE / 'tools.py').read_text(), ns)
    return ns


class ToolsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), SearxHandler)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.ns = load_like_llm({
            'LLM_TOOLS_DIR': str(HERE),
            'SEARXNG_URL': 'http://127.0.0.1:%d/' % cls.srv.server_port,
        })

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def test_llm_registers_exactly_two_tools(self):
        public = {k for k, v in self.ns.items() if callable(v) and not k.startswith('_')}
        self.assertEqual(public, {'web_search', 'fetch_url'})

    def test_tools_have_docstrings_and_type_hints_for_llm(self):
        for name in ('web_search', 'fetch_url'):
            fn = self.ns[name]
            self.assertTrue(fn.__doc__)
            self.assertTrue(fn.__annotations__)

    def test_web_search_trims_and_caps(self):
        out = json.loads(self.ns['web_search']('k3s release'))
        self.assertEqual(len(out['results']), 5)
        self.assertEqual(set(out['results'][0]), {'title', 'url', 'snippet'})
        self.assertEqual(len(out['results'][0]['snippet']), 300)
        self.assertIn('format=json', SearxHandler.seen[-1])
        self.assertIn('q=k3s+release', SearxHandler.seen[-1])

    def test_web_search_drops_results_without_url_and_clamps_max(self):
        out = json.loads(self.ns['web_search']('x', max_results=99))
        self.assertEqual(len(out['results']), 10)
        self.assertTrue(all(r['url'] for r in out['results']))
        self.assertEqual(len(json.loads(self.ns['web_search']('x', max_results=0))['results']), 1)

    def test_web_search_reports_failure_as_data(self):
        out = json.loads(self.ns['web_search']('boom'))
        self.assertTrue(out['error'].startswith('search-failed'))

    def test_web_search_unreachable_backend(self):
        ns = load_like_llm({'LLM_TOOLS_DIR': str(HERE), 'SEARXNG_URL': 'http://127.0.0.1:9'})
        self.assertTrue(json.loads(ns['web_search']('x'))['error'].startswith('search-failed'))

    def test_fetch_url_blocks_private_and_returns_json(self):
        out = json.loads(self.ns['fetch_url']('http://192.168.50.107:8081/health'))
        self.assertEqual(out['error'], 'blocked-address: 192.168.50.107')

    def test_fetch_url_clamps_max_chars(self):
        fake = mock.Mock(return_value={'text': 'ok'})
        with mock.patch.object(self.ns['_fetch'], 'fetch', fake):
            self.ns['fetch_url']('https://example.com', max_chars=10**9)
            self.ns['fetch_url']('https://example.com', max_chars=-5)
        self.assertEqual([c.args[1] for c in fake.call_args_list], [12000, 1])


if __name__ == '__main__':
    unittest.main()
