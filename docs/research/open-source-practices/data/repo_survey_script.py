#!/usr/bin/env python3
"""Survey of repository practices in young (created >= 2024-11-18), >1000-star GitHub repos.
Read-only: GET requests only via authenticated `gh api`.
Usage:
  repo_survey_script.py candidates OUT.json   # stage 1: build stratified candidate pool via search API
  repo_survey_script.py survey SAMPLE.json OUTDIR  # stage 2: measure each sampled repo
  repo_survey_script.py validate SURVEY.json OUT.json  # stage 3: stricter second pass
Between stages 1 and 2, 10 candidates per cell were drawn at random (seed 7), read by hand,
excluded if not software, and 25 per star band were taken round-robin across windows. That
selection step has no published code. SAMPLE.json is a list of
{"item": <search API repository item>, "band": "1k-2k"|..., "win": "W1"|...}.
Stages 1-3 call the live GitHub API, so rerunning them measures today's repositories, not the
2026-11-18 snapshot. Only repo_survey_analyze.py runs from the published CSV alone."""
import subprocess, json, re, sys, time, math, random, datetime, csv, os, urllib.parse
from concurrent.futures import ThreadPoolExecutor

MIN_CREATED = "2024-11-18"

# ---------- gh helpers ----------
def gh(path, params=None, raw=False, headers=False, method="GET"):
    """returns (status, hdrs, body). body parsed JSON unless raw."""
    cmd = ["gh", "api", "-X", "GET", "-i"]
    if raw: cmd += ["-H", "Accept: application/vnd.github.raw"]
    cmd.append(path)
    for k, v in (params or {}).items(): cmd += ["-f", f"{k}={v}"]
    for attempt in range(5):
        p = subprocess.run(cmd, capture_output=True, text=True)
        out = p.stdout
        m = re.match(r"HTTP/[\d.]+ (\d+)", out)
        status = int(m.group(1)) if m else 0
        head, _, body = out.partition("\r\n\r\n") if "\r\n\r\n" in out else out.partition("\n\n")
        hdrs = {}
        for line in head.splitlines()[1:]:
            if ":" in line:
                k, v = line.split(":", 1); hdrs[k.strip().lower()] = v.strip()
        if status in (403, 429) and hdrs.get("x-ratelimit-remaining") == "0":
            time.sleep(max(5, int(hdrs.get("x-ratelimit-reset", "0")) - int(time.time()) + 3)); continue
        if status in (403, 429) and ("rate limit" in body.lower() or "retry-after" in hdrs or "abuse" in body.lower()):
            time.sleep(20 * (attempt + 1)); continue
        if status == 0 and attempt < 2:
            time.sleep(3); continue
        if raw and status == 200: return status, hdrs, body
        try: return status, hdrs, json.loads(body) if body.strip() else None
        except Exception: return status, hdrs, body
    return status, hdrs, body

def last_page(hdrs):
    m = re.search(r'[?&]page=(\d+)>; rel="last"', hdrs.get("link", ""))
    return int(m.group(1)) if m else None

# ---------- stage 1 ----------
BANDS = [("1001..2000", "1k-2k"), ("2001..5000", "2k-5k"), ("5001..20000", "5k-20k"), (">20000", "20k+")]
WINS = [("2024-11-18..2025-05-17", "W1"), ("2025-05-18..2025-11-17", "W2"),
        ("2025-11-18..2026-05-17", "W3"), ("2026-05-18..2026-11-18", "W4")]
def candidates(outfile):
    random.seed(20261118)
    items, queries = [], []
    run = datetime.datetime.utcnow().isoformat() + "Z"
    for b, bn in BANDS:
        for w, wn in WINS:
            q = f"created:{w} stars:{b} fork:false archived:false"
            _, _, r = gh("search/repositories", {"q": q, "per_page": 1}); tot = r["total_count"]
            pg = random.randint(1, max(1, min(10, math.ceil(tot / 100))))
            _, _, r = gh("search/repositories", {"q": q, "sort": "stars", "per_page": 100, "page": pg})
            queries.append({"q": q, "sort": "stars", "per_page": 100, "page": pg, "total_count": tot, "band": bn, "window": wn})
            for it in r["items"]: it["_band"], it["_win"] = bn, wn; items.append(it)
            time.sleep(4)
    json.dump({"run_utc": run, "queries": queries, "items": items}, open(outfile, "w"))

