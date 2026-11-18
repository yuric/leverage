#!/usr/bin/env python3
"""Reads repo_survey_data.csv and prints every table used in repo_survey.md. Usage: repo_survey_analyze.py repo_survey_data.csv"""
import csv, sys, collections, statistics
rows = list(csv.DictReader(open(sys.argv[1])))
def b(r, k): return str(r.get(k, "")).strip().lower() in ("true", "1")
def n(r, k):
    try: return float(r[k])
    except Exception: return None
rows = [r for r in rows if b(r, "valid")]
N = len(rows)
P = {  # label -> predicate
 "README present": lambda r: b(r, "readme"),
 "License detected by GitHub (SPDX, not NOASSERTION)": lambda r: r["license_spdx"] not in ("NONE", "NOASSERTION", ""),
 "LICENSE file in tree": lambda r: b(r, "license_file_own"),
 "Topics set (>=1)": lambda r: (n(r, "n_topics") or 0) >= 1,
 "Homepage URL set": lambda r: b(r, "homepage"),
 "Dockerfile/compose at root": lambda r: b(r, "dockerfile_root"),
 "Issues enabled": lambda r: b(r, "has_issues"),
 "Tests directory or test files": lambda r: b(r, "tests_dir"),
 ".gitignore": lambda r: b(r, "gitignore"),
 "GitHub Releases >=1": lambda r: (n(r, "releases_count") or 0) >= 1,
 "Git tags >=1": lambda r: b(r, "has_tags"),
 "Semver-style tags (>=50% of up to 30 latest)": lambda r: (n(r, "tags_semver_frac") or 0) >= 0.5,
 "GitHub Actions workflows >=1": lambda r: (n(r, "n_workflows") or 0) >= 1,
 "Any CI config (Actions or other CI)": lambda r: (n(r, "n_workflows") or 0) >= 1 or bool(r["other_ci"]),
 "Workflow runs tests (strict test-command regex)": lambda r: b(r, "v_wf_test_strict"),
 "Workflow runs tests or build (loose)": lambda r: b(r, "wf_ci_test"),
 "Workflow runs lint/format/typecheck (regex heuristic)": lambda r: b(r, "wf_ci_lint"),
 "Workflow release/publish automation (heuristic)": lambda r: b(r, "wf_release"),
 "CodeQL": lambda r: b(r, "wf_codeql"),
 "OpenSSF Scorecard action": lambda r: b(r, "wf_scorecard"),
 "Stale bot (actions/stale)": lambda r: b(r, "wf_stale"),
 "Other SAST/secret/dependency scan in workflows": lambda r: b(r, "wf_dependency_review_or_sast"),
 "AI review/agent bot (strict workflow regex or config file)": lambda r: b(r, "ai_review_strict"),
 "  ...of which AI-review config file (coderabbit/greptile/gemini)": lambda r: bool(r["ai_review_config_file"]),
 "Workflows declare a permissions: block (read up to 8 workflows)": lambda r: b(r, "v_wf_permissions_block"),
 "Dependabot or Renovate": lambda r: b(r, "dep_bot_any"),
 "Dependabot": lambda r: b(r, "dependabot"),
 "Renovate": lambda r: b(r, "renovate"),
 "CONTRIBUTING (own repo)": lambda r: b(r, "contributing_own"),
 "CONTRIBUTING (own or inherited)": lambda r: b(r, "contributing_any"),
 "CODE_OF_CONDUCT (own repo)": lambda r: b(r, "code_of_conduct_own"),
 "CODE_OF_CONDUCT (own or inherited)": lambda r: b(r, "code_of_conduct_any"),
 "SECURITY policy (own repo)": lambda r: b(r, "security_own"),
 "SECURITY policy (own or inherited)": lambda r: b(r, "security_any"),
 "Private vulnerability reporting enabled": lambda r: b(r, "pvr_enabled"),
 "SECURITY policy or PVR": lambda r: b(r, "security_policy_or_pvr"),
 "Issue templates (own)": lambda r: b(r, "issue_tpl_any_own"),
 "Issue templates (own or inherited)": lambda r: b(r, "issue_tpl_any_own") or b(r, "issue_tpl_inherited"),
 "Issue templates: YAML forms": lambda r: (n(r, "issue_tpl_forms") or 0) >= 1,
 "Issue templates: legacy .md": lambda r: (n(r, "issue_tpl_md") or 0) >= 1,
 "Issue template config.yml": lambda r: b(r, "issue_tpl_config"),
 "Blank issues disabled": lambda r: b(r, "blank_issues_disabled"),
 "PR template (own or inherited)": lambda r: b(r, "pr_template_any"),
 "CODEOWNERS": lambda r: b(r, "codeowners_own"),
 "Agent-instruction file/dir (any kind, root-level)": lambda r: b(r, "has_agent_file"),
 "AGENTS.md (root)": lambda r: b(r, "agents_md"),
 "CLAUDE.md (root)": lambda r: b(r, "claude_md"),
 "AGENTS.md or CLAUDE.md at any depth": lambda r: b(r, "has_agents_md_or_claude_md_any_depth"),
 "CHANGELOG-type file": lambda r: b(r, "changelog_own"),
 "FUNDING.yml (own or inherited)": lambda r: b(r, "funding_any"),
 "README sponsor link": lambda r: b(r, "readme_sponsor_link"),
 "GOVERNANCE (own or inherited)": lambda r: b(r, "governance_any"),
 "MAINTAINERS": lambda r: b(r, "maintainers_own"),
 "ROADMAP": lambda r: b(r, "roadmap_own"),
 "SUPPORT (own or inherited)": lambda r: b(r, "support_any"),
 "ARCHITECTURE doc": lambda r: b(r, "architecture_own"),
 "AUTHORS": lambda r: b(r, "authors_own"),
 "ADR directory": lambda r: b(r, "adr_dir"),
 "RFC/spec/PRD/design-doc directory": lambda r: b(r, "rfc_spec_prd_dir"),
 "Deploy/self-host/install docs (heuristic)": lambda r: b(r, "deploy_docs"),
 "docs/ directory": lambda r: b(r, "docs_dir"),
 "CLA or DCO (manually verified)": lambda r: b(r, "cla_dco_manual"),
 "AI-contribution policy (manually verified: CONTRIBUTING section or AI policy file/workflow)": lambda r: b(r, "ai_policy_manual"),
 "AI-term hits in CONTRIBUTING (regex, incl. false positives)": lambda r: (n(r, "v_contrib_ai_hits") or 0) > 0,
 "AGENTS.md or CLAUDE.md at repo root": lambda r: b(r, "agents_or_claude_md_root"),
 "GitHub Discussions enabled": lambda r: b(r, "has_discussions"),
 "Wiki enabled": lambda r: b(r, "has_wiki"),
 "Discord/Slack/chat link in README": lambda r: b(r, "readme_chat_link"),
 "README install/quick-start/usage heading": lambda r: b(r, "readme_install_section"),
 "README badges": lambda r: b(r, "readme_badges"),
 "README demo image/GIF/video (strict: badges excluded)": lambda r: b(r, "v_readme_demo_strict"),
 "README any image/video incl. badges (loose)": lambda r: b(r, "readme_demo_media"),
 "README translations (README.xx.md)": lambda r: (n(r, "readme_translations") or 0) >= 1,
 ".editorconfig": lambda r: b(r, "editorconfig"),
 ".gitattributes": lambda r: b(r, "gitattributes"),
 "pre-commit/husky/lefthook": lambda r: b(r, "pre_commit"),
 "devcontainer": lambda r: b(r, "devcontainer"),
 "Makefile/justfile/Taskfile": lambda r: b(r, "task_runner"),
 "CITATION.cff": lambda r: b(r, "citation_own"),
}
def pct(c, d): return f"{c}/{d} ({100*c/d:.0f}%)" if d else "n/a"
def tier(p): return ">80%" if p > .8 else "40-80%" if p >= .4 else "10-40%" if p >= .1 else "<10%"
print(f"# N valid = {N}\n")
print("## Overall adoption ranked\n| Practice | Count | % | Tier |\n|---|---|---|---|")
res = sorted(((sum(1 for r in rows if f(r)), k) for k, f in P.items()), reverse=True)
for c, k in res: print(f"| {k} | {c}/{N} | {100*c/N:.0f}% | {tier(c/N)} |")
def seg(title, keyf, order=None):
    groups = collections.defaultdict(list)
    for r in rows: groups[keyf(r)].append(r)
    keys = order or sorted(groups)
    keys = [k for k in keys if k in groups]
    print(f"\n## By {title}\n| Practice | " + " | ".join(f"{k} (n={len(groups[k])})" for k in keys) + " |\n|---|" + "---|" * len(keys))
    for _, k in res:
        f = P[k]
        print(f"| {k} | " + " | ".join(f"{100*sum(1 for r in groups[g] if f(r))/len(groups[g]):.0f}%" for g in keys) + " |")
