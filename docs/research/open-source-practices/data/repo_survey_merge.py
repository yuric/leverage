#!/usr/bin/env python3
"""Merge survey_cat.json (stage 2 + manual categories) with validate.json (stage 3) and manual review flags; write CSV+JSON.
Usage: repo_survey_merge.py survey_cat.json validate.json OUTDIR
Both inputs are raw captures that are not published, so this step cannot be rerun from the
published files. After review, the published CSV was corrected by hand in two ways (see
notes/repo_survey.md, "Corrections after review"): three wf_codeql cells set to False, and the
column of verbatim CONTRIBUTING excerpts removed."""
import json, csv, sys, os
r = json.load(open(sys.argv[1])); v = {x["full_name"]: x for x in json.load(open(sys.argv[2]))}
# Manual review of regex hits (contexts printed during validation, read by hand):
AI_POLICY_MANUAL_CONTRIB = {"ZhFahim/anchor", "daeuniverse/honk", "supabitapp/supacode", "stickerdaniel/linkedin-mcp-server", "Dispatcharr/Dispatcharr",
  "pyrefly-org/pyrefly", "zumerlab/snapdom", "telemt/telemt", "Kilo-Org/kilocode", "career-ops-hq/career-ops"}
CLA_FALSE_POSITIVE = {"TestSprite/testsprite-cli"}  # CONTRIBUTING says "No separate CLA is required"
for x in r:
    x.update(v[x["full_name"]])
    x["ai_policy_manual"] = x["full_name"] in AI_POLICY_MANUAL_CONTRIB or bool(x["ai_policy_file"])
    x["cla_dco_manual"] = bool(x["cla_dco_any"]) and x["full_name"] not in CLA_FALSE_POSITIVE
    x["ai_review_strict"] = bool(x["v_wf_ai_strict"]) or bool(x["ai_review_config_file"])
    x["agents_or_claude_md_root"] = bool(x["agents_md"] or x["claude_md"])
def fl(d): return {k: (";".join(a) if isinstance(a, list) else a) for k, a in d.items() if k != "errors"} | {"errors": ";".join(d.get("errors", []))}
rows = [fl(x) for x in r]; keys = []
for x in rows:
    for k in x:
        if k not in keys: keys.append(k)
first = ["full_name", "url", "created_at", "stars", "band", "window", "owner_type", "language", "license_spdx", "category"]
keys = first + [k for k in keys if k not in first]
out = sys.argv[3]
with open(os.path.join(out, "repo_survey_data.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=keys); w.writeheader(); w.writerows(rows)
json.dump(r, open(os.path.join(out, "repo_survey_data.json"), "w"), indent=1)
