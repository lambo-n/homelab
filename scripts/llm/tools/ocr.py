"""Read a PDF or image from a URL and return its text, for an LLM tool.

The counterpart to fetch.py for what fetch.py refuses (`unsupported-content-type`).
The download goes through fetch.download(), so it keeps the SSRF checks. The
file is hostile input for poppler and Tesseract, so every parser runs under
`sudo llm-sandbox` (no network, read-only filesystem, memory and time limits)
and data moves over stdin/stdout, never through a file path.

CPU only: it must never compete with the llama models for VRAM.

A PDF with a text layer is read with pdftotext; only a scan (little or no
text) is rasterised and OCR'd one page at a time, up to `max_pages`.

Output: {url, text, truncated, pages, method} on success, or
{url, text: None, error} on failure.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import fetch  # noqa: E402

SANDBOX = os.environ.get('LLM_SANDBOX', 'llm-sandbox')
PDF_TYPES = ('application/pdf',)
IMAGE_TYPES = ('image/png', 'image/jpeg', 'image/tiff', 'image/bmp', 'image/webp', 'image/gif')
MAX_BYTES = 10 * 1024 * 1024
MAX_PAGES = 10
DPI = 150
MIN_TEXT_PER_PAGE = 40   # below this a PDF page is treated as a scan
STEP_TIMEOUT = 90        # llm-sandbox kills a step at 60 s; this is the backstop
ACCEPT = 'application/pdf,image/*;q=0.9,*/*;q=0.1'


class OcrError(Exception):
    pass


def _run(tool: str, args: list, data: bytes) -> bytes:
    cmd = ['sudo', '-n', SANDBOX, tool, *args]
    try:
        p = subprocess.run(cmd, input=data, capture_output=True, timeout=STEP_TIMEOUT)
    except subprocess.TimeoutExpired:
        raise OcrError(f'timeout: {tool}')
    except OSError as e:
        raise OcrError(f'sandbox-unavailable: {e}')
    if p.returncode != 0:
        raise OcrError(f'{tool}-failed: {p.stderr.decode("utf-8", "replace").strip()[:200]}')
    return p.stdout


def _tesseract(image: bytes) -> str:
    return _run('tesseract', ['stdin', 'stdout', '-l', 'eng'], image).decode('utf-8', 'replace')


def _squash(text: str) -> str:
    return ' '.join(text.split())


def _pdf(body: bytes, max_pages: int):
    info = _run('pdfinfo', ['-'], body).decode('utf-8', 'replace')
    m = re.search(r'^Pages:\s+(\d+)', info, re.M)
    if not m:
        raise OcrError('unreadable-pdf')
    total = int(m.group(1))
    last = min(total, max_pages)

    text = _squash(_run('pdftotext', ['-l', str(last), '-', '-'], body).decode('utf-8', 'replace'))
    if len(text) >= MIN_TEXT_PER_PAGE * last:
        return text, 'text-layer', total, total > last

    parts = []
    for page in range(1, last + 1):
        parts.append(_run('pdf-ocr-page', [str(page), str(DPI)], body).decode('utf-8', 'replace'))
    return _squash(' '.join(parts)), 'ocr', total, total > last


def ocr(url: str, max_chars: int = 8000, max_pages: int = 5) -> dict:
    max_pages = max(1, min(max_pages, MAX_PAGES))
    try:
        final, mime, _, body, cut = fetch.download(
            url, PDF_TYPES + IMAGE_TYPES, MAX_BYTES, accept=ACCEPT)
        if cut:
            raise OcrError(f'too-large: over {MAX_BYTES // (1024 * 1024)} MiB')
        if mime in PDF_TYPES:
            text, method, pages, truncated = _pdf(body, max_pages)
        else:
            text, method, pages, truncated = _squash(_tesseract(body)), 'ocr', 1, False
    except (fetch.FetchError, OcrError) as e:
        return {'url': url, 'text': None, 'error': str(e)}

    if len(text) > max_chars:
        text, truncated = text[:max_chars], True
    return {'url': final, 'text': text, 'truncated': truncated, 'pages': pages, 'method': method}


if __name__ == '__main__':
    import argparse
    import json
    ap = argparse.ArgumentParser(description='OCR a PDF/image URL')
    ap.add_argument('url')
    ap.add_argument('--max-chars', type=int, default=8000)
    ap.add_argument('--max-pages', type=int, default=5)
    a = ap.parse_args()
    print(json.dumps(ocr(a.url, a.max_chars, a.max_pages), indent=2))
