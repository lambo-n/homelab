#!/usr/bin/env python3
"""Check version numbers stated in the docs against the files that pin them.

Renovate bumps the manifests, mise.toml and the HelmReleases on its own; the
prose in README.md and GITOPS.md is not bumped with them. Each CLAIM below
ties one sentence in a doc to the file that owns that version.

  (no args)   report every claim; exit 1 if any disagrees or is missing
  --ci        CI. Prints GitHub ::warning annotations for drift. Always exits
              0 -- a Renovate PR that bumps a pinned file must never be
              blocked by prose it doesn't touch. See doc-history-check.py's
              --base mode for the same pattern.

A claim whose doc pattern no longer matches is reported as MISSING, so a
rewritten sentence can't silently drop out of the check: update or remove the
CLAIM in the same change.

Versions that no file in the repo pins (chart appVersions such as Prometheus,
Grafana, the Flux controllers, Traefik from k3s) can't be checked offline.
The homelab-docs skill lists how to read those from the live cluster.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# (label, doc, doc regex, source file, source regex). Each regex has one group.
CLAIMS = [
    ("kube-prometheus-stack chart", "README.md",
     r"\*\*kube-prometheus-stack\*\* chart `([^`]+)`",
     "kubernetes/apps/observability/kube-prometheus-stack/app/ocirepository.yaml",
     r"^\s*tag:\s*\"?([^\"\s]+)"),
    ("kube-prometheus-stack chart", "GITOPS.md",
     r"^\| Chart \| \*\*([^*]+)\*\* \(appVersion",
     "kubernetes/apps/observability/kube-prometheus-stack/app/ocirepository.yaml",
     r"^\s*tag:\s*\"?([^\"\s]+)"),
    ("cert-manager chart", "README.md",
     r"\*\*cert-manager\*\* `([^`]+)`",
     "kubernetes/apps/cert-manager/cert-manager/app/ocirepository.yaml",
     r"^\s*tag:\s*\"?([^\"\s]+)"),
    ("Infisical operator chart", "README.md",
     r"\*\*Infisical\*\* `([^`]+)`",
     "kubernetes/apps/infisical/secrets-operator/app/helmrelease.yaml",
     r"^\s*version:\s*\"?([^\"\s]+)"),
    ("Infisical operator chart", "GITOPS.md",
     r"^\| Operator \| chart \*\*([^*]+)\*\*",
     "kubernetes/apps/infisical/secrets-operator/app/helmrelease.yaml",
     r"^\s*version:\s*\"?([^\"\s]+)"),
    ("cloudflared image", "README.md",
     r"\*\*cloudflared\*\* `([^`]+)`",
     "kubernetes/apps/sunfire/cloudflared/app/deployment.yaml",
     r"cloudflared:([^@\s]+)"),
    ("restic image", "README.md",
     r"restic `([^`]+)`",
     "kubernetes/apps/sunfire/offsite-backup/app/cronjob.yaml",
     r"restic/restic:([^@\s]+)"),
    ("PostgreSQL image", "README.md",
     r"PostgreSQL \*\*([0-9][0-9.]*)\*\*",
     "kubernetes/apps/sunfire/postgres-cnpg/app/cluster.yaml",
     r"postgresql:([^@\s]+)"),
    ("OpenTofu", "README.md",
     r"\*\*OpenTofu\*\* `([^`]+)`",
     "mise.toml", r"^opentofu\s*=\s*\"([^\"]+)\""),
    ("OpenTofu", "GITOPS.md",
     r"^\| Version \| \*\*([^*]+)\*\*, pinned in `mise.toml`",
     "mise.toml", r"^opentofu\s*=\s*\"([^\"]+)\""),
    ("flux CLI", "README.md",
     r"\*\*Flux\*\* `([^`]+)`",
     "mise.toml", r"^flux2\s*=\s*\"([^\"]+)\""),
]


def first(path: str, pattern: str):
    m = re.search(pattern, (ROOT / path).read_text(), re.MULTILINE)
    return m.group(1) if m else None


def first_with_line(path: str, pattern: str):
    text = (ROOT / path).read_text()
    m = re.search(pattern, text, re.MULTILINE)
    if not m:
        return None, None
    return m.group(1), text.count("\n", 0, m.start()) + 1


def norm(v: str) -> str:
    return v.lstrip("v")


def main() -> int:
    bad = 0
    width = max(len(f"{c[1]}: {c[0]}") for c in CLAIMS)
    for label, doc, doc_rx, src, src_rx in CLAIMS:
        said, pinned = first(doc, doc_rx), first(src, src_rx)
        where = f"{doc}: {label}".ljust(width)
        if said is None or pinned is None:
            which = doc if said is None else src
            print(f"MISSING  {where}  pattern no longer matches in {which}")
            bad = 1
        elif norm(said) != norm(pinned):
            print(f"DRIFT    {where}  docs {said}  ≠  {src} {pinned}")
            bad = 1
        else:
            print(f"ok       {where}  {pinned}")
    return bad


def ci() -> int:
    for label, doc, doc_rx, src, src_rx in CLAIMS:
        said, line = first_with_line(doc, doc_rx)
        pinned = first(src, src_rx)
        loc = f"file={doc}" + (f",line={line}" if line else "")
        if said is None or pinned is None:
            which = doc if said is None else src
            print(f"::warning {loc},title=Version drift::{label}: "
                  f"pattern no longer matches in {which}")
        elif norm(said) != norm(pinned):
            print(f"::warning {loc},title=Version drift::{label} says "
                  f"{said}, but {src} pins {pinned}")
    return 0


if __name__ == "__main__":
    if sys.argv[1:2] == ["--ci"]:
        sys.exit(ci())
    sys.exit(main())