seg("owner type", lambda r: r["owner_type"])
seg("star band", lambda r: r["band"], ["1k-2k", "2k-5k", "5k-20k", "20k+"])
seg("age", lambda r: "<1yr (created >=2025-11-18)" if r["created_at"][:10] >= "2025-11-18" else "1-2yr", None)
seg("category", lambda r: r["category"])
print("\n## Distributions")
for k, name in (("license_spdx", "License"), ("language", "Language"), ("category", "Category"), ("owner_type", "Owner type"), ("pinning", "Action pinning (repos with external uses)"), ("band", "Band")):
    print(f"\n{name}: " + "; ".join(f"{a}={c}" for a, c in collections.Counter(r[k] or "None" for r in rows).most_common()))
def stats(k, label):
    v = [n(r, k) for r in rows if n(r, k) is not None]
    if v: print(f"{label}: n={len(v)} median={statistics.median(v):.0f} mean={statistics.mean(v):.1f} min={min(v):.0f} max={max(v):.0f}")
for k, l in (("health_pct", "Community health %"), ("n_workflows", "Workflows"), ("contributors", "Contributors"), ("releases_count", "Releases"), ("readme_lines", "README lines"), ("open_issues_and_prs", "Open issues+PRs"), ("n_topics", "Topics")): stats(k, l)
print("Health % = 100:", sum(1 for r in rows if n(r, "health_pct") == 100), "; >=80:", sum(1 for r in rows if (n(r, "health_pct") or 0) >= 80))
print("\nAgent file kinds (root):", collections.Counter(a for r in rows for a in r["agent_files_root"].split(";") if a).most_common())
print("Pinning among repos with workflows:", collections.Counter(r["pinning"] for r in rows if (n(r, "n_workflows") or 0) >= 1))
print("Zero-workflow repos:", [r["full_name"] for r in rows if (n(r, "n_workflows") or 0) == 0 and not r["other_ci"]])
for lbl, f in (("No license", lambda r: r["license_spdx"] in ("NONE", "NOASSERTION")), ("No CONTRIBUTING any", lambda r: not b(r, "contributing_any")), ("No SECURITY any and no PVR", lambda r: not b(r, "security_policy_or_pvr")), ("No releases", lambda r: not (n(r, "releases_count") or 0)), ("No CI", lambda r: not (n(r, "n_workflows") or 0) and not r["other_ci"])):
    print(f"\n{lbl}: {[ (r['full_name'], r['stars']) for r in rows if f(r)]}")
