#!/usr/bin/env python3
"""Start the isolated consumer and Stripe CLI without printing credentials."""
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

HERE = Path(__file__).resolve().parent
EVIDENCE = Path(os.environ.get("ASH_BILLING_EVIDENCE_DIR", str(HERE.parents[1] / "audit" / "stripe_validation")))
SECRET = re.compile(r"(?:sk|rk)_(?:test|live)_[A-Za-z0-9]+|whsec_[A-Za-z0-9]+")


def test_key():
    for name in ("STRIPE_SECRET_KEY", "STRIPE_API_KEY"):
        value = os.environ.get(name)
        if value:
            if not value.startswith("sk_test_"):
                raise RuntimeError("Only sk_test_ credentials are permitted")
            return value
    config = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "stripe" / "config.toml"
    if config.exists():
        section = re.search(r"^\[default\]\s*\n(.*?)(?=^\[|\Z)", config.read_text(), re.M | re.S)
        if section:
            keys = re.findall(r"^\w+\s*=\s*[\"'](sk_test_[^\"']+)[\"']", section.group(1), re.M)
            if keys:
                return keys[0]
    raise RuntimeError("Missing sk_test_ key in environment or default Stripe CLI profile")


def preflight(key):
    request = urllib.request.Request("https://api.stripe.com/v1/balance", headers={"Authorization": "Bearer " + key})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError("Test credential verification failed (HTTP %s)" % error.code) from None
    if result.get("livemode") is not False:
        raise RuntimeError("Stripe did not confirm livemode=false")


def capture(process, filename, signing_secret=None):
    with filename.open("a") as log:
        for raw in iter(process.stdout.readline, b""):
            line = raw.decode("utf-8", "replace")
            if signing_secret is not None:
                match = re.search(r"whsec_[A-Za-z0-9]+", line)
                if match:
                    signing_secret.put(match.group())
            log.write(SECRET.sub("[REDACTED]", line))
            log.flush()


def main():
    key = test_key()
    preflight(key)
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    if "--preflight" in sys.argv:
        print(json.dumps({"status": "PASS", "livemode": False}))
        return
    children = []
    try:
        environment = {**os.environ, "STRIPE_API_KEY": key, "STRIPE_SECRET_KEY": key, "STRIPE_NO_AUTO_UPDATE": "1",
                       "ASH_BILLING_TEST_STATE": str(EVIDENCE / "state.json")}
        listener = subprocess.Popen(["stripe", "listen", "--forward-to", "http://127.0.0.1:4089/webhooks/stripe",
            "--events", "checkout.session.completed,checkout.session.async_payment_succeeded,checkout.session.async_payment_failed,customer.subscription.created,customer.subscription.updated,customer.subscription.deleted"],
            env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        children.append(listener)
        secrets = queue.Queue()
        threading.Thread(target=capture, args=(listener, EVIDENCE / "listener.log", secrets), daemon=True).start()
        environment["STRIPE_WEBHOOK_SECRET"] = secrets.get(timeout=60)
        for operation in (["mix", "ecto.create"], ["mix", "ecto.migrate"]):
            result = subprocess.run(operation, cwd=HERE, env=environment,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            (EVIDENCE / (operation[-1] + ".log")).write_text(
                SECRET.sub("[REDACTED]", result.stdout.decode("utf-8", "replace")))
            if result.returncode:
                raise RuntimeError("Consumer database preparation failed; inspect local evidence")
        server = subprocess.Popen(["mix", "run", "--no-halt"], cwd=HERE, env=environment,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        children.append(server)
        threading.Thread(target=capture, args=(server, EVIDENCE / "consumer.log"), daemon=True).start()
        deadline = time.monotonic() + 60
        while True:
            if server.poll() is not None:
                raise RuntimeError("Consumer exited; inspect local evidence")
            try:
                with urllib.request.urlopen("http://127.0.0.1:4089/health", timeout=2) as response:
                    if json.load(response).get("mode") == "test":
                        break
            except (OSError, ValueError):
                if time.monotonic() >= deadline:
                    raise RuntimeError("Consumer readiness timed out") from None
                time.sleep(0.2)
        print(json.dumps({"status": "READY", "livemode": False, "endpoint": "http://127.0.0.1:4089", "secrets_logged": False}), flush=True)
        while server.poll() is None and listener.poll() is None:
            time.sleep(1)
        raise RuntimeError("Consumer or listener stopped unexpectedly")
    finally:
        for process in reversed(children):
            process.terminate()
        for process in reversed(children):
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except (RuntimeError, queue.Empty):
        print(json.dumps({"status": "BLOCKED", "reason": "Test setup failed; inspect redacted local evidence or missing test configuration"}), flush=True)
        sys.exit(1)
