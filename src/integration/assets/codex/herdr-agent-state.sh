#!/bin/sh
# installed by herdr
# managed by herdr; reinstalling or updating the integration overwrites this file.
# add custom hooks beside this file instead of editing it.
# HERDR_INTEGRATION_ID=codex
# HERDR_INTEGRATION_VERSION=8
set -eu
action="${1:-}"
hook_input_file="$(mktemp "${TMPDIR:-/tmp}/herdr-codex-hook.XXXXXX")" || exit 0
trap 'rm -f "$hook_input_file"' EXIT HUP INT TERM
cat >"$hook_input_file" 2>/dev/null || true
case "$action" in
  session|title) ;;
  *) exit 0 ;;
esac
[ "${HERDR_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_SOCKET_PATH:-}" ] || exit 0
[ -n "${HERDR_PANE_ID:-}" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
HERDR_ACTION="$action" HERDR_HOOK_INPUT_FILE="$hook_input_file" python3 - <<'PY'
import json
import os
import random
import re
import socket
import time

source = "herdr:codex"
action = os.environ.get("HERDR_ACTION", "")
pane_id = os.environ.get("HERDR_PANE_ID")
socket_path = os.environ.get("HERDR_SOCKET_PATH")
hook_input_file = os.environ.get("HERDR_HOOK_INPUT_FILE")
if not pane_id or not socket_path:
    raise SystemExit(0)

hook_input = {}
if hook_input_file:
    try:
        with open(hook_input_file, encoding="utf-8") as handle:
            content = handle.read()
        if content.strip():
            hook_input = json.loads(content)
    except Exception:
        hook_input = {}

hook_event_name = str(hook_input.get("hook_event_name") or "")
request_id = f"{source}:{int(time.time() * 1000)}:{random.randrange(1_000_000):06d}"
report_seq = time.time_ns()
session_id = hook_input.get("session_id")
agent_session_id = session_id if isinstance(session_id, str) and session_id else None


def send(method, params):
    request = {"id": request_id, "method": method, "params": params}
    try:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(0.5)
        client.connect(socket_path)
        client.sendall((json.dumps(request) + "\n").encode())
        try:
            client.recv(4096)
        except Exception:
            pass
        client.close()
    except Exception:
        pass


def collapse_ws(text):
    return re.sub(r"\s+", " ", text).strip()


def summarize_title(prompt):
    if not isinstance(prompt, str):
        return None
    text = None
    for raw in prompt.splitlines():
        line = collapse_ws(raw)
        if not line:
            continue
        if line.startswith("#") or line.startswith("//") or line.startswith("```"):
            continue
        text = line
        break
    if text is None:
        text = collapse_ws(prompt)
    if not text:
        return None
    text = re.sub(r"^/[A-Za-z0-9_-]+\s+", "", text)
    text = collapse_ws(text)
    if not text:
        return None
    max_len = 72
    if len(text) <= max_len:
        return text
    slice_ = text[: max_len - 1]
    cut = max(slice_.rfind(" "), slice_.rfind("/"), slice_.rfind("-"))
    base = slice_[:cut] if cut >= 24 else slice_
    return base.rstrip() + "…"



def title_state_path(session_key):
    # Small state file keyed by pane+session so we 1) skip heuristic after first
    # prompt and 2) respect native/manual titles without thrashing later prompts.
    base = os.environ.get("HERDR_RUNTIME_DIR") or os.environ.get("XDG_RUNTIME_DIR") or os.environ.get("TMPDIR") or "/tmp"
    safe_pane = re.sub(r"[^A-Za-z0-9._-]+", "_", pane_id)[:80]
    safe_session = re.sub(r"[^A-Za-z0-9._-]+", "_", session_key or "unknown")[:80]
    directory = os.path.join(base, "herdr-integration-title-state")
    try:
        os.makedirs(directory, mode=0o700, exist_ok=True)
    except Exception:
        return None
    return os.path.join(directory, f"{safe_pane}__{safe_session}.flag")

def heuristic_title_already_reported(session_key):
    path = title_state_path(session_key)
    if not path:
        return False
    return os.path.exists(path)

def mark_heuristic_title_reported(session_key):
    path = title_state_path(session_key)
    if not path:
        return
    try:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("1\n")
    except Exception:
        pass

def clear_heuristic_title_state(session_key):
    path = title_state_path(session_key)
    if not path:
        return
    try:
        os.remove(path)
    except FileNotFoundError:
        pass
    except Exception:
        pass

if action == "session":
    if hook_event_name and hook_event_name != "SessionStart":
        raise SystemExit(0)
    if not agent_session_id:
        raise SystemExit(0)
    session_start_source = (
        hook_input.get("source") if hook_event_name == "SessionStart" else None
    )
    if not isinstance(session_start_source, str) or not session_start_source:
        session_start_source = None
    params = {
        "pane_id": pane_id,
        "source": source,
        "agent": "codex",
        "seq": report_seq,
        "agent_session_id": agent_session_id,
    }
    if session_start_source:
        params["session_start_source"] = session_start_source
    send("pane.report_agent_session", params)
    clear_params = {
        "pane_id": pane_id,
        "source": source,
        "agent": "codex",
        "seq": report_seq + 1,
        "clear_title": True,
        "agent_session_id": agent_session_id,
    }
    send("pane.report_metadata", clear_params)
elif action == "title":
    if hook_event_name not in ("UserPromptSubmit",):
        raise SystemExit(0)
    # Once per session only — prefer existing harness/chat names over later prompts.
    if heuristic_title_already_reported(agent_session_id):
        raise SystemExit(0)
    title = summarize_title(hook_input.get("prompt"))
    if not title:
        raise SystemExit(0)
    params = {
        "pane_id": pane_id,
        "source": source,
        "agent": "codex",
        "seq": report_seq,
        "title": title,
    }
    if agent_session_id:
        params["agent_session_id"] = agent_session_id
    send("pane.report_metadata", params)
    mark_heuristic_title_reported(agent_session_id)
else:
    raise SystemExit(0)
PY
