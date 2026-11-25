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
  holds the environment each tool was started with;
- a .env it makes holds values of its own, never the example's published
  placeholders (scripts/make_env.py).

Every case runs a copy of scripts/ and the files the scripts read in a
temporary folder, so nothing is written into the checkout.

It also checks that no step of .github/workflows/ci.yml is skipped because
the script it runs is missing: a renamed or deleted script must fail CI,
not turn its step into a green skip.

Usage: python3 -I scripts/test_e2e_core_loop.py [-v]
Standard library only; exits 0 when every case behaves as expected. Every
value is made up.
"""

import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
MAKE_ENV = HERE / "make_env.py"
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


def copy_repository(target):
    """Copies what the scripts under test read into `target`, which then
    stands for the repository root: scripts/, the compose files, the
    example configuration and an empty mac/ for their `cd mac`."""
    shutil.copytree(HERE, target / "scripts", ignore=shutil.ignore_patterns("__pycache__"))
    for name in (".env.example", "compose.yaml", "compose.test.yaml"):
        shutil.copy2(ROOT / name, target / name)
    (target / "mac").mkdir()
    return target


class Run:
    """A scratch folder with a copy of the repository, the stand-in programs
    and the script's TMPDIR."""

    def __init__(self):
        self._folder = tempfile.TemporaryDirectory()
        self.root = Path(self._folder.name)
        self.repo = copy_repository(self.root / "repo")
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

    def run(self, call_value="nothing secret here", *, script="e2e_core_loop.sh", arguments=(), **extra):
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
            ["bash", str(self.repo / "scripts" / script), *arguments], cwd=self.repo, env=environment,
            capture_output=True, text=True,
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
            script="e2e_credentials.sh", LEVERAGE_E2E_ONLY="AddAndReadEndToEndTests",
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


class SpeedRunTests(unittest.TestCase):
    """Review: speed_run.sh took an exported COMPOSE_PROJECT_NAME as its
    project, and its cleanup removes the project's volumes, so a developer's
    stack under that name lost its database."""

    def test_an_exported_project_name_is_never_the_project_it_removes(self):
        run = Run()
        self.addCleanup(run.close)
        code, output = run.run(script="speed_run.sh", arguments=("--smoke",),
                               COMPOSE_PROJECT_NAME="made-up-dev-stack", FAKE_UP_FAILS="1")
        self.assertNotEqual(code, 0, output)
        calls = run.docker_calls()
        self.assertTrue(any("down --volumes" in arguments for _tag, _project, arguments in calls), calls)
        for _tag, project, _arguments in calls:
            self.assertNotEqual(project, "made-up-dev-stack", calls)
            self.assertRegex(project, r"-[0-9]+$", "the project is this run's own, with its pid")


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
        subprocess.run(["bash", str(run.repo / "scripts" / script)], cwd=run.repo, env=environment, capture_output=True, text=True,
                       check=False, timeout=120)
        self.assertTrue(mode.exists(), f"{script} handed docker no backup folder")
        return mode.read_text(encoding="utf-8").strip()

    def test_the_restore_drills_folder_is_sticky(self):
        self.assertEqual(self.mode_of_backup_folder("restore_drill.sh"), "0o1777")

    def test_the_handoff_runs_folders_are_sticky(self):
        self.assertEqual(self.mode_of_backup_folder("e2e_handoff.sh"), "0o1777")


PLACEHOLDER = "change-me"
SECRET_KEYS = ("POSTGRES_PASSWORD", "LEVERAGE_API_DB_PASSWORD", "SECRET_KEY_BASE")


def env_values(path):
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values


def placeholders(path):
    return [key for key, value in env_values(path).items() if PLACEHOLDER in value]