errs = [(r["full_name"], r["errors"]) for r in rows if r["errors"]]
print("\nRepos with API errors:", errs)
print("\nCross-tab: agent file vs contributors/owner:")
for lab, f in (("has agent file", lambda r: b(r, "has_agent_file")), ("no agent file", lambda r: not b(r, "has_agent_file"))):
    g = [r for r in rows if f(r)]
    print(lab, len(g), "owner Org:", sum(r["owner_type"] == "Organization" for r in g), "has CONTRIBUTING:", sum(b(r, "contributing_any") for r in g), "has CI:", sum((n(r, "n_workflows") or 0) >= 1 for r in g))

print("\n## Extras")
import datetime
def f(x): return str(x).lower() in ("true","1")
print("NONE license with a license-type file:", [(r["full_name"], r["license_file_path"]) for r in rows if r["license_spdx"]=="NONE" and f(r["license_file_own"])])
print("NOASSERTION repos:", [r["full_name"] for r in rows if r["license_spdx"]=="NOASSERTION"])
rec=[r for r in rows if r["latest_release_date"]]
cut=datetime.datetime(2026,11,18)-datetime.timedelta(days=90)
print("Repos with >=1 release:", len(rec), "latest release within 90d:", sum(1 for r in rec if datetime.datetime.strptime(r["latest_release_date"][:10],"%Y-%m-%d")>=cut))
print("Pushed within 30d:", sum(1 for r in rows if r["pushed_at"][:10]>="2026-10-19"))
print("Contributors <=3:", sum(1 for r in rows if (n(r,"contributors") or 0)<=3), " <=10:", sum(1 for r in rows if (n(r,"contributors") or 0)<=10), " >=50:", sum(1 for r in rows if (n(r,"contributors") or 0)>=50))
sec=[r for r in rows if f(r["security_any"])]
print("Of SECURITY-policy repos (any):", len(sec), "with PVR on:", sum(f(r["pvr_enabled"]) for r in sec), "; PVR on without policy:", sum(1 for r in rows if f(r["pvr_enabled"]) and not f(r["security_any"])))
ci=[r for r in rows if (n(r,"n_workflows") or 0)>=1]
print("Of repos with workflows:", len(ci), "strict tests:", sum(f(r["v_wf_test_strict"]) for r in ci), "release:", sum(f(r["wf_release"]) for r in ci), "dep bot:", sum(f(r["dep_bot_any"]) for r in ci), "pinned all_sha:", sum(r["pinning"]=="all_sha" for r in ci), "mixed:", sum(r["pinning"]=="mixed" for r in ci), "tags only:", sum(r["pinning"]=="none" for r in ci))
print("Workflow count median among repos with >=1:", statistics.median([n(r,"n_workflows") for r in ci]))
print("Release workflow loose; CodeQL repos:", [r["full_name"] for r in rows if f(r["wf_codeql"])])
print("Agent-file by owner: ", {o: sum(f(r["has_agent_file"]) for r in rows if r["owner_type"]==o) for o in ("Organization","User")})
print("Agent root AGENTS.md AND CLAUDE.md both:", sum(f(r["agents_md"]) and f(r["claude_md"]) for r in rows), " CLAUDE only:", sum(f(r["claude_md"]) and not f(r["agents_md"]) for r in rows), " AGENTS only:", sum(f(r["agents_md"]) and not f(r["claude_md"]) for r in rows))
print("Any agent artifacts in .claude/.agents/.cursor only (no AGENTS/CLAUDE md root):", sum(f(r["has_agent_file"]) and not f(r["agents_or_claude_md_root"]) for r in rows))
print("Repos w/ agent file (n=%d) CONTRIBUTING:%d; w/o (n=%d): %d" % (sum(f(r["has_agent_file"]) for r in rows), sum(f(r["has_agent_file"]) and f(r["contributing_any"]) for r in rows), sum(not f(r["has_agent_file"]) for r in rows), sum((not f(r["has_agent_file"])) and f(r["contributing_any"]) for r in rows)))
print("Community health bands:", {k: sum(lo<=(n(r,"health_pct") or 0)<=hi for r in rows) for k,(lo,hi) in {"<40":(0,39),"40-59":(40,59),"60-79":(60,79),"80-99":(80,99),"100":(100,100)}.items()})
print("Issue forms+config blank disabled both:", sum((n(r,"issue_tpl_forms") or 0)>=1 and f(r["blank_issues_disabled"]) for r in rows))
print("Has own README but demo missing:", [r["full_name"] for r in rows if f(r["readme"]) and not f(r["v_readme_demo_strict"])])
print("Repos w/ all five core (README, license-detected, CONTRIBUTING, COC, SECURITY):", sum(f(r["readme"]) and r["license_spdx"] not in("NONE","NOASSERTION") and f(r["contributing_any"]) and f(r["code_of_conduct_any"]) and f(r["security_any"]) for r in rows))
print("Repos with CONTRIBUTING and COC and SECURITY and issue templates and PR template (any):", sum(f(r["contributing_any"]) and f(r["code_of_conduct_any"]) and f(r["security_any"]) and (f(r["issue_tpl_any_own"])) and f(r["pr_template_any"]) for r in rows))
print("Org .github repo exists for owner:", sum(f(r["has_org_dotgithub_repo"]) for r in rows), " inherited any health file:", sum(any(f(r[k+"_inherited"]) for k in ("contributing","code_of_conduct","security","support","governance","funding","pr_template")) or f(r["issue_tpl_inherited"]) for r in rows))
print("Inherited counts: ", {k: sum(f(r[k+"_inherited"]) for r in rows) for k in ("contributing","code_of_conduct","security","support","governance","funding","pr_template")})
print("README lines >=500:", sum((n(r,"readme_lines") or 0)>=500 for r in rows), " <150:", sum((n(r,"readme_lines") or 0)<150 for r in rows))
print("Tests dir but no CI:", sum(f(r["tests_dir"]) and not (n(r,"n_workflows") or 0) for r in rows))
print("CI present but no tests dir:", sum((n(r,"n_workflows") or 0)>=1 and not f(r["tests_dir"]) for r in rows))
print("Docs-only-ish check: repos w/ AGENTS/CLAUDE + CONTRIBUTING + COC + SECURITY + CHANGELOG all:", sum(f(r["agents_or_claude_md_root"]) and f(r["contributing_any"]) and f(r["code_of_conduct_any"]) and f(r["security_any"]) and f(r["changelog_own"]) for r in rows))
print("CHANGELOG-type file among repos with releases:", sum(f(r["changelog_own"]) for r in rows if (n(r,"releases_count") or 0)>=1), "/", sum(1 for r in rows if (n(r,"releases_count") or 0)>=1))
print("Top 15 by stars sanity: ", [(r["full_name"], r["stars"]) for r in sorted(rows,key=lambda r:-int(r["stars"]))[:5]])
print("Windows:", collections.Counter(r["window"] for r in rows))
