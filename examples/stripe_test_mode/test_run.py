"""Offline safety checks; no Stripe credentials or network access required."""
import importlib.util
import io
import json
import os
from pathlib import Path
import queue
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("stripe_test_launcher", Path(__file__).with_name("run.py"))
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)


class TestLauncherSafety(unittest.TestCase):
    def test_test_key_is_accepted(self):
        with mock.patch.dict(os.environ, {"STRIPE_SECRET_KEY": "sk_test_fixture"}, clear=True):
            self.assertEqual(launcher.test_key(), "sk_test_fixture")

    def test_live_key_is_rejected_without_falling_back(self):
        with mock.patch.dict(os.environ, {"STRIPE_SECRET_KEY": "sk_live_fixture", "STRIPE_API_KEY": "sk_test_fixture"}, clear=True):
            with self.assertRaises(RuntimeError):
                launcher.test_key()

    def test_unknown_key_is_rejected(self):
        with mock.patch.dict(os.environ, {"STRIPE_SECRET_KEY": "unknown"}, clear=True):
            with self.assertRaises(RuntimeError):
                launcher.test_key()

    def test_missing_key_is_blocked(self):
        with tempfile.TemporaryDirectory() as config:
            with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": config}, clear=True):
                with self.assertRaises(RuntimeError):
                    launcher.test_key()

    def test_preflight_requires_explicit_false_livemode(self):
        for value in (True, None, "false"):
            response = mock.MagicMock()
            response.__enter__.return_value = io.StringIO(json.dumps({"livemode": value}))
            with mock.patch.object(launcher.urllib.request, "urlopen", return_value=response):
                with self.assertRaises(RuntimeError):
                    launcher.preflight("sk_test_fixture")

    def test_preflight_accepts_false_livemode(self):
        response = mock.MagicMock()
        response.__enter__.return_value = io.StringIO('{"livemode": false}')
        with mock.patch.object(launcher.urllib.request, "urlopen", return_value=response):
            launcher.preflight("sk_test_fixture")

    def test_log_capture_redacts_credentials_and_keeps_secret_in_memory(self):
        process = mock.MagicMock()
        process.stdout = io.BytesIO(b"sk_test_fixture rk_live_fixture whsec_fixture\n")
        secret = queue.Queue()
        with tempfile.TemporaryDirectory() as output:
            log = Path(output) / "listener.log"
            launcher.capture(process, log, secret)
            self.assertEqual(log.read_text(), "[REDACTED] [REDACTED] [REDACTED]\n")
            self.assertEqual(secret.get_nowait(), "whsec_fixture")


if __name__ == "__main__":
    unittest.main()