class EnvFileTests(unittest.TestCase):
    """Review: a script that made .env copied .env.example, so a later
    `docker compose up` ran with passwords and a Rails secret published in
    the repository. A .env a script makes now holds values of its own."""

    def make(self, folder):
        return subprocess.run(
            ["python3", "-I", str(folder / "scripts" / "make_env.py"), str(folder)],
            capture_output=True, text=True, check=False, timeout=60)

    def repository(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        return copy_repository(Path(folder.name) / "repo")

    def test_the_example_has_the_placeholders_the_helper_replaces(self):
        example = env_values(ROOT / ".env.example")
        for key in SECRET_KEYS:
            self.assertTrue(example[key].startswith(PLACEHOLDER), key)

    def test_a_made_env_has_values_of_its_own(self):
        first, second = self.repository(), self.repository()
        for folder in (first, second):
            result = self.make(folder)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("made .env", result.stdout)
        made, other = env_values(first / ".env"), env_values(second / ".env")
        self.assertEqual(placeholders(first / ".env"), [])
        secrets = [made[key] for key in SECRET_KEYS]
        self.assertEqual(len(set(secrets)), 3, "each secret has a value of its own")
        for key in SECRET_KEYS:
            self.assertRegex(made[key], r"^[0-9a-f]{64,}$", key)
            self.assertNotEqual(made[key], other[key], f"{key} is new on each run")
        self.assertEqual(made["POSTGRES_USER"], "leverage", "values that are no secret are kept")
        self.assertEqual(stat.S_IMODE((first / ".env").stat().st_mode), 0o600)
        self.assertEqual(list(first.glob(".env.*")), [first / ".env.example"], "no temporary file is left")

    def test_an_existing_env_is_left_as_it_is(self):
        folder = self.repository()
        existing = "POSTGRES_PASSWORD=the-owners-own-value\n"
        (folder / ".env").write_text(existing, encoding="utf-8")
        result = self.make(folder)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((folder / ".env").read_text(encoding="utf-8"), existing)
        self.assertNotIn("made .env", result.stdout)

    def test_a_script_makes_env_with_the_helper_in_its_own_tree(self):
        for script in ("e2e_core_loop.sh", "e2e_credentials.sh", "e2e_handoff.sh"):
            with self.subTest(script=script):
                run = Run()
                self.addCleanup(run.close)
                run.run(script=script, FAKE_UP_FAILS="1", API_IMAGE_TAG="made-up-tag")
                made = run.repo / ".env"
                self.assertTrue(made.exists(), "the script made .env in the copy it ran from")
                self.assertEqual(placeholders(made), [])

    def test_no_script_copies_the_example(self):
        for script in sorted(HERE.glob("*.sh")):
            with self.subTest(script=script.name):
                self.assertNotRegex(script.read_text(encoding="utf-8"), r"cp [^\n]*\.env\.example")


# A docker for the drill: every query answers 1, and the first `stop`
# fails, so a drill that was not refused ends at its first step.
FAKE_DOCKER_DRILL = """#!/bin/sh
printf '%s|%s|%s\\n' "${API_IMAGE_TAG:-}" "${COMPOSE_PROJECT_NAME:-}" "$*" >>"$FAKE_LOG"
case "$*" in
  *" exec "*) echo 1 ;;
  *" stop "*) exit 1 ;;
esac
exit 0
"""


class RestoreDrillProjectTests(unittest.TestCase):
    """Review: --from-project removes the named project and its database
    volume, also on failure, and took any name, the owner's `leverage` and
    the app's `leverage-app` included. It now takes only the end-to-end
    runs' own projects, and refuses before any docker call."""

    def drill(self, name):
        run = Run()
        self.addCleanup(run.close)
        (run.bin / "docker").write_text(FAKE_DOCKER_DRILL, encoding="utf-8")
        backups = run.root / "backups"
        backups.mkdir()
        code, output = run.run(script="restore_drill.sh", arguments=("--from-project", name),
                               LEVERAGE_BACKUP_DIR=str(backups), API_IMAGE_TAG="made-up-tag")
        return code, output, run.docker_calls()

    def test_the_owners_and_the_apps_projects_are_refused_before_docker(self):
        for name in ("leverage", "leverage-app", "made-up-dev-stack", "leverage-e2e"):
            with self.subTest(name=name):
                code, output, calls = self.drill(name)
                self.assertEqual(code, 2, output)
                self.assertIn("removes the project and its database volume", output)
                self.assertEqual(calls, [], "no docker call, so no `down --volumes`")

    def test_an_end_to_end_runs_project_is_taken(self):
        code, output, calls = self.drill("leverage-e2e-handoff-1-6")
        self.assertNotEqual(code, 2, output)
        self.assertTrue(calls, output)
        self.assertTrue(all("-p leverage-e2e-handoff-1-6" in arguments for _tag, _project, arguments in calls
                            if arguments.startswith("compose")), calls)


class ContinuousIntegrationTests(unittest.TestCase):
    def test_no_step_is_skipped_because_its_script_is_missing(self):
        guards = CI.read_text(encoding="utf-8").count("hashFiles(")
        self.assertEqual(guards, 0, f"{guards} steps of ci.yml are skipped when their script is missing")

    def test_the_documented_npx_commands_name_one_exact_version(self):
        """Review: the local Markdown lint ran whatever markdownlint-cli2
        npm served that day, not the version CI's pinned action bundles."""
        commands = {}
        for name in ("AGENTS.md", "CONTRIBUTING.md"):
            for package in re.findall(r"npx (?:--yes )?(\S+)", (ROOT / name).read_text(encoding="utf-8")):
                commands.setdefault(package.split("@")[0], set()).add(package)
        self.assertIn("markdownlint-cli2", commands)
        for base, spelled in commands.items():
            with self.subTest(package=base):
                self.assertEqual(len(spelled), 1, f"the documents name different versions: {spelled}")
                self.assertRegex(spelled.pop(), r"^[\w.-]+@\d+\.\d+\.\d+$", "an exact version")

    def test_dependabot_watches_every_pinned_manifest(self):
        """Review: only the actions had an updater, so the locked gems and
        the digest-pinned Ruby and PostgreSQL images went stale silently."""
        text = (ROOT / ".github" / "dependabot.yml").read_text(encoding="utf-8")
        entries = set(re.findall(
            r'package-ecosystem:\s*"([^"]+)"\s*\n\s*directory:\s*"([^"]+)"', text))
        manifests = {
            ("github-actions", "/"): ".github/workflows",
            ("bundler", "/api"): "api/Gemfile.lock",
            ("docker", "/api"): "api/Dockerfile",
            ("docker-compose", "/"): "compose.yaml",
        }
        for entry, manifest in manifests.items():
            with self.subTest(manifest=manifest):
                self.assertTrue((ROOT / manifest).exists(), manifest)
                self.assertIn(entry, entries, f"no Dependabot entry for {manifest}")
        self.assertEqual(text.count('prefix: "chore(deps)"'), len(entries),
                         "every entry gives its pull requests the Conventional Commits title")

    def test_dependabot_can_read_and_name_each_pinned_image(self):
        """Review: the Ruby image's tag came from an ARG, which Dependabot
        does not resolve, so the entry for api/Dockerfile found no image;
        and its ignore rule named `ruby`, while Dependabot names an image by
        its whole path with only the docker.io registry removed."""
        text = (ROOT / ".github" / "dependabot.yml").read_text(encoding="utf-8")
        ignored = {}
        for block in re.split(r"(?m)^  - (?=package-ecosystem:)", text)[1:]:
            ecosystem = re.match(r'package-ecosystem:\s*"([^"]+)"', block).group(1)
            ignored[ecosystem] = set(re.findall(r'dependency-name:\s*"([^"]+)"', block))
        image = r"(?P<image>[a-z0-9./_-]+):(?P<tag>\w[\w.-]*)@sha256:[0-9a-f]{64}"
        froms = re.findall(r"(?m)^FROM\s+(\S+)", (ROOT / "api" / "Dockerfile").read_text(encoding="utf-8"))
        external = [ref for ref in froms if ref != "base"]
        self.assertEqual(len(external), 1, f"one image from a registry, the others build on it: {froms}")
        ruby = re.fullmatch(image, external[0])
        self.assertIsNotNone(ruby, f"{external[0]}: a literal tag and a digest, no ARG, or Dependabot finds no image")
        version = (ROOT / "api" / ".ruby-version").read_text(encoding="utf-8").strip().removeprefix("ruby-")
        self.assertEqual(ruby["tag"], f"{version}-slim", "the image's tag and api/.ruby-version name one version")
        compose = re.findall(r"(?m)^\s+image:\s*(\S+)", (ROOT / "compose.yaml").read_text(encoding="utf-8"))
        pinned = [re.fullmatch(image, ref) for ref in compose if "@" in ref]
        self.assertEqual(len(pinned), 1, f"one digest-pinned image in compose.yaml: {compose}")
        self.assertIsNotNone(pinned[0], "a literal tag and a digest")
        for ecosystem, found in (("docker", ruby), ("docker-compose", pinned[0])):
            with self.subTest(ecosystem=ecosystem):
                name = found["image"].removeprefix("docker.io/")
                self.assertEqual(ignored[ecosystem], {name},
                                 "the ignore rule names the image as Dependabot does")


if __name__ == "__main__":
    unittest.main()
