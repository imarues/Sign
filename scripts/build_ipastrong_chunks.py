#!/usr/bin/env python3
"""Prepare independently downloadable 250-app IPA Strong catalogue batches.

The ONLY upstream source is the canonical URL supplied by the store owner.
Generated files are a temporary delivery mirror, not a second app source.
"""
import hashlib
import json
import os
import pathlib
import urllib.request

SOURCE = "https://raw.githubusercontent.com/sgad73055-code/ipastrong/main/ipastrong.json"
SIZE = 250

def main():
    out = pathlib.Path(os.environ["CATALOG_OUTPUT"])
    request = urllib.request.Request(
        SOURCE, headers={"User-Agent": "BatSign-catalog-mirror/1.0", "Accept": "application/json"}
    )
    with urllib.request.urlopen(request, timeout=90) as response:
        data = response.read(30 * 1024 * 1024 + 1)
    if len(data) > 30 * 1024 * 1024:
        raise ValueError("Upstream catalogue is unexpectedly large")
    source = json.loads(data)
    if not isinstance(source, dict) or not isinstance(source.get("apps"), list) or not source["apps"]:
        raise ValueError("Upstream has no valid apps array; keeping the previous mirror")
    apps = source["apps"]
    version = hashlib.sha256(data).hexdigest()[:20]
    parts = []
    for idx, start in enumerate(range(0, len(apps), SIZE)):
        record = {key: value for key, value in source.items() if key != "apps"}
        record["apps"] = apps[start:start + SIZE]
        # The first batch owns source-level featured/news data.
        if idx:
            record["featuredApps"] = []
            record["news"] = []
        relative = f"versions/{version}/part-{idx + 1:04d}.json"
        destination = out / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(
            json.dumps(record, ensure_ascii=False, separators=(",", ":")), encoding="utf-8"
        )
        parts.append(relative)
    manifest = {
        "schema": 1,
        "sourceURL": SOURCE,
        "contentHash": version,
        "count": len(apps),
        "batchSize": SIZE,
        "parts": parts,
    }
    out.mkdir(parents=True, exist_ok=True)
    (out / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, separators=(",", ":")), encoding="utf-8"
    )
    print(f"Prepared {len(apps)} original app records in {len(parts)} parts of at most {SIZE} each; hash {version}")

if __name__ == "__main__":
    main()
