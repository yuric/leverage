#!/usr/bin/env python3
"""Self-test for e2e_core_loop.sh's own plumbing, and for CI's steps.

scripts/e2e_core_loop.sh is the one test of the whole core loop (milestone
2 plan §5.2). Its real run needs Docker and Swift; these cases run the
script itself with stand-in `docker`, `swift` and `curl` programs first on
PATH, which record what they were asked and write what the real ones
would, so what the script does around the run is checked in a second:

- it builds and runs the API under an image tag of its own, never the
  shared `leverage-api:local`, and removes that image when it is done, but
  leaves an image whose tag it was given;
- its secret scan covers the stand-in tools' record of each call, which
  holds the environment each tool was started with.

It also checks that no step of .github/workflows/ci.yml is skipped because
the script it runs is missing: a renamed or deleted script must fail CI,
not turn its step into a green skip.

Usage: python3 -I scripts/test_e2e_core_loop.py [-v]
Standard library only; exits 0 when every case behaves as expected. Every
value is made up.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SCRIPT = HERE / "e2e_core_loop.sh"
CI = ROOT / ".github" / "workflows" / "ci.yml"

SECRET = "made-up-e2e-secret-value"

FAKE_DOCKER = """#!/bin/sh
printf '%s|%s|%s\\n' "${API_IMAGE_TAG:-}" "${COMPOSE_PROJECT_NAME:-}" "$*" >>"$FAKE_LOG"
case "$*" in
  *" up "*) [ -n "${FAKE_UP_FAILS:-}" ] && exit 1; exit 0 ;;
  *" port api 3000"*) echo "127.0.0.1:40001"; exit 0 ;;
  *"pg_dump"*)
    printf '%s\\n' 'COPY public.credentials (id, plan, account_email) FROM stdin;'
    if [ "${LEVERAGE_E2E_ONLY:-}" != promptReportsModel ] || [ -n "${FAKE_LEAK_ACCOUNT_EMAIL:-}" ]; then
      printf '1\\t\\\\N\\t%s\\n' 'standin.owner@example.invalid'
    fi
    printf '%s\\n' '\\.'
    exit 0 ;;
esac
exit 0
"""

FAKE_SWIFT = """#!/bin/sh
case "$1" in
  build) exit 0 ;;
  test)
    names="CoreLoop StoppedReviewer PromptJoin ReportModel CreateTask DeliverOffOffer DeliverOffRelease"
    case "$*" in *"--filter LeverageEndToEnd.*PromptJoinEndToEndTests"*) names="PromptJoin" ;; esac
    case "$*" in *"--filter LeverageEndToEnd.*promptReportsModel"*) names="ReportModel" ;; esac
    for name in $names; do
      if [ "$name" = "${FAKE_OMIT_CASE:-}" ]; then continue; fi
      folder="$LEVERAGE_E2E_DIR/$name"
      mkdir -p "$folder"
      printf '%s\\n' "$FAKE_SECRET" >"$folder/secrets.txt"
      case "$name" in
        CoreLoop|StoppedReviewer|PromptJoin)
          mkdir -p "$folder/support/logs" "$folder/StandIns/state"
          echo "helper info: nothing to see" >"$folder/support/logs/helper.log"
          printf '{"tool": "claude", "env": {"MADE_UP": "%s"}}\\n' "$FAKE_CALL_VALUE" >"$folder/StandIns/state/calls.jsonl"
          ;;
      esac
    done
    exit 0 ;;
