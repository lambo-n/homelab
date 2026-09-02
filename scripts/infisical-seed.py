#!/usr/bin/env python3
"""Seed Infisical with the cross-boundary secrets, from the plaintext originals.

Cross-boundary = the keys that must stay byte-identical between the k3s cluster
and the Cloudflare Worker's two environments. They are synced by hand today;
Infisical becomes system of record. See GITOPS.md "Secrets: hybrid" / "Phase 2b".

Two naming quirks this script normalises, both of which are why hand-syncing
was error-prone:

  1. The Worker calls it POSTGREST_JWT_SECRET; the cluster key is
     PGRST_JWT_SECRET. Same bytes, different names. Infisical stores the
     Worker's name (it is the app-facing contract); the operator maps it back
     for the cluster.
  2. worker-credentials.yaml prefixes keys PROD_/FEATURE_ to fake two
     environments inside one file. Infisical has real environments, so the
     prefixes disappear and become --env.

Never prints secret values. Values reach the CLI through a 0600 temp file
rather than argv, since argv is world-readable via /proc.

Usage:
    ./scripts/infisical-seed.py --project-id <id>            # show plan only
    ./scripts/infisical-seed.py --project-id <id> --apply    # push
"""
import argparse, os, pathlib, subprocess, sys, tempfile

try:
    import yaml
except ImportError:
    sys.exit("needs pyyaml: pip install pyyaml")

BACKEND = pathlib.Path.home() / "sunfire-backend"

# infisical_name -> (source file, key within that file), per environment
MAPPING = {
    "prod": {
        "POSTGREST_JWT_SECRET": ("postgrest/secret.yaml", "PGRST_JWT_SECRET"),
        "MINIO_ACCESS_KEY":     ("minio/worker-credentials.yaml", "PROD_MINIO_ACCESS_KEY"),
        "MINIO_SECRET_KEY":     ("minio/worker-credentials.yaml", "PROD_MINIO_SECRET_KEY"),
    },
    "feature": {
        "POSTGREST_JWT_SECRET": ("postgrest/secret.yaml", "PGRST_JWT_SECRET"),
        "MINIO_ACCESS_KEY":     ("minio/worker-credentials.yaml", "FEATURE_MINIO_ACCESS_KEY"),
        "MINIO_SECRET_KEY":     ("minio/worker-credentials.yaml", "FEATURE_MINIO_SECRET_KEY"),
    },
}


def load(rel):
    doc = yaml.safe_load((BACKEND / rel).read_text()) or {}
    return doc.get("stringData") or doc.get("data") or {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project-id", required=True)
    ap.add_argument("--apply", action="store_true", help="actually push (default: plan only)")
    args = ap.parse_args()

    cache, missing, plan = {}, [], []
    for env, keys in MAPPING.items():
        for name, (rel, src_key) in keys.items():
            cache.setdefault(rel, load(rel))
            if src_key not in cache[rel]:
                missing.append(f"{rel}:{src_key}")
                continue
            plan.append((env, name, rel, src_key, cache[rel][src_key]))

    if missing:
        sys.exit("missing source keys:\n  " + "\n  ".join(missing))

    print(f"{'ENV':<9} {'INFISICAL KEY':<24} SOURCE")
    for env, name, rel, src_key, _ in plan:
        print(f"{env:<9} {name:<24} {rel}:{src_key}")
    print(f"\n{len(plan)} secrets across {len(MAPPING)} environments.")

    if not args.apply:
        print("\nplan only — re-run with --apply to push.")
        return

    for env in MAPPING:
        rows = [(n, v) for e, n, _, _, v in plan if e == env]
        fd, tmp = tempfile.mkstemp(suffix=".env")
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w") as fh:
                for n, v in rows:
                    fh.write(f"{n}={v}\n")
            r = subprocess.run(
                ["infisical", "secrets", "set", "--file", tmp,
                 "--projectId", args.project_id, "--env", env, "--silent"],
                capture_output=True, text=True)
            if r.returncode != 0:
                sys.exit(f"[{env}] failed: {r.stderr.strip()[:300]}")
            print(f"[{env}] pushed {len(rows)} secrets")
        finally:
            with open(tmp, "r+b") as fh:      # overwrite before unlink
                n = fh.seek(0, 2); fh.seek(0); fh.write(b"\0" * n)
            os.unlink(tmp)

    print("\nNext: verify Wrangler's staged copies still byte-match, then remove\n"
          "the duplicated keys from the SOPS files (GITOPS.md Phase 2b).")


if __name__ == "__main__":
    main()
