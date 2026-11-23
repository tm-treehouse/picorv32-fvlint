# SPDX-License-Identifier: ISC
"""Markdown summary of fvlint results for a CI job summary.

    python fvlint/summary.py fvlint_out/default/results.json [...] >> "$GITHUB_STEP_SUMMARY"
"""

import json
import os
import sys
from collections import Counter

ORDER = ["FAIL", "ERROR", "VACUOUS", "UNKNOWN", "WARN", "INFO", "WAIVED", "PROVEN"]


def cell(text):
    return str(text or "").replace("|", "\\|").replace("\n", " ")


for path in sys.argv[1:]:
    if not os.path.exists(path):
        print(f"### fvlint: no results in `{path}` (see the job log)\n")
        continue
    with open(path) as f:
        data = json.load(f)
    meta, results = data["meta"], data["results"]
    counts = Counter(r["status"] for r in results)
    print(f"### fvlint: `{meta['top']}` ({path.split('/')[-2]})\n")
    print(", ".join(f"{counts[s]} {s.lower()}" for s in ORDER if counts[s]) +
          f" in {meta.get('elapsed_s', '?')} s\n")
    shown = [r for r in results if r["status"] != "PROVEN"]
    if shown:
        print("| Status | Check | Location | Detail |")
        print("|---|---|---|---|")
        for r in sorted(shown, key=lambda r: (ORDER.index(r["status"]), r["id"])):
            detail = r["waiver"] if r["status"] == "WAIVED" and r.get("waiver") else r.get("detail")
            print(f"| {r['status']} | `{cell(r['id'])}` | {cell(r['src'])} | {cell(detail)} |")
        print()