# ---------- stage 2 ----------
def has_path(paths, regex, dirs=("", ".github/", "docs/", "doc/")):
    """regex matched against basename (case-insens) for files directly in given dirs."""
    rx = re.compile(regex, re.I)
    hits = []
    for p in paths:
        d, _, base = p.rpartition("/")
        d = d + "/" if d else ""
        if d in dirs and rx.fullmatch(base): hits.append(p)
    return hits

def any_depth(paths, regex):
    rx = re.compile(regex, re.I)
    return [p for p in paths if rx.fullmatch(p.rsplit("/", 1)[-1])]

def prefix(paths, regex):
    rx = re.compile(regex, re.I)
    return [p for p in paths if rx.match(p)]

def get_raw(full, path, limit=250000):
    st, _, body = gh(f"repos/{full}/contents/{urllib.parse.quote(path)}", raw=True)
    return body[:limit] if st == 200 and isinstance(body, str) else None

_org_cache = {}
def org_dotgithub(owner):
    if owner in _org_cache: return _org_cache[owner]
    st, _, r = gh(f"repos/{owner}/.github")
    res = None
    if st == 200 and isinstance(r, dict):
        st2, _, t = gh(f"repos/{owner}/.github/git/trees/{r['default_branch']}", {"recursive": 1})
        if st2 == 200: res = [x["path"] for x in t.get("tree", []) if x["type"] == "blob"]
    _org_cache[owner] = res
    return res

FILES = {  # name: (regex for basename, dirs)
 "contributing": r"contributing(\.(md|rst|txt|markdown))?",
 "code_of_conduct": r"code[_-]of[_-]conduct(\.(md|rst|txt|markdown))?",
 "security": r"security(\.(md|rst|txt|markdown))?",
 "support": r"support(\.(md|rst|txt|markdown))?",
 "governance": r"governance(\.(md|rst|txt|markdown))?",
 "maintainers": r"maintainers(\.(md|rst|txt|markdown))?",
 "roadmap": r"roadmap(\.(md|rst|txt|markdown))?",
 "architecture": r"architecture(\.(md|rst|txt|markdown))?",
 "authors": r"authors(\.(md|rst|txt|markdown))?",
 "codeowners": r"codeowners",
 "pr_template": r"pull_request_template(\.(md|txt))?",
 "funding": r"funding\.ya?ml",
 "changelog": r"(changelog|changes|history|news|release[s_-]?notes?)(\.(md|rst|txt|markdown))?",
 "license_file": r"(licen[sc]e|copying|unlicense)([-_.].*)?",
 "citation": r"citation\.cff",
 "install_doc": r"install(ation)?(\.(md|rst|txt))?",
 "deploy_doc": r"(deploy(ment)?|self[-_]?host(ing|ed)?)(\.(md|rst|txt))?",
}
INHERITABLE = ["contributing", "code_of_conduct", "security", "support", "governance", "funding", "pr_template"]

AGENT_PATTERNS = {
 "AGENTS.md": r"agents\.md", "CLAUDE.md": r"claude\.md", "GEMINI.md": r"gemini\.md", "QWEN.md": r"qwen\.md",
 ".cursorrules": r"\.cursorrules", ".windsurfrules": r"\.windsurfrules", ".clinerules": r"\.clinerules",
 "CONVENTIONS.md": r"conventions\.md",
}
AGENT_PREFIXES = {
 ".cursor/rules": r"\.cursor/(rules|commands)", "copilot-instructions": r"\.github/(copilot-instructions\.md|instructions/|prompts/|chatmodes/)",
 ".claude/": r"\.claude/", ".gemini/": r"\.gemini/", ".roo/": r"\.(roo|roomodes)", ".kiro/": r"\.kiro/", ".junie/": r"\.junie/",
 ".windsurf/": r"\.windsurf/", ".clinerules/": r"\.clinerules/", ".aider": r"\.aider", ".continue/": r"\.continue/", ".agents/": r"\.agents/",
 ".codex/": r"\.codex/", ".opencode/": r"\.opencode/", ".specify/": r"\.specify/", "openspec/": r"openspec/",
}

