"""Test release control flow only; no credentials, signing, or Apple submission."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NotarizationTests(unittest.TestCase):
    def run_release(self, status="Accepted", gatekeeper_failure=False, missing_key=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            shutil.copy(ROOT / "scripts/notarize.sh", root / "scripts/notarize.sh")
            bundle = root / "MacMCPControl.app/Contents/Resources/MacMCPControl_MacMCPControl.bundle/Contents/Resources"
            bundle.mkdir(parents=True)
            (bundle / "ngrok").write_bytes(b"test-only")
            bindir = root / "bin"
            bindir.mkdir()
            log = root / "commands"
            stub = '''#!/bin/bash
set -eu
name="${0##*/}"
printf '%s %s\\n' "$name" "$*" >> "$TEST_COMMAND_LOG"
case "$name" in
  xcrun)
    if [[ "$1 $2" == "notarytool submit" ]]; then
      printf '{"id":"test-id","status":"%s"}\\n' "$TEST_NOTARY_STATUS"
    fi ;;
  spctl) if [[ "$TEST_GATEKEEPER_FAILURE" == 1 ]]; then exit 1; fi ;;
esac
'''
            for name in ["codesign", "ditto", "xcrun", "spctl", "tar"]:
                path = bindir / name
                path.write_text(stub)
                path.chmod(0o755)
            env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}",
                       TEST_COMMAND_LOG=str(log), TEST_NOTARY_STATUS=status,
                       TEST_GATEKEEPER_FAILURE=str(int(gatekeeper_failure)),
                       APPLE_SIGNING_IDENTITY="test-only", APP_STORE_CONNECT_API_KEY_BASE64="dGVzdA==",
                       APP_STORE_CONNECT_KEY_ID="test-only", APP_STORE_CONNECT_ISSUER_ID="test-only")
            if missing_key:
                env.pop("APP_STORE_CONNECT_API_KEY_BASE64")
            result = subprocess.run(["bash", str(root / "scripts/notarize.sh")], env=env, text=True, capture_output=True)
            commands = log.read_text() if log.exists() else ""
            return result, commands

    def test_success_staples_before_archiving_and_checks_extracted_zip(self):
        result, commands = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(commands.index("stapler staple"), commands.index("tar -czf"))
        self.assertEqual(commands.count("spctl --assess"), 2)
        self.assertIn("extracted/MacMCPControl.app", commands)

    def test_rejected_submission_never_archives(self):
        result, commands = self.run_release(status="Invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("notarytool log", commands)
        self.assertNotIn("stapler staple", commands)
        self.assertNotIn("tar -czf", commands)

    def test_gatekeeper_rejection_never_archives(self):
        result, commands = self.run_release(gatekeeper_failure=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("tar -czf", commands)

    def test_missing_credentials_fail_before_signing(self):
        result, commands = self.run_release(missing_key=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(commands, "")
