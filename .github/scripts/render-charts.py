#!/usr/bin/env python3
"""Render every HelmRelease in this repo with `helm template`.

`kubectl kustomize` proves a HelmRelease is well-formed YAML; it says nothing
about the chart it points at. A chart bump changes one string -- an
OCIRepository tag, or spec.chart.spec.version -- so a version that does not
exist, cannot be pulled, or fails to render against our values builds perfectly
cleanly and only fails at reconcile time, on the cluster.

This resolves each HelmRelease to its chart source the way Flux does, feeds it
the same spec.values, and renders it. Exit status is 1 if any chart fails.

Deliberately NOT a cluster check: no kubeconfig, no CRDs installed, no
Capabilities.APIVersions beyond what --kube-version implies. A chart that
renders here can still fail to apply. It is the pull-and-render half that is
being gated, which is the half a Renovate bump changes.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml


class _AppConfigLoader(yaml.SafeLoader):
    """SafeLoader that tolerates application-specific tags.

    Not every .yaml under kubernetes/ is a manifest: configMapGenerator sources
    such as Home Assistant's configuration.yaml carry tags like `!env_var` and
    `!secret` that only the application understands. Their values are
    irrelevant here -- only documents with a `kind` are used -- so any unknown
    tag loads as None instead of failing the whole run.
    """


_AppConfigLoader.add_multi_constructor("!", lambda loader, suffix, node: None)


def load_docs(root: Path):
    """Every YAML document under root, skipping SOPS files (ciphertext, and
    nothing here points at a chart)."""
    for path in sorted(root.rglob("*.yaml")):
        if ".sops." in path.name:
            continue
        try:
            with path.open() as fh:
                for doc in yaml.load_all(fh, Loader=_AppConfigLoader):
                    if isinstance(doc, dict) and doc.get("kind"):
                        yield path, doc
        except yaml.YAMLError as exc:
            print(f"::error file={path}::not parseable as YAML: {exc}")
            raise


def collect(root: Path):
    releases, oci, repos = [], {}, {}
    for path, doc in load_docs(root):
        kind = doc["kind"]
        meta = doc.get("metadata") or {}
        key = (meta.get("namespace"), meta.get("name"))
        if kind == "HelmRelease":
            releases.append((path, doc))
        elif kind == "OCIRepository":
            oci[key] = doc
        elif kind == "HelmRepository":
            repos[key] = doc
    return releases, oci, repos


def resolve(path: Path, hr: dict, oci: dict, repos: dict):
    """-> (chart_ref, version, extra_args) in `helm template` terms."""
    meta = hr.get("metadata") or {}
    ns = meta.get("namespace")
    spec = hr.get("spec") or {}

    chart_ref = spec.get("chartRef")
    if chart_ref:
        if chart_ref.get("kind") != "OCIRepository":
            raise ValueError(f"unsupported chartRef kind {chart_ref.get('kind')!r}")
        key = (chart_ref.get("namespace", ns), chart_ref["name"])
        source = oci.get(key)
        if source is None:
            raise ValueError(f"chartRef points at missing OCIRepository {key}")
        sspec = source["spec"]
        version = (sspec.get("ref") or {}).get("tag")
        if not version:
            raise ValueError(f"OCIRepository {key} pins no ref.tag")
        return sspec["url"], version, []

    chart = ((spec.get("chart") or {}).get("spec")) or {}
    if not chart:
        raise ValueError("HelmRelease has neither chartRef nor chart.spec")
    source_ref = chart.get("sourceRef") or {}
    key = (source_ref.get("namespace", ns), source_ref.get("name"))
    source = repos.get(key)
    if source is None:
        raise ValueError(f"sourceRef points at missing HelmRepository {key}")
    return chart["chart"], chart["version"], ["--repo", source["spec"]["url"]]


def render(hr: dict, chart: str, version: str, extra: list[str], kube_version: str):
    meta = hr["metadata"]
    values = (hr.get("spec") or {}).get("values") or {}
    with tempfile.NamedTemporaryFile("w", suffix=".yaml") as fh:
        yaml.safe_dump(values, fh)
        fh.flush()
        cmd = [
            "helm", "template", meta["name"], chart,
            "--version", version,
            "--namespace", meta.get("namespace", "default"),
            "--values", fh.name,
            "--include-crds",
            "--kube-version", kube_version,
            *extra,
        ]
        try:
            return subprocess.run(cmd, capture_output=True, text=True)
        except FileNotFoundError:
            print("::error::helm is not on PATH -- mise installs it from mise.toml")
            raise SystemExit(1)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("root", nargs="?", default="kubernetes", type=Path)
    # Matches the k3s server minor that mise pins kubectl to; a chart's
    # Capabilities.KubeVersion checks are only meaningful against the real one.
    ap.add_argument("--kube-version", default="1.35.0")
    args = ap.parse_args()

    releases, oci, repos = collect(args.root)
    if not releases:
        print(f"::error::no HelmRelease found under {args.root} -- wrong path?")
        return 1

    failures = 0
    for path, hr in releases:
        name = f"{(hr['metadata']).get('namespace')}/{hr['metadata']['name']}"
        try:
            chart, version, extra = resolve(path, hr, oci, repos)
        except ValueError as exc:
            print(f"::error file={path}::{name}: {exc}")
            failures += 1
            continue

        result = render(hr, chart, version, extra, args.kube_version)
        if result.returncode != 0:
            print(f"::error file={path}::{name}: helm template failed for "
                  f"{chart} {version}")
            for line in (result.stderr or result.stdout).splitlines():
                print(f"    {line}")
            failures += 1
            continue

        # The render succeeded -- that is the gate. Summarising it is best-effort:
        # BaseLoader because SafeLoader resolves YAML 1.1's reserved tags, and a
        # bare `=` in rendered chart output (kube-prometheus-stack emits one) is
        # tag:yaml.org,2002:value, which SafeLoader has no constructor for. If a
        # chart still defeats the parser, say so and keep going rather than
        # failing a build over a summary line.
        summary = f"{chart.rsplit('/', 1)[-1]} {version}"
        try:
            docs = [d for d in yaml.load_all(result.stdout, Loader=yaml.BaseLoader)
                    if isinstance(d, dict)]
        except yaml.YAMLError as exc:
            print(f"ok    {name:<36} {summary:<28} rendered "
                  f"({len(result.stdout):,} bytes, not summarisable: "
                  f"{type(exc).__name__})")
            continue
        kinds = sorted({d.get("kind", "?") for d in docs})
        crds = sum(1 for d in docs if d.get("kind") == "CustomResourceDefinition")
        print(f"ok    {name:<36} {summary:<28} {len(docs):>3} objects, {crds} CRDs")
        print(f"        kinds: {', '.join(kinds)}")

    print(f"\n{len(releases) - failures}/{len(releases)} charts rendered")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