esac
exit 0
"""

FAKE_CURL = "#!/bin/sh\nexit 0\n"


class Run:
    """A scratch folder with the stand-in programs and the script's TMPDIR."""

    def __init__(self):
        self._folder = tempfile.TemporaryDirectory()
        self.root = Path(self._folder.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.tmp = self.root / "tmp"
        self.tmp.mkdir()
        self.log = self.root / "docker.log"
        for name, text in (("docker", FAKE_DOCKER), ("swift", FAKE_SWIFT), ("curl", FAKE_CURL)):
            path = self.bin / name
            path.write_text(text, encoding="utf-8")
            path.chmod(0o755)

    def close(self):
        self._folder.cleanup()

    def run(self, call_value="nothing secret here", *, script=SCRIPT, **extra):
        environment = {
            "PATH": f"{self.bin}:{os.environ.get('PATH', '/usr/bin:/bin')}",
            "HOME": str(self.root),
            "TMPDIR": str(self.tmp),
            "FAKE_LOG": str(self.log),
            "FAKE_SECRET": SECRET,
            "FAKE_CALL_VALUE": call_value,
            **extra,
        }
        result = subprocess.run(
            ["bash", str(script)], cwd=ROOT, env=environment, capture_output=True, text=True,
            check=False, timeout=120)
        return result.returncode, result.stdout + result.stderr

    def docker_calls(self):
        if not self.log.exists():
            return []
        return [line.split("|", 2) for line in self.log.read_text(encoding="utf-8").splitlines()]


class EndToEndScriptTests(unittest.TestCase):
    def setUp(self):
        self.run_ = Run()
        self.addCleanup(self.run_.close)

    def test_the_stand_ins_pass_when_no_secret_is_anywhere(self):
        code, output = self.run_.run()
        self.assertEqual(code, 0, output)
        self.assertIn("no secret found", output)

    def test_the_full_run_requires_the_prompt_join_and_deliver_off_release_cases(self):
        for case in ("PromptJoin", "DeliverOffRelease"):
            with self.subTest(case=case):
                code, output = self.run_.run(FAKE_OMIT_CASE=case)
                self.assertEqual(code, 1, output)
                self.assertIn("expected all 7 end-to-end tests to run", output)

    def test_the_prompt_join_case_can_run_on_its_own(self):
        code, output = self.run_.run(LEVERAGE_E2E_ONLY="PromptJoinEndToEndTests")
        self.assertEqual(code, 0, output)
        self.assertIn("running 1 end-to-end test", output)

    def test_a_prompt_only_case_passes_with_no_helper_log(self):
        code, output = self.run_.run(LEVERAGE_E2E_ONLY="promptReportsModel")
        self.assertEqual(code, 0, output)
        self.assertIn("running 1 end-to-end test", output)
        self.assertIn("no secret found", output)
        self.assertNotIn("expected account email", output)

    def test_a_prompt_only_case_refuses_the_stand_in_account_email(self):
        code, output = self.run_.run(LEVERAGE_E2E_ONLY="promptReportsModel", FAKE_LEAK_ACCOUNT_EMAIL="1")
        self.assertEqual(code, 1, output)
        self.assertIn("dump.sql", output)
        self.assertNotIn("standin.owner@example.invalid", output)

    def test_the_api_image_has_a_tag_of_its_own_and_is_removed_after_the_run(self):
        code, output = self.run_.run(FAKE_UP_FAILS="1")
        self.assertNotEqual(code, 0, output)
        calls = self.run_.docker_calls()
        self.assertTrue(calls, output)
        tags = {tag for tag, _project, _arguments in calls if "compose" in _arguments}
        projects = {project for _tag, project, _arguments in calls}
        self.assertEqual(len(projects), 1, calls)
        project = projects.pop()
        self.assertTrue(project.startswith("leverage-e2e-"), project)
        self.assertEqual(tags, {project}, "compose builds and runs the image under the run's own tag")
        removed = [arguments for _tag, _project, arguments in calls if arguments.startswith("image rm")]
        self.assertEqual(removed, [f"image rm leverage-api:{project}"], calls)

    def test_an_image_tag_it_was_given_is_used_and_kept(self):
        code, output = self.run_.run(FAKE_UP_FAILS="1", API_IMAGE_TAG="made-up-tag")
        self.assertNotEqual(code, 0, output)
        calls = self.run_.docker_calls()
        self.assertEqual({tag for tag, _project, arguments in calls if "compose" in arguments}, {"made-up-tag"})
        self.assertFalse([arguments for _tag, _project, arguments in calls if arguments.startswith("image rm")])

    def test_a_secret_in_a_stand_in_tools_record_of_its_environment_fails_the_run(self):
        code, output = self.run_.run(call_value=SECRET)
        self.assertNotEqual(code, 0, output)
        self.assertIn("calls.jsonl", output)
        self.assertNotIn(SECRET, output)


COPIED_REPLY_LINE = "made-up reply body generated only in the test's stand-in copy"
FAKE_CREDENTIALS_SWIFT = """#!/bin/sh
if [ "$1" = test ]; then
  folder="$LEVERAGE_E2E_DIR/credentials"
  mkdir -p "$folder/support/logs" "$folder/StandIns/replies/codex"
  printf '%s\\n' "$FAKE_SECRET" >"$folder/secrets.txt"
  printf '{"meta":{"kind":"usage","marker":"LVRG-REPLY-000000000001"},"stdout":"%s"}\\n' \
    "$FAKE_REPLY_LINE" >"$folder/StandIns/replies/codex/usage-test-only.json"
  if [ -z "${FAKE_NO_HELPER_LOG:-}" ]; then
    printf '%s\\n' "$FAKE_HELPER_LINE" >"$folder/support/logs/helper.log"
  fi
fi
"""


class CredentialsScriptTests(unittest.TestCase):
    def setUp(self):
        self.run_ = Run()
        self.addCleanup(self.run_.close)
        (self.run_.bin / "swift").write_text(FAKE_CREDENTIALS_SWIFT, encoding="utf-8")

    def run_credentials(self, **extra):
        return self.run_.run(
            script=HERE / "e2e_credentials.sh", LEVERAGE_E2E_ONLY="AddAndReadEndToEndTests",
            API_IMAGE_TAG="made-up-tag", FAKE_REPLY_LINE=COPIED_REPLY_LINE, **extra)

    def test_the_helper_log_is_required_and_the_failed_run_is_removed(self):
        code, output = self.run_credentials(FAKE_NO_HELPER_LOG="1")
        self.assertEqual(code, 1, output)
        self.assertIn("the helper log is missing", output)
        self.assertEqual(list(self.run_.tmp.iterdir()), [])
        calls = self.run_.docker_calls()
        self.assertTrue(any("down --volumes" in arguments for _tag, _project, arguments in calls))

    def test_copied_reply_content_in_the_helper_log_fails_the_run(self):
        code, output = self.run_credentials(FAKE_HELPER_LINE=COPIED_REPLY_LINE)
        self.assertEqual(code, 1, output)
        self.assertIn("helper.log", output)
        self.assertIn("usage-test-only.json", output)
        self.assertNotIn(COPIED_REPLY_LINE, output)


# A docker that notes the mode of the backup folder it is handed, then
# fails, so the script under test stops at its first container.
FAKE_DOCKER_MODE = """#!/bin/sh
if [ -n "${LEVERAGE_BACKUP_DIR:-}" ] && [ -d "$LEVERAGE_BACKUP_DIR" ] && [ ! -f "$FAKE_MODE" ]; then
  python3 -I -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o7777))' "$LEVERAGE_BACKUP_DIR" >"$FAKE_MODE"
fi
exit 1
"""


class BackupFolderTests(unittest.TestCase):
    """Review: the backup folder the drill and the handoff run make for the
    containers is writable by every user (the container's uid differs from
    the caller's on Linux), and sticky, so that no other local user can
    rename or remove a dump in it before the restore reads it."""

    def mode_of_backup_folder(self, script):
        run = Run()
        self.addCleanup(run.close)
        docker = run.bin / "docker"
        docker.write_text(FAKE_DOCKER_MODE, encoding="utf-8")
        mode = run.root / "mode.txt"
        environment = {
            "PATH": f"{run.bin}:{os.environ.get('PATH', '/usr/bin:/bin')}", "HOME": str(run.root),
            "TMPDIR": str(run.tmp), "FAKE_MODE": str(mode), "API_IMAGE_TAG": "made-up-tag",
        }
        subprocess.run(["bash", str(HERE / script)], cwd=ROOT, env=environment, capture_output=True, text=True,
                       check=False, timeout=120)
        self.assertTrue(mode.exists(), f"{script} handed docker no backup folder")
        return mode.read_text(encoding="utf-8").strip()

    def test_the_restore_drills_folder_is_sticky(self):
        self.assertEqual(self.mode_of_backup_folder("restore_drill.sh"), "0o1777")

    def test_the_handoff_runs_folders_are_sticky(self):
        self.assertEqual(self.mode_of_backup_folder("e2e_handoff.sh"), "0o1777")


class ContinuousIntegrationTests(unittest.TestCase):
    def test_no_step_is_skipped_because_its_script_is_missing(self):
        guards = CI.read_text(encoding="utf-8").count("hashFiles(")
        self.assertEqual(guards, 0, f"{guards} steps of ci.yml are skipped when their script is missing")


if __name__ == "__main__":
    unittest.main()
