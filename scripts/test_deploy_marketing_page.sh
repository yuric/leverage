#!/usr/bin/env bash
# Exercise the deployment against a local Git fixture and command stand-ins.
set -euo pipefail
python3 -I - "${1:-$(dirname "$0")/deploy_marketing_page.sh}" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(sys.argv.pop()).resolve()
BUCKET = "fixture-marketing"
DISTRIBUTION = "FIXTURE01"
PUBLIC_URLS = ("https://ageoflever.com/", "https://www.ageoflever.com/")

AWS = r'''
import json
import os
from pathlib import Path
import sys

root = Path(os.environ["AWS_STAND_IN_ROOT"])
marker = root / "marker"
args = sys.argv[1:]
command = args[:2]

def option(name):
    return args[args.index(name) + 1]

def fail(code, message):
    print(message, file=sys.stderr)
    sys.exit(code)

state = marker.read_text().strip() if marker.exists() else None
body = Path(option("--body")).read_text().strip() if command == ["s3api", "put-object"] else None
with (root / "calls").open("a") as log:
    log.write(json.dumps({"args": args, "state": state, "body": body}) + "\n")

if command[:1] == ["s3api"]:
    assert option("--bucket") == os.environ["MARKETING_BUCKET"]
    assert option("--key") == ".well-known/deployed-marketing-revision"
if command == ["s3api", "get-object"]:
    if os.environ.get("AWS_STAND_IN_FAILURE") == "read":
        fail(254, "An error occurred (AccessDenied) when calling the GetObject operation")
    if state is None:
        fail(254, "An error occurred (NoSuchKey) when calling the GetObject operation")
    Path(args[-1]).write_text(marker.read_text())
    print("{}")
elif command == ["s3api", "put-object"]:
    marker.write_text(body + "\n")
    print("{}")
elif command == ["s3", "cp"]:
    assert state == "in-progress"
    assert any(arg.startswith("s3://" + os.environ["MARKETING_BUCKET"] + "/") for arg in args)
elif command == ["s3", "sync"]:
    assert state == "in-progress"
    assert any(arg.startswith("s3://" + os.environ["MARKETING_BUCKET"] + "/") for arg in args)
    assert "--delete" in args
    assert "--size-only" in args
    assert option("--exclude") == ".well-known/deployed-marketing-revision"
elif command == ["cloudfront", "create-invalidation"]:
    assert state == "in-progress"
    assert option("--distribution-id") == os.environ["MARKETING_DISTRIBUTION"]
    assert option("--paths") == "/*"
    assert option("--query") == "Invalidation.Id"
    assert option("--output") == "text"
    print("FIXTUREINVALIDATION")
elif command == ["cloudfront", "wait"]:
    assert state == "in-progress"
    assert args[2] == "invalidation-completed"
    assert option("--distribution-id") == os.environ["MARKETING_DISTRIBUTION"]
    assert option("--id") == "FIXTUREINVALIDATION"
    if os.environ.get("AWS_STAND_IN_FAILURE") == "wait":
        fail(255, "Waiter InvalidationCompleted failed")
else:
    fail(92, f"Unexpected AWS command: {args}")
'''

CURL = r'''
import json
import os
from pathlib import Path
import sys

root = Path(os.environ["AWS_STAND_IN_ROOT"])
args = sys.argv[1:]
url, = (arg for arg in args if arg.startswith("https://"))
state = (root / "marker").read_text().strip()
with (root / "calls").open("a") as log:
    log.write(json.dumps({"args": ["curl", url], "state": state}) + "\n")
assert state == "in-progress"
assert url in ("https://ageoflever.com/", "https://www.ageoflever.com/")
if url == "https://www.ageoflever.com/" and os.environ["AWS_STAND_IN_FAILURE"] == "probe":
    body = b"<p>Stale page</p>\n"
else:
    body = (root / "repo" / "marketing-page" / "index.html").read_bytes()
output = next((args[index + 1] for index, arg in enumerate(args)
               if arg in ("-o", "--output")), "-")
if output == "-":
    sys.stdout.buffer.write(body)
else:
    Path(output).write_bytes(body)
'''


class DeployMarketingPageTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.marker = self.root / "marker"
        self.calls = self.root / "calls"
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for name, source in (("aws", AWS), ("curl", CURL)):
            stub = bin_dir / name
            stub.write_text("#!/usr/bin/env python3\n" + source)
            stub.chmod(0o755)
        self.env = dict(os.environ)
        for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "AWS_STAND_IN_FAILURE"):
            self.env.pop(name, None)
        self.env.update(
            PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            MARKETING_BUCKET=BUCKET,
            MARKETING_DISTRIBUTION=DISTRIBUTION,
            AWS_STAND_IN_ROOT=str(self.root),
        )
        self.git("init", "-q")
        page = self.repo / "marketing-page"
        page.mkdir()
        (page / "index.html").write_text("<p>Fixture</p>\n")
        (page / "asset.mjs").write_text("export const fixture = true;\n")
        self.git("add", "marketing-page")
        self.commit("Marketing page")
        self.revision = self.git("rev-parse", "HEAD:marketing-page")

    def git(self, *args):
        return subprocess.run(
            ["git", *args], cwd=self.repo, env=self.env, check=True,
            capture_output=True, text=True,
        ).stdout.strip()

    def commit(self, message):
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
                 "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                 "commit", "-qm", message)

    def deploy(self, *, failure="", succeeds=True):
        self.calls.write_text("")
        env = dict(self.env, AWS_STAND_IN_FAILURE=failure)
        result = subprocess.run(
            ["bash", str(SCRIPT)], cwd=self.repo, env=env, text=True,
            capture_output=True, timeout=30,
        )
        output = result.stdout + result.stderr
        if succeeds:
            self.assertEqual(result.returncode, 0, output)
        else:
            self.assertNotEqual(result.returncode, 0, output)
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def assert_deploy_order(self, calls, *, failure=""):
        expected = [
            ["s3api", "get-object"],
            ["s3api", "put-object"],
            ["s3", "cp"],
            ["s3", "cp"],
            ["s3", "cp"],
            ["s3", "sync"],
            ["cloudfront", "create-invalidation"],
            ["cloudfront", "wait"],
        ]
        if failure != "wait":
            expected.extend(["curl", url] for url in PUBLIC_URLS)
        if not failure:
            expected.append(["s3api", "put-object"])
        self.assertEqual([entry["args"][:2] for entry in calls], expected)
        self.assertEqual(calls[1]["body"], "in-progress")
        ordinary_assets = calls[2]["args"]
        exclusions = [
            ordinary_assets[index + 1]
            for index, arg in enumerate(ordinary_assets) if arg == "--exclude"
        ]
        self.assertIn("--recursive", ordinary_assets)
        self.assertIn("index.html", exclusions)
        self.assertIn("*.mjs", exclusions)

        modules = calls[3]["args"]
        self.assertIn("--recursive", modules)
        self.assertEqual(modules[modules.index("--exclude") + 1], "*")
        self.assertEqual(modules[modules.index("--include") + 1], "*.mjs")
        self.assertEqual(modules[modules.index("--content-type") + 1], "text/javascript")

        self.assertIn(f"s3://{BUCKET}/index.html", calls[4]["args"])
        if not failure:
            self.assertEqual(calls[-1]["body"], self.revision)
            self.assertEqual(self.marker.read_text().strip(), self.revision)
        else:
            self.assertEqual(self.marker.read_text().strip(), "in-progress")

    def test_missing_marker_deploys(self):
        calls = self.deploy()
        self.assertIsNone(calls[0]["state"])
        self.assert_deploy_order(calls)

    def test_unchanged_subtree_skips_after_unrelated_commit(self):
        self.marker.write_text(self.revision + "\n")
        (self.repo / "README.md").write_text("Unrelated change\n")
        self.git("add", "README.md")
        self.commit("Change unrelated file")
        calls = self.deploy()
        self.assertEqual([entry["args"][:2] for entry in calls], [["s3api", "get-object"]])
        self.assertEqual(self.marker.read_text().strip(), self.revision)

    def test_marker_read_error_fails_closed(self):
        self.marker.write_text(self.revision + "\n")
        calls = self.deploy(failure="read", succeeds=False)
        self.assertEqual([entry["args"][:2] for entry in calls], [["s3api", "get-object"]])
        self.assertEqual(self.marker.read_text().strip(), self.revision)

    def test_failed_invalidation_preserves_dirty_marker_for_retry(self):
        self.marker.write_text("0" * len(self.revision) + "\n")
        self.assert_deploy_order(self.deploy(failure="wait", succeeds=False), failure="wait")
        retry = self.deploy()
        self.assertEqual(retry[0]["state"], "in-progress")
        self.assert_deploy_order(retry)

    def test_mismatched_public_page_preserves_dirty_marker_for_retry(self):
        self.assert_deploy_order(self.deploy(failure="probe", succeeds=False), failure="probe")
        retry = self.deploy()
        self.assertEqual(retry[0]["state"], "in-progress")
        self.assert_deploy_order(retry)


unittest.main()
PY
