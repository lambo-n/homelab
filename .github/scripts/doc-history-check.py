#!/usr/bin/env python3
"""Flag history-style wording added to the current-state docs.

The markdown files at the repo root describe the homelab as it is now.
History (what was found, corrected, closed, verified on some date) belongs in
archive/. See AGENTS.md rule 8 and archive/README.md.

Only *added* lines are checked, so existing text never trips it. The patterns
are a heuristic: a hit is a prompt to look, not proof of a violation. A line
that quotes the patterns on purpose can end in <!-- doc-history:ignore -->.

  --hook        Claude Code PostToolUse hook. Reads the tool call from stdin;
                on a hit, prints to stderr and exits 2 so the agent sees it.
  --base REF    CI. Checks root *.md lines added since REF and prints GitHub
                ::warning annotations. Always exits 0.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

PATTERNS = [
    r"\b(closed|corrected|fixed|resolved|restricted|retired|replaced|superseded|found|verified)\s+(on\s+)?20\d\d-\d\d-\d\d",
    r"\*\((found|closed|corrected|fixed|resolved)\b[^)]*\)\*",
    r"\bsince 20\d\d-\d\d-\d\d",
    r"\b(an )?earlier (revision|version|draft)s?\b",
    r"\bused to\b",
    r"\bno longer\b",
    r"\bstopped being true\b",
    r"\bwas never true\b",
    r"\bpreviously\b",
    r"\bbefore that\b",
    r"\bhow it was found\b",
]
RX = re.compile("|".join(f"(?:{p})" for p in PATTERNS), re.IGNORECASE)

MESSAGE = (
    "Root docs describe the homelab's current state only (AGENTS.md rule 8). "
    "These added lines read like history. Keep the current fact at the root, "
    "and move the story (found / corrected / closed / verified-on dates, "
    "'earlier revisions said') to archive/ — see archive/README.md. "
    "Ignore this if the line really is current state."
)


def repo_root(where: Path = Path(".")) -> Path | None:
    out = subprocess.run(["git", "-C", str(where), "rev-parse", "--show-toplevel"],
                         capture_output=True, text=True)
    return Path(out.stdout.strip()) if out.returncode == 0 else None


def is_current_state_doc(root: Path, path: Path) -> bool:
    try:
        rel = path.resolve().relative_to(root)
    except ValueError:
        return False
    return len(rel.parts) == 1 and rel.suffix == ".md"


def added_lines(root: Path, rel: str, base: str):
    """(line number, text) for lines in rel added relative to base."""
    tracked = subprocess.run(["git", "cat-file", "-e", f"{base}:{rel}"],
                             cwd=root, capture_output=True).returncode == 0
    if not tracked:
        text = (root / rel).read_text(errors="replace").splitlines()
        return list(enumerate(text, 1))
    diff = subprocess.run(["git", "diff", "-U0", base, "--", rel],
                          cwd=root, capture_output=True, text=True).stdout
    out, n = [], 0
    for line in diff.splitlines():
        m = re.match(r"@@ -\S+ \+(\d+)", line)
        if m:
            n = int(m.group(1))
        elif line.startswith("+") and not line.startswith("+++"):
            out.append((n, line[1:]))
            n += 1
    return out


def hits(root: Path, rel: str, base: str):
    return [(n, t) for n, t in added_lines(root, rel, base)
            if RX.search(t) and "doc-history:ignore" not in t]


def hook() -> int:
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 0
    fp = (data.get("tool_input") or {}).get("file_path")
    if not fp:
        return 0
    path = Path(fp)
    if not path.exists():
        return 0
    root = repo_root(path.resolve().parent)
    if root is None or not (root / "archive").is_dir() \
            or not is_current_state_doc(root, path):
        return 0
    rel = str(path.resolve().relative_to(root))
    found = hits(root, rel, "HEAD")
    if not found:
        return 0
    print(MESSAGE, file=sys.stderr)
    for n, t in found:
        print(f"  {rel}:{n}: {t.strip()}", file=sys.stderr)
    return 2


def ci(base: str) -> int:
    root = repo_root()
    for path in sorted(root.glob("*.md")):
        for n, t in hits(root, path.name, base):
            print(f"::warning file={path.name},line={n},"
                  f"title=History in a current-state doc::{t.strip()}")
    return 0


if __name__ == "__main__":
    if sys.argv[1:2] == ["--hook"]:
        sys.exit(hook())
    if sys.argv[1:2] == ["--base"] and len(sys.argv) == 3:
        sys.exit(ci(sys.argv[2]))
    print(__doc__, file=sys.stderr)
    sys.exit(64)