WF_RX = {
 "ci_test": r"(pytest|npm (run )?test|pnpm( run)? test|yarn test|bun test|cargo (test|nextest)|go test|vitest|jest|ctest|make test|gradlew? (test|build|check)|mvn |dotnet test|rspec|phpunit|unittest|tox|nox|swift test|flutter test|playwright|cypress|deno test|npm run build|pnpm( run)? build|cargo build|go build|uv run|hatch run|just test|turbo run)",
 "ci_lint": r"(lint|eslint|ruff|flake8|mypy|pyright|tsc\b|clippy|rustfmt|cargo fmt|prettier|biome|golangci|black|isort|pre-commit|typecheck|type-check|shellcheck|oxlint)",
 "release": r"(release|publish|goreleaser|semantic-release|release-please|changesets|pypi-publish|npm publish|gh-release|twine|cargo publish|docker/build-push-action|vsce publish)",
 # Corrected after review: the survey as run used r"(github/codeql-action|codeql)", which also
 # matched REMOVE_CODEQL options, codeql-action/upload-sarif for other scanners, a CodeQL triage
 # workflow, and workflow file names. Only an init or analyze step is a CodeQL analysis.
 "codeql": r"github/codeql-action/(init|analyze)@",
 "scorecard": r"ossf/scorecard-action",
 "stale": r"actions/stale",
 "cla_dco": r"(cla-assistant|contributor-assistant|\bdco\b|cla\.ya?ml|check-cla|signed-off-by|\bcla\b)",
 "ai_review": r"(claude-code-action|anthropics/claude|coderabbit|copilot|codex|gemini-cli|gemini-code-assist|google-github-actions/run-gemini|openai|ai-review|greptile|qodo|pr-agent|sourcery|cursor-agent|opencode|gpt-|llm-review|ai-triage|ai-pr)",
 "dependency_review_or_sast": r"(dependency-review-action|semgrep|trivy|snyk|sonarcloud|sonarqube|bandit|gitleaks|trufflehog|osv-scanner|zizmor)",
}
AI_POLICY_RX = r"(AI[- ]generated|AI[- ]assisted|generated by (an )?(AI|LLM)|\bLLMs?\b|Copilot|ChatGPT|generative AI|\bAI tools?\b|AI agents?|Claude|vibe[- ]cod|AI-written|AI contributions?|AI policy|artificial intelligence)"
CLA_RX = r"(\bCLA\b|Contributor License Agreement|\bDCO\b|Developer Certificate of Origin|Signed-off-by|--signoff|git commit -s)"

