"""Tools for `qwen27-agent` on VM 105: everything in tools.py plus run_python.

    llm -m qwen27-agent --functions ~/.config/io.datasette.llm/tools/agent_tools.py \
        "What is the 40th Fibonacci number?"

Kept apart from tools.py on purpose: run_python executes model-written code, and
the small `fast` model (or any preset) that reads a fetched page must never be
one prompt injection away from it. Only the agent preset is pointed here.

Same rules as tools.py: `llm --functions` execs this in an empty namespace and
registers every public callable, so the re-exported tools are plain
assignments, everything else is underscore-prefixed, and nothing uses
`from x import y`. Install all of fetch.py, ocr.py, pyrun.py, tools.py and
this file together, see GPU-VM.md -> Tool calling.
"""
import importlib.util
import json
import os

_DIR = os.environ.get('LLM_TOOLS_DIR') or os.path.expanduser('~/.config/io.datasette.llm/tools')


def _load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(_DIR, name + '.py'))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_tools = _load('tools')
_pyrun = _load('pyrun')

web_search = _tools.web_search
fetch_url = _tools.fetch_url
ocr_url = _tools.ocr_url


def run_python(code: str) -> str:
    """Run a Python 3 program and return its exit_code, stdout and stderr as JSON.
    Standard library only, no network, no files kept between calls, 30 seconds and 512 MiB.
    Use print() to see results. Good for arithmetic, parsing and checking an answer."""
    return json.dumps(_pyrun.run(code))
