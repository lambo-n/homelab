"""Run with: python3 -m unittest discover -s scripts/llm/tools -v

No sandbox needed: subprocess.run is replaced, so these check the wire format,
the limits and that code only ever goes through `sudo -n llm-sandbox`. The
sandbox itself is checked on the guest, see GPU-VM.md -> Tool calling.
"""
import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))
import pyrun  # noqa: E402


def reply(stdout: bytes, rc=0, stderr=b''):
    return mock.Mock(returncode=rc, stdout=stdout, stderr=stderr)


def wire(code, out=b'', err=b''):
    return b'%d\n%d\n' % (code, len(out)) + out + err


class PyrunTests(unittest.TestCase):
    def run_with(self, completed=None, **kw):
        m = mock.Mock(return_value=completed, **kw)
        with mock.patch('subprocess.run', m):
            return pyrun.run('print(1)'), m

    def test_success_splits_stdout_and_stderr(self):
        out, _ = self.run_with(reply(wire(3, b'hi\n', b'oops\n')))
        self.assertEqual((out['exit_code'], out['stdout'], out['stderr']), (3, 'hi\n', 'oops\n'))
        self.assertFalse(out['stdout_truncated'] or out['stderr_truncated'])

    def test_stdout_containing_digits_and_newlines_is_not_misparsed(self):
        out, _ = self.run_with(reply(wire(0, b'1\n2\n3\n', b'')))
        self.assertEqual(out['stdout'], '1\n2\n3\n')

    def test_code_goes_in_on_stdin_through_the_wrapper_only(self):
        _, m = self.run_with(reply(wire(0)))
        self.assertEqual(m.call_args.args[0], ['sudo', '-n', pyrun.SANDBOX, 'python-run'])
        self.assertEqual(m.call_args.kwargs['input'], b'print(1)')

    def test_stdout_truncates_head_and_stderr_truncates_tail(self):
        out, _ = self.run_with(reply(wire(1, b'a' * 7000, b'x' * 3000 + b'END')))
        self.assertEqual(len(out['stdout']), pyrun.STDOUT_CHARS)
        self.assertTrue(out['stdout_truncated'] and out['stderr_truncated'])
        self.assertTrue(out['stderr'].endswith('END'))

    def test_empty_reply_means_killed_by_limit(self):
        out, _ = self.run_with(reply(b''))
        self.assertIsNone(out['exit_code'])
        self.assertTrue(out['error'].startswith('killed-by-limit'))

    def test_garbage_reply_is_not_trusted(self):
        out, _ = self.run_with(reply(b'sudo: a password is required\n', rc=1, stderr=b'denied'))
        self.assertTrue(out['error'].startswith('killed-by-limit'))
        self.assertIn('denied', out['error'])

    def test_exit_120_explains_itself(self):
        out, _ = self.run_with(reply(wire(120)))
        self.assertIn('scratch', out['note'])

    def test_oversize_code_is_refused_without_running(self):
        with mock.patch('subprocess.run') as m:
            out = pyrun.run('x' * (pyrun.MAX_CODE_BYTES + 1))
        self.assertTrue(out['error'].startswith('code-too-large'))
        m.assert_not_called()

    def test_timeout_and_missing_sandbox_are_data(self):
        with mock.patch('subprocess.run', side_effect=subprocess.TimeoutExpired('x', 1)):
            self.assertEqual(pyrun.run('1')['error'], 'timeout')
        with mock.patch('subprocess.run', side_effect=FileNotFoundError('sudo')):
            self.assertTrue(pyrun.run('1')['error'].startswith('sandbox-unavailable'))

    def test_code_is_never_executed_in_process(self):
        with mock.patch('subprocess.run', return_value=reply(wire(0))):
            pyrun.run("import os; os.environ['PYRUN_RAN'] = '1'")
        self.assertNotIn('PYRUN_RAN', os.environ)


class AgentToolsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ns = {}
        with mock.patch.dict(os.environ, {'LLM_TOOLS_DIR': str(HERE)}):
            exec((HERE / 'agent_tools.py').read_text(), cls.ns)

    def public(self, ns):
        return {k for k, v in ns.items() if callable(v) and not k.startswith('_')}

    def test_agent_surface_is_the_web_tools_plus_run_python(self):
        self.assertEqual(self.public(self.ns),
                         {'web_search', 'fetch_url', 'ocr_url', 'run_python'})

    def test_run_python_is_not_reachable_from_the_default_tools(self):
        ns = {}
        with mock.patch.dict(os.environ, {'LLM_TOOLS_DIR': str(HERE)}):
            exec((HERE / 'tools.py').read_text(), ns)
        self.assertNotIn('run_python', self.public(ns))
        self.assertNotIn('pyrun', ns)

    def test_run_python_has_docstring_hints_and_returns_json(self):
        fn = self.ns['run_python']
        self.assertTrue(fn.__doc__ and fn.__annotations__)
        with mock.patch('subprocess.run', return_value=reply(wire(0, b'42\n'))):
            self.assertIn('"stdout": "42\\n"', fn('print(42)'))


if __name__ == '__main__':
    unittest.main()