def survey_repo(item, band, win):
    full = item["full_name"]; o, r = full.split("/")
    st, _, repo = gh(f"repos/{full}")
    d = {"full_name": full, "url": f"https://github.com/{full}", "band": band, "window": win, "errors": []}
    if st != 200: d["errors"].append(f"repo {st}"); return d
    d.update({
        "created_at": repo["created_at"], "stars": repo["stargazers_count"], "forks": repo["forks_count"],
        "owner_type": repo["owner"]["type"], "language": repo.get("language"),
        "license_spdx": (repo.get("license") or {}).get("spdx_id") or "NONE", "description": repo.get("description"),
        "default_branch": repo["default_branch"], "pushed_at": repo["pushed_at"], "open_issues_and_prs": repo["open_issues_count"],
        "has_discussions": repo.get("has_discussions"), "has_wiki": repo.get("has_wiki"), "has_issues": repo.get("has_issues"),
        "homepage": bool(repo.get("homepage")), "homepage_url": repo.get("homepage"), "topics": repo.get("topics", []), "n_topics": len(repo.get("topics", [])),
        "fork": repo["fork"], "archived": repo["archived"],
    })
    d["valid"] = (repo["created_at"][:10] >= MIN_CREATED and repo["stargazers_count"] > 1000 and not repo["fork"] and not repo["archived"])
    if not d["valid"]: return d
    # tree
    st, _, t = gh(f"repos/{full}/git/trees/{repo['default_branch']}", {"recursive": 1})
    if st != 200: d["errors"].append(f"tree {st}"); paths = []
    else: paths = [x["path"] for x in t.get("tree", []) if x["type"] == "blob"]; d["tree_truncated"] = t.get("truncated", False)
    d["n_files"] = len(paths)
    P = paths
    inh = org_dotgithub(o)
    # file presence
    for name, rx in FILES.items():
        dirs = ("", ".github/", "docs/", "doc/") if name != "funding" else (".github/",)
        if name in ("authors", "maintainers", "roadmap", "changelog", "architecture", "install_doc", "deploy_doc", "license_file", "citation"): dirs = ("", ".github/", "docs/", "doc/")
        hits = has_path(P, rx, dirs)
        if name == "pr_template" and not hits:
            hits = [p for p in P if re.match(r"(\.github/|docs/)?pull_request_template/", p, re.I)]
        d[name + "_own"] = bool(hits); d[name + "_path"] = hits[0] if hits else ""
        if name in INHERITABLE:
            ih = bool(inh and has_path(inh, rx, ("", ".github/", "docs/")) ) if not hits else False
            d[name + "_inherited"] = ih
            d[name + "_any"] = bool(hits) or ih
    d["has_org_dotgithub_repo"] = inh is not None
    # architecture alt
    d["architecture_own"] = d["architecture_own"] or bool(prefix(P, r"docs?/architecture")) 
    d["adr_dir"] = bool(prefix(P, r"(docs?/)?(adr|adrs|decisions|architecture[-_]decision[-_]records?)/|docs?/(architecture/)?(adr|decisions)/|docs?/.*/adr/"))
    d["rfc_spec_prd_dir"] = bool(prefix(P, r"(docs?/)?(rfcs?|specs?|prds?|proposals?|design[-_]docs?|openspec|\.specify)/|docs?/(design|specs?|prd|rfcs?)/"))
    d["prd_named"] = bool(prefix(P, r"(.*/)?prd[^/]*") ) and any(re.search(r"(^|/)prd", p, re.I) for p in P)
    d["deploy_docs"] = d["deploy_doc_own"] or bool(prefix(P, r"(docs?/)?[^/]*(deploy|self[-_]?host|selfhost|installation)[^/]*[/.]"))
    d["docs_dir"] = bool(prefix(P, r"docs?/")) 
    d["tests_dir"] = bool([p for p in P if re.search(r"(^|/)(tests?|__tests__|spec)/|\.(test|spec)\.[jt]sx?$|_test\.(go|py)$|test_.*\.py$", p)])
    # issue templates
    it = [p for p in P if re.match(r"\.github/ISSUE_TEMPLATE/", p, re.I)]
    legacy = [p for p in P if re.fullmatch(r"(\.github/|docs/)?issue_template\.(md|yml|yaml)", p, re.I)]
    forms = [p for p in it if re.search(r"\.ya?ml$", p) and not re.search(r"config\.ya?ml$", p, re.I)]
    mds = [p for p in it if p.lower().endswith(".md")]
    d["issue_tpl_forms"] = len(forms); d["issue_tpl_md"] = len(mds) + len(legacy)
    d["issue_tpl_any_own"] = bool(forms or mds or legacy)
    cfg = [p for p in it if re.search(r"config\.ya?ml$", p, re.I)]
    d["issue_tpl_config"] = bool(cfg); d["blank_issues_disabled"] = None
    if cfg:
        c = get_raw(full, cfg[0])
        if c is not None: d["blank_issues_disabled"] = bool(re.search(r"blank_issues_enabled:\s*false", c))
    ih = bool(inh and any(re.match(r"(\.github/)?ISSUE_TEMPLATE/", p, re.I) for p in inh))
    d["issue_tpl_inherited"] = (not d["issue_tpl_any_own"]) and ih
    # agent files
    agents = []
    for nm, rx in AGENT_PATTERNS.items():
        if has_path(P, rx, ("",)): agents.append(nm)
    for nm, rx in AGENT_PREFIXES.items():
        if prefix(P, rx): agents.append(nm)
    d["agent_files_root"] = ";".join(agents); d["has_agent_file"] = bool(agents)
    d["has_agents_md_or_claude_md_any_depth"] = bool(any_depth(P, r"(agents|claude)\.md"))
    d["agent_files_nested"] = ";".join(sorted({n for n in ("AGENTS.md", "CLAUDE.md") if any_depth(P, re.escape(n)) and n not in agents}))
    d["agents_md"] = "AGENTS.md" in agents; d["claude_md"] = "CLAUDE.md" in agents
    # dev config
    d["dependabot"] = bool(has_path(P, r"dependabot\.ya?ml", (".github/",)))
    d["renovate"] = bool(has_path(P, r"(\.?renovaterc(\.json5?)?|renovate\.json5?)", ("", ".github/", ".gitlab/")))
    d["dep_bot_any"] = d["dependabot"] or d["renovate"]
    d["editorconfig"] = bool(has_path(P, r"\.editorconfig", ("",)))
    d["gitattributes"] = bool(has_path(P, r"\.gitattributes", ("",)))
    d["pre_commit"] = bool(has_path(P, r"(\.pre-commit-config\.ya?ml|lefthook\.ya?ml|\.lefthook\.ya?ml)", ("",)) or prefix(P, r"\.husky/"))
    d["devcontainer"] = bool(prefix(P, r"\.devcontainer(/|\.json)"))
    d["dockerfile_root"] = bool(has_path(P, r"(dockerfile(\..*)?|docker-compose\.ya?ml|compose\.ya?ml)", ("",)))
    d["dockerfile_any"] = bool(any_depth(P, r"dockerfile(\..*)?"))
    d["task_runner"] = bool(has_path(P, r"(makefile|justfile|taskfile\.ya?ml|taskfile\.yml)", ("",)))
    d["gitignore"] = bool(has_path(P, r".gitignore", ("",)))
    d["other_ci"] = ";".join(n for n, rx in {"circleci": r"\.circleci/", "travis": r"\.travis\.yml", "gitlab": r"\.gitlab-ci\.yml", "azure": r"azure-pipelines\.yml", "jenkins": r"Jenkinsfile", "buildkite": r"\.buildkite/"}.items() if prefix(P, rx))
    d["ai_review_config_file"] = ";".join(n for n, rx in {"coderabbit": r"\.coderabbit\.ya?ml", "greptile": r"\.?greptile", "copilot-review": r"\.github/copilot-review", "gemini-code-assist": r"\.gemini/(config|styleguide)", "sourcery": r"\.sourcery\.ya?ml", "qodo": r"\.pr_agent\.toml", "cubic/graphite/other": r"(cubic|graphite)\.ya?ml"}.items() if prefix(P, rx))
    # readme
    rd = has_path(P, r"readme(\.[a-z-]+)?\.(md|rst|txt|markdown)|readme", ("",))
    rd = sorted(rd, key=lambda p: (0 if p.lower() == "readme.md" else 1, len(p)))
    d["readme"] = bool(rd); d["readme_path"] = rd[0] if rd else ""
    d["readme_translations"] = len(has_path(P, r"readme[._-][a-z]{2}([-_][a-z]{2,4})?\.md", ("", "docs/")))
    rtxt = get_raw(full, rd[0]) if rd else None
    if rtxt is not None:
        d["readme_lines"] = rtxt.count("\n") + 1
        d["readme_install_section"] = bool(re.search(r"^#{1,4}\s*.*(install|quick\s*-?start|getting\s+started|get started|usage|setup|how to run|run locally)", rtxt, re.I | re.M))
        d["readme_badges"] = bool(re.search(r"(shields\.io|img\.shields|badge\.svg|badges?\.|/badge/|actions/workflows/.*badge|codecov\.io|\.svg\)\]\()", rtxt, re.I))
        d["readme_demo_media"] = bool(re.search(r"(!\[[^\]]*\]\([^)]+\.(gif|png|jpe?g|webp|mp4|webm|svg)|<img\s|<video|youtu\.be|youtube\.com|user-attachments/(assets|files)|asciinema|\.mp4|\.webm|\.gif)", rtxt, re.I))
        d["readme_chat_link"] = bool(re.search(r"(discord\.(gg|com)|slack\.com|join\.slack|t\.me/|telegram|matrix\.to|gitter\.im|wechat|weixin|zulip)", rtxt, re.I))
        d["readme_discord"] = bool(re.search(r"discord\.(gg|com)", rtxt, re.I))
        d["readme_mentions_ai_contrib"] = bool(re.search(AI_POLICY_RX, rtxt) and re.search(r"(contribut)", rtxt, re.I))
        d["readme_sponsor_link"] = bool(re.search(r"(github\.com/sponsors|opencollective|ko-fi|buymeacoffee|patreon|liberapay)", rtxt, re.I))
    # contributing contents
    cp = d.get("contributing_path"); ctxt = None
    if not cp and inh:
        h = has_path(inh, FILES["contributing"], ("", ".github/", "docs/"))
        if h: ctxt = get_raw(f"{o}/.github", h[0])
    elif cp: ctxt = get_raw(full, cp)
    d["contributing_chars"] = len(ctxt) if ctxt else 0
    d["contributing_cla_dco_text"] = bool(ctxt and re.search(CLA_RX, ctxt))
    d["contributing_ai_policy_text"] = bool(ctxt and re.search(AI_POLICY_RX, ctxt))
    ai_files = has_path(P, r"(ai[-_]?(policy|contribut\w*|guidelines?|usage|disclosure)|llm[-_]?policy)(\.md)?", ("", ".github/", "docs/"))
    ai_files = ai_files + [p for p in P if re.fullmatch(r"\.github/workflows/[^/]*ai[-_]?policy[^/]*\.ya?ml", p, re.I)]
    d["ai_policy_file"] = bool(ai_files)
    d["ai_policy_any"] = d["contributing_ai_policy_text"] or d["ai_policy_file"] or bool(d.get("readme_mentions_ai_contrib"))
    d["cla_dco_config_file"] = bool(has_path(P, r"(\.clabot|dco\.ya?ml|cla\.ya?ml|\.cla\.ya?ml)", ("", ".github/")))
    # workflows
    wfs = [p for p in P if re.fullmatch(r"\.github/workflows/[^/]+\.ya?ml", p)]
    d["n_workflows"] = len(wfs); d["workflow_names"] = ";".join(w.split("/")[-1] for w in wfs)
    texts = {}
    for w in wfs[:8]:
        c = get_raw(full, w)
        if c: texts[w] = c
    d["n_workflows_read"] = len(texts)
    blob = "\n".join(f"# FILE {k}\n{v}" for k, v in texts.items()) + "\n" + " ".join(wfs)
    for k, rx in WF_RX.items(): d["wf_" + k] = bool(re.search(rx, blob, re.I)) if wfs else False
    d["wf_tests_or_lint"] = d["wf_ci_test"] or d["wf_ci_lint"]
    # pinning
    uses = []
    for c in texts.values():
        for m in re.finditer(r"^\s*-?\s*uses:\s*['\"]?([^\s'\"#]+)", c, re.M):
            u = m.group(1)
            if u.startswith("./") or u.startswith("docker://") or "@" not in u: continue
            uses.append(u)
    sha = [u for u in uses if re.fullmatch(r"[0-9a-f]{40}", u.split("@", 1)[1])]
    d["wf_external_uses"] = len(uses); d["wf_uses_sha_pinned"] = len(sha)
    d["pinning"] = "n/a" if not uses else ("all_sha" if len(sha) == len(uses) else ("none" if not sha else "mixed"))
    d["cla_dco_any"] = d["wf_cla_dco"] or d["contributing_cla_dco_text"] or d["cla_dco_config_file"]
    # releases / tags
    st, h, rel = gh(f"repos/{full}/releases", {"per_page": 1})
    if st == 200:
        lp = last_page(h); d["releases_count"] = lp if lp else len(rel)
        d["latest_release_date"] = rel[0]["published_at"] if rel else ""
        d["latest_release_tag"] = rel[0]["tag_name"] if rel else ""
    else: d["errors"].append(f"releases {st}")
    st, h, tags = gh(f"repos/{full}/tags", {"per_page": 30})
    if st == 200 and isinstance(tags, list):
        names = [x["name"] for x in tags]
        d["tags_sampled"] = len(names)
        d["tags_semver_frac"] = round(sum(bool(re.fullmatch(r"v?\d+\.\d+(\.\d+)?([-+.][0-9A-Za-z.-]+)?", n)) for n in names) / len(names), 2) if names else None
        d["has_tags"] = bool(names)
    # contributors
    st, h, con = gh(f"repos/{full}/contributors", {"per_page": 1, "anon": "false"})
    if st == 200: lp = last_page(h); d["contributors"] = lp if lp else len(con)
    elif st == 204: d["contributors"] = 0
    else: d["errors"].append(f"contributors {st}")
    # community profile
    st, _, cp_ = gh(f"repos/{full}/community/profile")
    if st == 200:
        d["health_pct"] = cp_.get("health_percentage")
        files = cp_.get("files", {})
        for k in ("code_of_conduct", "contributing", "license", "readme", "issue_template", "pull_request_template", "code_of_conduct_file"):
            d["cp_" + k] = bool(files.get(k))
        d["cp_description"] = bool(cp_.get("description"))
    else: d["errors"].append(f"community {st}")
    # PVR
    st, _, pv = gh(f"repos/{full}/private-vulnerability-reporting")
    d["pvr_enabled"] = pv.get("enabled") if st == 200 and isinstance(pv, dict) else None
    if st != 200: d["errors"].append(f"pvr {st}")
    d["security_policy_or_pvr"] = bool(d.get("security_any")) or bool(d["pvr_enabled"])
    return d

