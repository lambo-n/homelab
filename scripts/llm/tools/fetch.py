"""Fetch a URL and return its readable text, for an LLM tool.

The model chooses the URL, and a page it reads can try to steer that choice,
so this runs on VM 105 as an SSRF boundary as well as a fetcher:

  * Only http/https, and only to hosts whose every resolved address is
    globally routable (no loopback, RFC 1918, link-local, CGNAT, ...).
  * The connection goes to the address that was checked, not to a second DNS
    lookup, so a rebinding answer can't swap in a private one.
  * Redirects are followed by hand and every hop goes through the same check.
  * The body is read up to MAX_BYTES, never whole.

Output is always a dict: {url, title, text, truncated} on success, or
{url, title: None, text: None, error} on failure.
"""
import argparse
import http.client
import ipaddress
import json
import re
import socket
import ssl
import urllib.parse
from html.parser import HTMLParser

USER_AGENT = (
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
)
MAX_BYTES = 2 * 1024 * 1024
MAX_REDIRECTS = 5
TIMEOUT = 10
TEXT_TYPES = ('text/html', 'application/xhtml+xml', 'text/plain')
REDIRECT_CODES = (301, 302, 303, 307, 308)


class Blocked(Exception):
    pass


class TextExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self.text = []
        self.title = None
        self._in_title = False
        self._skip_depth = 0

    def handle_starttag(self, tag, attrs):
        if tag == 'title':
            self._in_title = True
        elif tag in ('script', 'style'):
            self._skip_depth += 1

    def handle_endtag(self, tag):
        if tag == 'title':
            self._in_title = False
        elif tag in ('script', 'style') and self._skip_depth > 0:
            self._skip_depth -= 1

    def handle_data(self, data):
        if self._in_title:
            if self.title is None:
                self.title = data.strip()
            else:
                self.title += data
        elif self._skip_depth == 0:
            self.text.append(data)

    def get_text(self):
        return ' '.join(' '.join(self.text).split())


def _is_public(ip: str) -> bool:
    addr = ipaddress.ip_address(ip)
    if addr.version == 6 and addr.ipv4_mapped:
        addr = addr.ipv4_mapped
    return addr.is_global and not addr.is_multicast


def _resolve(host: str, port: int) -> list[str]:
    infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    return list(dict.fromkeys(i[4][0] for i in infos))


def _pick_address(host: str, port: int) -> str:
    """Resolve host and return one address, or raise Blocked if any is not public."""
    ips = _resolve(host, port)
    if not ips or not all(_is_public(ip) for ip in ips):
        raise Blocked(host)
    return ips[0]


class _PinnedHTTP(http.client.HTTPConnection):
    def __init__(self, host, port, ip, timeout):
        super().__init__(host, port, timeout=timeout)
        self._ip = ip

    def connect(self):
        self.sock = socket.create_connection((self._ip, self.port), self.timeout)


class _PinnedHTTPS(http.client.HTTPSConnection):
    def __init__(self, host, port, ip, timeout):
        super().__init__(host, port, timeout=timeout, context=ssl.create_default_context())
        self._ip = ip

    def connect(self):
        sock = socket.create_connection((self._ip, self.port), self.timeout)
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


def _open(url: str, accept: str = 'text/html,text/plain;q=0.9,*/*;q=0.1'):
    """One GET, no redirect handling. Returns (connection, response)."""
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ('http', 'https') or not parts.hostname:
        raise ValueError('unsupported-scheme')
    port = parts.port or (443 if parts.scheme == 'https' else 80)
    ip = _pick_address(parts.hostname, port)
    cls = _PinnedHTTPS if parts.scheme == 'https' else _PinnedHTTP
    conn = cls(parts.hostname, port, ip, TIMEOUT)
    target = urllib.parse.urlunsplit(('', '', parts.path or '/', parts.query, ''))
    try:
        conn.request('GET', target, headers={
            'User-Agent': USER_AGENT,
            'Accept': accept,
            'Accept-Encoding': 'identity',
        })
        return conn, conn.getresponse()
    except BaseException:
        conn.close()
        raise


def _charset(content_type: str, head: bytes) -> str:
    m = re.search(r'charset=["\']?([\w.:-]+)', content_type)
    if not m:
        m = re.search(rb'<meta[^>]+charset=["\']?([\w.:-]+)', head[:2048], re.I)
        if m:
            return m.group(1).decode('ascii', 'ignore')
        return 'utf-8'
    return m.group(1)


def _decode(body: bytes, content_type: str) -> str:
    try:
        return body.decode(_charset(content_type, body), errors='replace')
    except LookupError:
        return body.decode('utf-8', errors='replace')


def _error(url: str, msg: str) -> dict:
    return {'url': url, 'title': None, 'text': None, 'error': msg}


class FetchError(Exception):
    """A failure to report to the model as the `error` string."""


def download(url: str, types: tuple, max_bytes: int, accept: str | None = None):
    """GET url through the SSRF checks. Returns (final_url, mime, content_type, body, truncated).

    Raises FetchError for every failure, including a content type not in `types`.
    """
    current = url
    try:
        for _ in range(MAX_REDIRECTS + 1):
            conn, resp = _open(current, accept) if accept else _open(current)
            try:
                if resp.status in REDIRECT_CODES:
                    location = resp.getheader('Location')
                    if not location:
                        raise FetchError(f'http-error: {resp.status} redirect without Location')
                    current = urllib.parse.urljoin(current, location)
                    continue

                if resp.status >= 400:
                    raise FetchError(f'http-error: {resp.status} {resp.reason}')

                content_type = resp.getheader('Content-Type', '').lower()
                mime = content_type.split(';')[0].strip()
                if mime not in types:
                    raise FetchError(f'unsupported-content-type: {mime or "unknown"}')

                body = resp.read(max_bytes + 1)
            finally:
                conn.close()
            break
        else:
            raise FetchError('too-many-redirects')
    except Blocked as e:
        raise FetchError(f'blocked-address: {e}')
    except ValueError as e:
        raise FetchError(str(e))
    except (OSError, http.client.HTTPException) as e:
        raise FetchError(f'network-error: {e}')
    return current, mime, content_type, body[:max_bytes], len(body) > max_bytes


def fetch(url: str, max_chars: int = 8000) -> dict:
    try:
        current, mime, content_type, body, truncated = download(url, TEXT_TYPES, MAX_BYTES)
    except FetchError as e:
        return _error(url, str(e))

    html_content = _decode(body, content_type)

    title = None
    if mime == 'text/plain':
        text = ' '.join(html_content.split())
    else:
        parser = TextExtractor()
        try:
            parser.feed(html_content)
        except Exception:
            pass
        text, title = parser.get_text(), parser.title

    if len(text) > max_chars:
        text = text[:max_chars]
        truncated = True

    return {'url': current, 'title': title, 'text': text, 'truncated': truncated}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Fetch URL content')
    parser.add_argument('url', help='URL to fetch')
    parser.add_argument('--max-chars', type=int, default=8000, help='Max characters to return')

    args = parser.parse_args()
    result = fetch(args.url, args.max_chars)
    print(json.dumps(result, indent=2))
