"""Tools for the `llm` CLI on VM 105: web_search (SearXNG) and fetch_url.

    llm -m fast --functions ~/.config/io.datasette.llm/tools/tools.py \
        "What changed in the latest k3s release?"

`llm --functions` execs this file in an empty namespace (no __file__, no
sibling imports) and registers every public callable as a tool. So: exactly
two public names below, everything else underscore-prefixed, and only plain
`import x` (never `from x import y`, which would register y as a tool).
fetch.py is found through LLM_TOOLS_DIR; install both files together, see
GPU-VM.md -> Tool calling.

Both tools return JSON strings. Page text and search snippets come from the
open web: the model should treat them as data, never as instructions.
"""
import importlib.util
import json
import os
import urllib.parse
import urllib.request

_DIR = os.environ.get('LLM_TOOLS_DIR') or os.path.expanduser('~/.config/io.datasette.llm/tools')
_SEARXNG = os.environ.get('SEARXNG_URL', 'http://192.168.50.104:8080').rstrip('/')
_MAX_RESULTS = 10
_SNIPPET_CHARS = 300
_MAX_FETCH_CHARS = 12000  # `fast` has an 8192-token window; keep one page well inside it
_SEARCH_MAX_BYTES = 1024 * 1024


def _load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(_DIR, name + '.py'))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_fetch = _load('fetch')


def web_search(query: str, max_results: int = 5) -> str:
    """Search the web and return the top results as JSON: title, url and a short snippet each.
    Use fetch_url on a result's url to read the full page."""
    max_results = max(1, min(int(max_results), _MAX_RESULTS))
    url = _SEARXNG + '/search?' + urllib.parse.urlencode({'q': query, 'format': 'json'})
    try:
        with urllib.request.urlopen(url, timeout=15) as resp:
            data = json.loads(resp.read(_SEARCH_MAX_BYTES))
    except Exception as e:
        return json.dumps({'query': query, 'error': f'search-failed: {e}'})

    results = [
        {
            'title': r.get('title'),
            'url': r.get('url'),
            'snippet': (r.get('content') or '')[:_SNIPPET_CHARS],
        }
        for r in data.get('results', [])
        if r.get('url')
    ][:max_results]
    return json.dumps({'query': query, 'results': results})


def fetch_url(url: str, max_chars: int = 6000) -> str:
    """Fetch a web page and return its readable text as JSON (url, title, text, truncated).
    Only public http/https pages; PDFs and images are not supported."""
    max_chars = max(1, min(int(max_chars), _MAX_FETCH_CHARS))
    return json.dumps(_fetch.fetch(url, max_chars))
