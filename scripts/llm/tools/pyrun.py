"""Run model-written Python in the llm-sandbox sandbox and report what happened.

The code is untrusted: it comes from a model that may have just read a hostile
page. It runs only under `sudo llm-sandbox python-run` (no network, no access
to the user's files or the llama API keys, 16 MiB scratch, 512 MiB RAM, one
CPU, 30 s). This module never executes it in-process.

Output: {exit_code, stdout, stderr, stdout_truncated, stderr_truncated} when the
program ran, or {exit_code: None, error} when it did not (or was killed).
"""
import os
import subprocess

SANDBOX = os.environ.get('LLM_SANDBOX', 'llm-sandbox')
MAX_CODE_BYTES = 32 * 1024
STDOUT_CHARS = 6000
STDERR_CHARS = 3000       # the tail of a traceback is the useful part
TIMEOUT = 45              # llm-sandbox kills the unit at 30 s; this is the backstop


def _error(msg: str) -> dict:
    return {'exit_code': None, 'error': msg}


def _text(raw: bytes) -> str:
    return raw.decode('utf-8', 'replace')


def run(code: str) -> dict:
    data = code.encode('utf-8')
    if len(data) > MAX_CODE_BYTES:
        return _error(f'code-too-large: over {MAX_CODE_BYTES // 1024} KiB')
    try:
        p = subprocess.run(['sudo', '-n', SANDBOX, 'python-run'], input=data,
                           capture_output=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return _error('timeout')
    except OSError as e:
        return _error(f'sandbox-unavailable: {e}')

    # Wire format: exit code, stdout byte count, stdout, then stderr. An empty
    # reply means the unit died before it could report (30 s or 512 MiB hit).
    head = p.stdout.split(b'\n', 2)
    if len(head) < 3 or not head[0].strip().isdigit() or not head[1].strip().isdigit():
        return _error('killed-by-limit: exceeded 30 s or 512 MiB, or the sandbox failed'
                      + (f': {_text(p.stderr).strip()[:200]}' if p.returncode else ''))
    code_, n, rest = int(head[0]), int(head[1]), head[2]
    out, err = _text(rest[:n]), _text(rest[n:])

    result = {'exit_code': code_,
              'stdout': out[:STDOUT_CHARS], 'stdout_truncated': len(out) > STDOUT_CHARS,
              'stderr': err[-STDERR_CHARS:], 'stderr_truncated': len(err) > STDERR_CHARS}
    if code_ == 120:
        result['note'] = 'output could not be written: scratch space (16 MiB) or file size limit hit'
    return result


if __name__ == '__main__':
    import json
    import sys
    print(json.dumps(run(sys.stdin.read()), indent=2))
