#!/usr/bin/env python3
"""Self-test for check_home_paths.py.

Each case makes a small git repository in a temporary folder, commits
made-up files to it and runs the check there: placeholder home folders
pass, a real-looking one fails and names the file and line, and a file
that is not tracked is not read. One case runs the check on the
repository itself.

Usage: python3 -I scripts/test_check_home_paths.py [-v]
Standard library and git only; exits 0 when every case behaves as expected.
Every value is made up; the paths the check must refuse are put together
from pieces, so that this file itself passes the check.
"""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SCRIPT = HERE / "check_home_paths.py"
USERS = "/Us" + "ers/"
HOME = "/ho" + "me/"


def check(root):
    result = subprocess.run([sys.executable, "-I", str(SCRIPT), "--root", str(root)],
                            capture_output=True, text=True, check=False, timeout=60)
    return result.returncode, result.stdout + result.stderr


class Repository:
    def __init__(self, test):
        folder = tempfile.TemporaryDirectory()
        test.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)

    def add(self, name, text, *, track=True):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(text, bytes):
            path.write_bytes(text)
        else:
            path.write_text(text, encoding="utf-8")
        if track:
            subprocess.run(["git", "-C", str(self.root), "add", name], check=True)


class CheckHomePathsTests(unittest.TestCase):
    def test_placeholder_home_folders_pass(self):
        repository = Repository(self)
        repository.add("tests/a.swift", "\n".join(
            f'let path = "{USERS}{name}/Library"' for name in
            ("someone", "someone-made-up", "example", "standin", "made-up", "Shared")))
        repository.add("docs/b.md", f"Run it as {HOME}example/bin, or {USERS}<name>/bin.\n")
        code, output = check(repository.root)
        self.assertEqual(code, 0, output)

    def test_a_real_looking_home_folder_fails_with_its_file_and_line(self):
        repository = Repository(self)
        repository.add("scripts/run.sh", "#!/bin/sh\n" f'export DOCKER_HOST="unix://{USERS}jdoe/.docker/run/docker.sock"\n')
        code, output = check(repository.root)
        self.assertEqual(code, 1, output)
        self.assertIn("scripts/run.sh:2", output)
        self.assertIn("home folder", output)

    def test_a_linux_home_folder_fails_too(self):
        repository = Repository(self)
        repository.add("ci.yml", f"path: {HOME}runner-person/work\n")
        code, output = check(repository.root)
        self.assertEqual(code, 1, output)
        self.assertIn("ci.yml:1", output)

    def test_a_path_inside_a_web_address_is_not_a_home_folder(self):
        repository = Repository(self)
        repository.add("notes.md", f"See https://example.com{HOME}20240917/page.\n")
        code, output = check(repository.root)
        self.assertEqual(code, 0, output)

    def test_an_untracked_file_and_a_binary_file_are_not_read(self):
        repository = Repository(self)
        repository.add("scratch.txt", f"{USERS}jdoe/x\n", track=False)
        repository.add("image.png", b"\x89PNG\r\n\x1a\n\xff\xfe" + f"{USERS}jdoe/x".encode())
        code, output = check(repository.root)
        self.assertEqual(code, 0, output)

    def test_the_repository_passes(self):
        code, output = check(ROOT)
        self.assertEqual(code, 0, output)


if __name__ == "__main__":
    unittest.main()
