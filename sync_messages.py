#!/usr/bin/env python3
"""
sync_messages.py — keep this NUC's copy of the gate-monitor announcements in
step with the website.

Every 30 seconds it asks the website for the current list
(GET /edge/display-messages, authenticated with the NUC key). When the list has
changed it rewrites messages.js, which welcome.html reads before each board
slide. If the website can't be reached, the last list stays on screen.
signage_controller.sh starts it and restarts it if it ever stops.

    python3 sync_messages.py          run continuously
    python3 sync_messages.py --once   fetch once, print the result, exit (testing)

The website address and key live in signage.secrets in this folder (created by
setup_nuc_display.sh, readable only by this user).
"""

import argparse
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path
from urllib.parse import urlsplit

HERE = Path(__file__).resolve().parent
SECRETS_FILE = HERE / "signage.secrets"
MESSAGES_FILE = HERE / "messages.js"
LOG_FILE = HERE / "sync.log"

INTERVAL_SECONDS = 30
TIMEOUT_SECONDS = 10
MAX_RESPONSE_BYTES = 256 * 1024
LOG_MAX_BYTES = 256 * 1024
# The website already enforces these; capped again so a bad response can't
# overflow the board.
MAX_MESSAGES = 8
MAX_CHARS = 150


class SyncError(Exception):
    pass


def log(message):
    try:
        if LOG_FILE.exists() and LOG_FILE.stat().st_size > LOG_MAX_BYTES:
            lines = LOG_FILE.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
            LOG_FILE.write_text("".join(lines[-500:]), encoding="utf-8")
        with LOG_FILE.open("a", encoding="utf-8") as fh:
            fh.write(f"{datetime.now():%Y-%m-%d %H:%M:%S} {message}\n")
    except OSError:
        pass


def read_secrets(path=SECRETS_FILE):
    """Return (api_url, edge_key) from KEY="value" lines, without executing the file."""
    values = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    api_url = values.get("API_URL", "").rstrip("/")
    edge_key = values.get("EDGE_KEY", "")
    parts = urlsplit(api_url)
    if parts.scheme not in ("http", "https") or not parts.netloc:
        raise SyncError(f"API_URL in {path.name} must look like https://your-backend-address")
    if not edge_key:
        raise SyncError(f"EDGE_KEY is missing from {path.name}")
    return api_url, edge_key


def parse_response(data):
    """Validate the website's reply; return (version, [message text, ...])."""
    if (not isinstance(data, dict) or not isinstance(data.get("version"), str)
            or not isinstance(data.get("messages"), list)):
        raise SyncError("unexpected response from the website")
    messages = []
    for item in data["messages"][:MAX_MESSAGES]:
        if not isinstance(item, dict) or not isinstance(item.get("text"), str):
            raise SyncError("unexpected message format from the website")
        text = " ".join(item["text"].split())[:MAX_CHARS]
        if text:
            messages.append(text)
    return data["version"], messages


def fetch(api_url, edge_key):
    request = urllib.request.Request(
        f"{api_url}/edge/display-messages",
        headers={"X-Edge-Key": edge_key, "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            body = response.read(MAX_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            raise SyncError("the website rejected the NUC key (HTTP 401); check EDGE_KEY") from exc
        raise SyncError(f"the website returned HTTP {exc.code}") from exc
    except (urllib.error.URLError, OSError) as exc:
        reason = getattr(exc, "reason", exc)
        raise SyncError(f"cannot reach the website ({reason})") from exc
    if len(body) > MAX_RESPONSE_BYTES:
        raise SyncError("the website's response was too large")
    try:
        data = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SyncError("the website's response was not valid JSON") from exc
    return parse_response(data)


def write_messages(version, messages, path=MESSAGES_FILE):
    """Atomically replace messages.js so the page never reads a half-written file."""
    # ensure_ascii escapes every non-ASCII character (incl. U+2028/U+2029),
    # so the JSON is always a valid JavaScript literal.
    payload = json.dumps({"version": version, "messages": messages})
    fd, tmp_path = tempfile.mkstemp(dir=path.parent, prefix=".messages-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(f"window.RVNL_MESSAGES = {payload};\n")
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def saved_version(path=MESSAGES_FILE):
    """Version currently on disk, so a restart doesn't rewrite an unchanged file."""
    try:
        text = path.read_text(encoding="utf-8")
        return json.loads(text[text.index("{"):text.rindex("}") + 1]).get("version")
    except (OSError, ValueError):
        return None


def acquire_single_instance_lock():
    import fcntl  # Linux-only; imported here so the rest stays testable elsewhere
    lock_dir = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    handle = open(os.path.join(lock_dir, "rvnl-signage-sync.lock"), "w")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        return None
    return handle


def run_forever(api_url, edge_key):
    if api_url.startswith("http://"):
        log("WARNING: API_URL uses http://, so the NUC key is sent unencrypted. "
            "Use https:// outside local testing.")
    log("Announcements sync started")
    last_version = saved_version()
    last_problem = None
    while True:
        try:
            version, messages = fetch(api_url, edge_key)
            if version != last_version or not MESSAGES_FILE.exists():
                write_messages(version, messages)
                log(f"Board updated: {len(messages)} message(s)")
                last_version = version
            if last_problem:
                log("Website reachable again")
                last_problem = None
        except (SyncError, OSError) as exc:
            problem = str(exc)
            if problem != last_problem:
                log(f"Sync failed, keeping the last messages on screen: {problem}")
                last_problem = problem
        time.sleep(INTERVAL_SECONDS)


def main():
    parser = argparse.ArgumentParser(description="Sync gate-monitor announcements")
    parser.add_argument("--once", action="store_true",
                        help="fetch once, print the result and exit")
    args = parser.parse_args()

    try:
        api_url, edge_key = read_secrets()
    except FileNotFoundError:
        print(f"Not configured: {SECRETS_FILE.name} is missing. Run setup_nuc_display.sh.")
        return 2
    except SyncError as exc:
        print(f"Configuration problem: {exc}")
        return 2

    if args.once:
        try:
            version, messages = fetch(api_url, edge_key)
            write_messages(version, messages)
        except (SyncError, OSError) as exc:
            print(f"FAILED: {exc}")
            return 1
        print(f"OK: {len(messages)} message(s) on the board (version {version})")
        for text in messages:
            print(f"  - {text}")
        return 0

    lock = acquire_single_instance_lock()
    if lock is None:
        print("The announcements sync is already running.")
        return 0
    try:
        run_forever(api_url, edge_key)
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