def flatten(d):
    return {k: (";".join(v) if isinstance(v, list) else v) for k, v in d.items() if k != "errors"} | {"errors": ";".join(d.get("errors", []))}

def survey(sample_file, outdir):
    sample = json.load(open(sample_file))
    def work(s):
        try: return survey_repo(s["item"], s["band"], s["win"])
        except Exception as e: return {"full_name": s["item"]["full_name"], "errors": [f"exception {e}"], "valid": False}
    prog = os.path.join(outdir, "progress.jsonl"); done = {}
    if os.path.exists(prog):
        for l in open(prog):
            x = json.loads(l)
            if x.get("valid") is not False or not any("exception" in e for e in x.get("errors", [])): done[x["full_name"]] = x
    def work2(s):
        if s["item"]["full_name"] in done: return done[s["item"]["full_name"]]
        x = work(s)
        with open(prog, "a") as f: f.write(json.dumps(x) + "\n")
        return x
    with ThreadPoolExecutor(4) as ex: res = list(ex.map(work2, sample))
    json.dump(res, open(os.path.join(outdir, "survey_raw.json"), "w"), indent=1)
    return res

# ---------- stage 3: stricter second-pass checks (re-fetches README, CONTRIBUTING, workflows) ----------
STRICT_TEST = r"(pytest|npm (run )?test|pnpm( run)? (-r )?test|yarn( run)? test|bun test|cargo (test|nextest)|go test|vitest|jest\b|ctest|make (test|check)|gradlew? \S*test|mvn\b.*\btest|dotnet test|rspec|phpunit|swift test|flutter test|playwright test|deno test|unittest|\btox\b|\bnox\b|just test|xcodebuild.*\btest)"
STRICT_AI = r"(claude-code-action|anthropics/claude|coderabbit|copilot-pull-request-reviewer|openai/codex-action|codex-action|run-gemini-cli|gemini-cli-action|gemini-code-assist|greptile|qodo|pr-agent|sourcery|cursor-agent|ai-review|claude-review|@claude\b|opencode github)"
STRICT_AIPOL = r"(AI[- ]generated|AI[- ]assisted|AI[- ]written|AI[- ]authored|(generated|written|produced) (by|with|using) (an? )?(AI|LLM|large language)|LLM[- ]generated|use of (AI|LLMs?)|\bAI tools?\b|\bAI agents?\b|\bLLMs?\b|Copilot|ChatGPT|\bClaude\b|vibe[- ]?cod|generative AI|AI policy|AI contributions?)"
def validate(sample_json, outfile):
    rows = json.load(open(sample_json)); out = []
    def one(d):
        full = d["full_name"]; o = full.split("/")[0]; v = {"full_name": full}
        rt = get_raw(full, d["readme_path"]) if d.get("readme_path") else None
        if rt is not None:
            nob = re.sub(r"!\[[^\]]*\]\([^)]*(shields\.io|badge|badgen|codecov|travis|circleci|github\.com/[^)]*/workflows/|visitor-badge|hits\.|komarev|star-history|contrib\.rocks|capsule-render)[^)]*\)", "", rt, flags=re.I)
            nob = re.sub(r"<img[^>]*(shields\.io|badge|badgen|codecov|visitor|hits\.|komarev|star-history|contrib\.rocks|capsule-render)[^>]*>", "", nob, flags=re.I)
            v["v_readme_demo_strict"] = bool(re.search(r"(!\[[^\]]*\]\([^)]+\.(gif|png|jpe?g|webp|mp4|webm)|!\[[^\]]*\]\(https?://[^)]*(user-attachments|githubusercontent)[^)]*\)|<img\s[^>]*src|<video|youtu\.be|youtube\.com/watch|asciinema\.org|user-attachments/assets|\.mp4|\.webm)", nob, re.I))
        cp = d.get("contributing_path"); ctxt = get_raw(full, cp) if cp else None
        ctx = []
        if ctxt:
            for m in re.finditer(STRICT_AIPOL, ctxt):
                ctx.append(ctxt[max(0, m.start() - 80): m.end() + 80].replace("\n", " "))
        # Contexts are printed for the manual policy review but not stored: they are verbatim
        # text from the surveyed repositories and are not published.
        v["v_contrib_ai_hits"] = len(ctx)
        if ctx: print(full, " || ".join(ctx[:3]), file=sys.stderr)
        wfs = [w for w in (d.get("workflow_names") or "").split(";") if w]
        txt = ""
        for w in wfs[:8]:
            c = get_raw(full, ".github/workflows/" + w)
            if c: txt += "\n# FILE " + w + "\n" + c
        v["v_wf_test_strict"] = bool(re.search(STRICT_TEST, txt, re.I)) if wfs else False
        ai = re.findall(STRICT_AI, txt, re.I); v["v_wf_ai_strict"] = bool(ai); v["v_wf_ai_matches"] = ";".join(sorted(set(a.lower() if isinstance(a, str) else a[0].lower() for a in ai)))[:200]
        v["v_wf_triggers_pr_target"] = bool(re.search(r"pull_request_target", txt))
        v["v_wf_permissions_block"] = bool(re.search(r"^\s*permissions:", txt, re.M))
        return v
    with ThreadPoolExecutor(4) as ex: out = list(ex.map(one, rows))
    json.dump(out, open(outfile, "w"), indent=1)

if __name__ == "__main__":
    if sys.argv[1] == "candidates": candidates(sys.argv[2])
    elif sys.argv[1] == "survey": survey(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "validate": validate(sys.argv[2], sys.argv[3])

