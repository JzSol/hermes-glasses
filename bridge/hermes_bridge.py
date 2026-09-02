#!/usr/bin/env python3
"""
Hermes Glasses Bridge - WebSocket server connecting the Hermes Glasses iOS
app to a Hermes Agent. The phone performs low-power wake detection and sends
the captured utterance to Hermes for final STT, agent reasoning, and TTS.

Protocol (JSON text frames):
  app → bridge: {"type":"audio_start","request_id":...,
                 "format":"pcm_s16le","sample_rate":16000,"channels":1,
                 "locale":"en-GB"|"lv-LV","follow_up":bool}
                                                  begin captured utterance
  app → bridge: binary PCM16 frames, then {"type":"audio_end",...}
  app → bridge: {"type":"query","text":...}   legacy text client
  app → bridge: {"type":"new_session"}           forget the conversation
  app → bridge: {"type":"cancel_turn","request_id":...} stop the active turn
  app → bridge: {"type":"photo","data":<b64>}    reply to capture_photo
  app → bridge: {"type":"photo_error", ...}
  bridge → app: {"type":"welcome","capabilities":{"vision":bool,
                "turn_cancel":bool}} /
                {"type":"capture_photo"} /
                {"type":"response","text":...,"request_id":...} /
                {"type":"follow_up_ended","request_id":...} /
                {"type":"session_reset"} /
                transcript / response deltas / response +
                audio_start + binary PCM16 mono TTS + audio_end
"""

import asyncio
import base64
import contextlib
import datetime
import hmac
import io
import json
import os
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
import wave
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

# Load only the bridge-local .env before reading any configuration constants.
# Explicit process environment values win, which keeps launchd/terminal
# overrides deterministic while allowing a local bridge/.env for development.
BRIDGE_DIR = Path(__file__).resolve().parent
BRIDGE_ENV_FILE = BRIDGE_DIR / ".env"
try:
    from dotenv import load_dotenv
except ImportError:  # pragma: no cover - requirements.txt supplies this
    load_dotenv = None

if load_dotenv is not None:
    load_dotenv(dotenv_path=BRIDGE_ENV_FILE, override=False)

try:
    import websockets
except ImportError:
    print("Install websockets: pip install websockets")
    sys.exit(1)

# ── Configuration ──────────────────────────────────────────────────────────
HOST = os.environ.get("HERMES_BRIDGE_HOST", "0.0.0.0")
PORT = int(os.environ.get("HERMES_BRIDGE_PORT", "8765"))
HERMES_BIN = os.environ.get(
    "HERMES_BIN",
    os.path.expanduser("~/.hermes/hermes-agent/.venv/bin/hermes"),
)

# Shared-secret auth. This is required at startup - Hermes has tool access, so
# an open bridge is remote code execution for anyone who finds the port.
AUTH_TOKEN = os.environ.get("HERMES_BRIDGE_TOKEN", "").strip()

# Exact, allowlisted access-control route. Both open and close pulse the same
# configured dry-contact relay; the model never selects an actuator.
GATE_ENTITY = os.environ.get("HERMES_BRIDGE_GATE_ENTITY", "").strip()
HASS_ENV_FILE = Path(os.environ.get(
    "HERMES_BRIDGE_HASS_ENV_FILE", "~/.hermes/.env"
)).expanduser()


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _env_int(name: str, default: int, minimum: int = 1) -> int:
    try:
        value = int(os.environ.get(name, str(default)))
    except (TypeError, ValueError):
        return default
    return max(minimum, value)


def _env_float(name: str, default: float, minimum: float = 0.0) -> float:
    try:
        value = float(os.environ.get(name, str(default)))
    except (TypeError, ValueError):
        return default
    return max(minimum, value)


GATE_COOLDOWN_SECONDS = _env_float(
    "HERMES_BRIDGE_GATE_COOLDOWN_SECONDS", 5.0
)
_GATE_ENTITY_RE = re.compile(r"^switch\.[a-z0-9_]+$")
_gate_lock = threading.Lock()
_gate_last_accepted_at = 0.0


# Vision remains available by default for existing clients. Adam's voice-only
# prototype sets this to false to return a local capability response without
# asking the phone to capture a photo.
BRIDGE_VISION = _env_bool("HERMES_BRIDGE_VISION", True)

# Hermes invocation bounds. The workdir intentionally defaults to the process
# cwd instead of a personal path; set HERMES_BRIDGE_WORKDIR in bridge/.env for
# a stable launchd setup.
BRIDGE_WORKDIR = os.environ.get("HERMES_BRIDGE_WORKDIR") or os.getcwd()
HERMES_MAX_TURNS = _env_int("HERMES_BRIDGE_MAX_TURNS", 20)
HERMES_RUN_BUDGET = _env_int("HERMES_BRIDGE_RUN_BUDGET", 90)

# Hermes's local dashboard API is the low-latency path for Adam.  It keeps one
# agent session alive, runs final STT with Hermes's configured provider, and
# streams the configured TTS provider as raw PCM. Adam recommends the optional
# MLX Whisper provider on Apple silicon with faster-whisper as its fallback.
HERMES_API_BASE = os.environ.get(
    "HERMES_BRIDGE_API_BASE", "http://127.0.0.1:9119"
).rstrip("/")
HERMES_PRIVATE_BACKEND = os.environ.get(
    "HERMES_BRIDGE_PRIVATE_BACKEND", "auto"
).strip().lower()
HERMES_PREWARM = _env_bool("HERMES_BRIDGE_PREWARM", True)
HERMES_PRIVATE_PYTHON = os.environ.get(
    "HERMES_BRIDGE_PRIVATE_PYTHON",
    str(Path(os.path.abspath(os.path.expanduser(HERMES_BIN))).parent / "python"),
)
HERMES_AUDIO_SAMPLE_RATE = 16_000
HERMES_AUDIO_CHANNELS = 1
HERMES_AUDIO_FORMAT = "pcm_s16le"
HERMES_AUDIO_MAX_SECONDS = _env_int("HERMES_BRIDGE_AUDIO_MAX_SECONDS", 30)
HERMES_AUDIO_MAX_BYTES = (
    HERMES_AUDIO_SAMPLE_RATE * HERMES_AUDIO_CHANNELS * 2
    * HERMES_AUDIO_MAX_SECONDS
)
HERMES_STT_PROMPT = (
    "Adam, Donzo, Hermes, Janis, Ray-Ban Meta, Tailscale. Preserve names, product "
    "terms, and punctuation exactly."
)

# Per-session voice profile. These overrides keep spoken turns responsive
# without changing the user's global Hermes model. If an override cannot run,
# HermesGateway retries once with the user's inherited profile settings.
HERMES_AGENT_PROVIDER = os.environ.get(
    "HERMES_BRIDGE_AGENT_PROVIDER", "openai-codex"
).strip()
HERMES_AGENT_MODEL = os.environ.get(
    "HERMES_BRIDGE_AGENT_MODEL", "gpt-5.4-mini"
).strip()
HERMES_AGENT_REASONING_EFFORT = os.environ.get(
    "HERMES_BRIDGE_AGENT_REASONING_EFFORT", "low"
).strip()
HERMES_AGENT_FAST = _env_bool("HERMES_BRIDGE_AGENT_FAST", True)


def voice_session_profile_signature() -> str:
    """Stable, non-secret identity for the persisted Adam voice profile."""
    return json.dumps({
        "version": 1,
        "provider": HERMES_AGENT_PROVIDER,
        "model": HERMES_AGENT_MODEL,
        "reasoning_effort": HERMES_AGENT_REASONING_EFFORT,
        "fast": HERMES_AGENT_FAST,
    }, sort_keys=True, separators=(",", ":"))

# Bridge-side TTS (edge-tts/say → PCM streaming). Default OFF: the app
# speaks replies on-device with AVSpeechSynthesizer. Set HERMES_BRIDGE_TTS=1
# to fall back to server TTS for clients that can't speak locally.
BRIDGE_TTS = os.environ.get("HERMES_BRIDGE_TTS", "") == "1"
STREAM_TTS_PROVIDER = os.environ.get(
    "HERMES_BRIDGE_STREAM_TTS_PROVIDER", ""
).strip() or None
STREAM_TTS_VOICE = os.environ.get(
    "HERMES_BRIDGE_STREAM_TTS_VOICE", ""
).strip() or None

# Which brain answers queries:
#   "hermes" (default) - spawn the hermes CLI per query (agent with tools;
#                        slower: pays agent boot every question)
#   "claude"           - call the Claude API directly (fast conversational
#                        answers + vision; needs ANTHROPIC_API_KEY)
#   "anthropic" / "openai" / "gemini" - call the provider's HTTP API
#                        directly (fast conversational answers + vision;
#                        needs the matching *_API_KEY). "claude" is kept as
#                        an alias for "anthropic" (back-compat).
BRAIN = os.environ.get("HERMES_BRIDGE_BRAIN", "hermes")
CLAUDE_MODEL = os.environ.get("HERMES_BRIDGE_MODEL", "claude-opus-4-8")

# ── Provider brains (direct API, BRAIN="anthropic"|"openai"|"gemini") ──────
BASE_URLS = {
    "anthropic": "https://api.anthropic.com",
    "openai": "https://api.openai.com",
    "gemini": "https://generativelanguage.googleapis.com",
}
PROVIDER_API_KEY_ENV = {
    "anthropic": "ANTHROPIC_API_KEY",
    "openai": "OPENAI_API_KEY",
    "gemini": "GEMINI_API_KEY",
}


# ── Deterministic gate relay ──────────────────────────────────────────────

_GATE_COMMANDS = {
    "open gate": "open",
    "open the gate": "open",
    "open gates": "open",
    "open the gates": "open",
    "close gate": "close",
    "close the gate": "close",
    "close gates": "close",
    "close the gates": "close",
}


def detect_gate_action(text: str) -> str | None:
    """Return open/close only for a complete canonical gate utterance."""
    command = re.sub(
        r"^\s*\[Context:[^\r\n]*\]\s*", "", text, count=1,
        flags=re.IGNORECASE,
    )
    command = re.sub(r"[?!.,'\"’]+", " ", command.lower())
    command = " ".join(command.split())
    fillers = ("hey", "ok", "okay", "hermes", "adam", "please")
    while True:
        matched = next(
            (filler for filler in fillers if command.startswith(filler + " ")),
            None,
        )
        if not matched:
            break
        command = command[len(matched) + 1:]
    return _GATE_COMMANDS.get(command)


def _env_file_values(path: Path) -> dict[str, str]:
    """Parse simple KEY=VALUE secret files without executing shell code."""
    values = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return values
    for raw_line in lines:
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        name, separator, value = line.partition("=")
        name = name.strip()
        if not separator or not re.fullmatch(
            r"[A-Za-z_][A-Za-z0-9_]*", name
        ):
            continue
        value = value.strip()
        if (
            len(value) >= 2
            and value[0] == value[-1]
            and value[0] in ("'", '"')
        ):
            value = value[1:-1]
        values[name] = value
    return values


def _home_assistant_config() -> tuple[str, str]:
    """Resolve Home Assistant credentials without logging either value."""
    file_values = _env_file_values(HASS_ENV_FILE)
    url = (
        os.environ.get("HERMES_BRIDGE_HASS_URL", "").strip()
        or os.environ.get("HASS_URL", "").strip()
        or file_values.get("HASS_URL", "").strip()
    )
    token = (
        os.environ.get("HERMES_BRIDGE_HASS_TOKEN", "").strip()
        or os.environ.get("HASS_TOKEN", "").strip()
        or file_values.get("HASS_TOKEN", "").strip()
    )
    return url.rstrip("/"), token


def activate_gate_relay(action: str) -> tuple[bool, str]:
    """Pulse the configured Ajax relay through Home Assistant once."""
    global _gate_last_accepted_at

    if action not in {"open", "close"}:
        return False, "Gate relay command rejected."
    if not AUTH_TOKEN:
        return False, "Gate control requires an authenticated bridge."
    if not _GATE_ENTITY_RE.fullmatch(GATE_ENTITY):
        return False, "Gate relay is not configured on this bridge."

    hass_url, hass_token = _home_assistant_config()
    parsed = urllib.parse.urlsplit(hass_url)
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.netloc
        or not hass_token
    ):
        return False, "Home Assistant gate control is not configured."

    with _gate_lock:
        now = time.monotonic()
        if (
            _gate_last_accepted_at > 0
            and now - _gate_last_accepted_at < GATE_COOLDOWN_SECONDS
        ):
            return True, "A gate relay command was already accepted moments ago."

        headers = {
            "Authorization": "Bearer " + hass_token,
            "Content-Type": "application/json",
        }
        state_request = urllib.request.Request(
            hass_url + "/api/states/" + GATE_ENTITY,
            headers=headers,
            method="GET",
        )
        pulse_request = urllib.request.Request(
            hass_url + "/api/services/switch/turn_on",
            data=json.dumps({"entity_id": GATE_ENTITY}).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        try:
            with urllib.request.urlopen(state_request, timeout=10) as response:
                state_body = response.read()
                state_status = getattr(response, "status", 200)
            if not 200 <= state_status < 300:
                raise RuntimeError("unexpected Home Assistant state status")
            state_payload = json.loads(state_body.decode("utf-8"))
            if not isinstance(state_payload, dict):
                raise ValueError("unexpected Home Assistant state response")
            if state_payload.get("state") in {"unavailable", "unknown", None}:
                return False, "Gate relay is unavailable; no activation was sent."

            with urllib.request.urlopen(pulse_request, timeout=10) as response:
                response.read()
                pulse_status = getattr(response, "status", 200)
            if not 200 <= pulse_status < 300:
                raise RuntimeError("unexpected Home Assistant pulse status")
        except (
            urllib.error.HTTPError,
            urllib.error.URLError,
            TimeoutError,
            OSError,
            ValueError,
            RuntimeError,
        ) as error:
            print(
                "[Gate] Home Assistant relay activation failed "
                f"({type(error).__name__})"
            )
            return False, (
                "Gate relay activation failed; Home Assistant did not accept it."
            )

        _gate_last_accepted_at = now
        print(f"[Gate] {action} command accepted for the allowlisted relay")
        return True, "Gate relay activation command accepted."


def _canon_brain(brain: str) -> str:
    return "anthropic" if brain == "claude" else brain


def build_provider_request(
    brain: str, model: str, base_url: str, api_key: str, prompt: str,
    image_b64: str | None, system: str | None = None,
) -> tuple[str, dict, dict]:
    """Return (url, headers, body_dict) for a one-shot chat+vision request.

    `system` defaults to CLAUDE_SYSTEM (the voice persona: 1-3 spoken
    sentences) so provider-brain answers stay voice-optimized, same as the
    legacy ask_claude() path.
    """
    system = system if system is not None else CLAUDE_SYSTEM
    brain = _canon_brain(brain)
    headers = {"Content-Type": "application/json"}
    if brain == "anthropic":
        content = []
        if image_b64:
            content.append({"type": "image", "source": {
                "type": "base64", "media_type": "image/jpeg", "data": image_b64}})
        content.append({"type": "text", "text": prompt})
        headers["x-api-key"] = api_key
        headers["anthropic-version"] = "2023-06-01"
        body = {"model": model, "max_tokens": 1024, "system": system,
                "messages": [{"role": "user", "content": content}]}
        return base_url + "/v1/messages", headers, body
    if brain == "openai":
        if image_b64:
            content = [{"type": "text", "text": prompt},
                       {"type": "image_url", "image_url": {
                           "url": "data:image/jpeg;base64," + image_b64}}]
        else:
            content = prompt
        if api_key:
            headers["Authorization"] = "Bearer " + api_key
        body = {"model": model, "max_tokens": 1024,
                "messages": [{"role": "system", "content": system},
                             {"role": "user", "content": content}]}
        return base_url + "/v1/chat/completions", headers, body
    if brain == "gemini":
        parts = []
        if image_b64:
            parts.append({"inline_data": {"mime_type": "image/jpeg", "data": image_b64}})
        parts.append({"text": prompt})
        body = {"contents": [{"role": "user", "parts": parts}],
                "systemInstruction": {"parts": [{"text": system}]}}
        # The key travels in a header, never in the URL: query strings end up
        # in proxy logs, crash reports and error messages.
        if api_key:
            headers["x-goog-api-key"] = api_key
        url = "%s/v1beta/models/%s:generateContent" % (base_url, model)
        return url, headers, body
    raise ValueError("unknown brain: %s" % brain)


def parse_provider_reply(brain: str, status: int, body_bytes: bytes) -> str:
    brain = _canon_brain(brain)
    data = json.loads(body_bytes.decode("utf-8"))
    if status != 200:
        raise RuntimeError(data.get("error", {}).get("message", "API error %s" % status))
    if brain == "anthropic":
        return next(b["text"] for b in data["content"] if b.get("type") == "text")
    if brain == "openai":
        return data["choices"][0]["message"]["content"]
    if brain == "gemini":
        return data["candidates"][0]["content"]["parts"][0]["text"]
    raise ValueError("unknown brain: %s" % brain)


def ask_provider(
    brain: str,
    text: str,
    photo: bytes | None = None,
    locale: str | None = None,
) -> str:
    """Answer via a direct provider HTTP API (anthropic/openai/gemini).

    Stdlib-only (urllib), stateless single-turn request built with
    build_provider_request() and parsed with parse_provider_reply(). Unlike
    the legacy SDK-based ask_claude() below, this path carries no cross-turn
    history - each query is answered independently.
    """
    brain = _canon_brain(brain)
    base_url = os.environ.get("HERMES_BRIDGE_BASE_URL", BASE_URLS[brain])
    key_env = PROVIDER_API_KEY_ENV[brain]
    api_key = os.environ.get(key_env, "")
    if not api_key:
        return f"The {brain} brain needs an API key. Set {key_env} for the bridge."

    image_b64 = base64.b64encode(photo).decode() if photo else None
    url, headers, body = build_provider_request(
        brain, CLAUDE_MODEL, base_url, api_key, text, image_b64,
        system=adam_persona(locale or "en-GB"))

    request = urllib.request.Request(
        url, data=json.dumps(body).encode(), headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=30) as resp:
            status, body_bytes = resp.status, resp.read()
    except urllib.error.HTTPError as e:
        status, body_bytes = e.code, e.read()
    except urllib.error.URLError as e:
        print(f"[{brain}] Connection error: {e}")
        return f"Sorry, I couldn't reach the {brain} API."

    try:
        return parse_provider_reply(brain, status, body_bytes)
    except Exception as e:
        print(f"[{brain}] API error ({status}): {e}")
        return f"Sorry, the {brain} API returned an error."


# Utterances containing any of these ask about something the user sees;
# the bridge then requests a photo from the glasses. Phrases, not bare
# words: "picture" alone would fire on "why did you take a picture?"
VISUAL_KEYWORDS = [
    "look at", "looking at", "see this", "what am i seeing",
    "what is this", "what's this", "read this", "in front of me",
    "take a picture", "take a photo", "snap a photo", "use the camera",
    "through the camera",
]


def is_visual_query(text: str) -> bool:
    lowered = text.lower()
    return any(keyword in lowered for keyword in VISUAL_KEYWORDS)


# "this drink", "that building", "the one on the left" - references to
# something the user is (probably) looking at
DEICTIC_RE = re.compile(r"\b(this|that|these|those)\s+([a-z]+)|\bthe one\b",
                        re.IGNORECASE)


# "this morning", "that question" - deictic in grammar but not about
# anything visible. Nouns here never trigger a photo.
DEICTIC_STOP_NOUNS = {
    "morning", "afternoon", "evening", "night", "time", "day", "week",
    "month", "year", "moment", "question", "answer", "idea", "point",
    "case", "way", "reason", "sense", "stuff", "conversation", "chat",
    "session", "app", "voice", "sound", "response", "reply", "much",
    "long", "short", "many", "far", "fast", "slow", "bit", "lot", "kind",
    "sort", "type",
    # Auxiliary/copular verbs: "this is a test", "that was fun" are not
    # about anything visible
    "is", "was", "are", "were", "be", "being", "been", "isn", "wasn",
    "will", "would", "can", "could", "should", "might", "may", "must",
    "does", "did", "done", "has", "had", "have", "gets", "got", "goes",
    "went", "seems", "means", "works", "sounds", "feels", "happened",
}


# Deictic follow-up captures only when no photo was taken within this many
# seconds - within the window, conversation memory already knows what the
# user is looking at.
PHOTO_MEMORY_WINDOW_S = 120.0


def should_capture_photo(text: str, last_photo_at: float, now: float) -> bool:
    """Decide whether a query needs a fresh photo.

    Explicit visual keywords always capture. Deictic references ("this X")
    capture only for plausibly-visible nouns, and only when no photo was
    taken recently - within the window, conversation memory already knows
    what the user is looking at.
    """
    if is_visual_query(text):
        return True
    for match in DEICTIC_RE.finditer(text):
        noun = (match.group(2) or "").lower()
        if match.group(0).lower() == "the one" or (
            noun and noun not in DEICTIC_STOP_NOUNS
        ):
            return (now - last_photo_at) > PHOTO_MEMORY_WINDOW_S
    return False


# ── Adam voice persona and locale ──────────────────────────────────────────
SUPPORTED_LOCALES = {"en-GB", "en-US", "lv-LV"}
DEFAULT_LOCALE = "en-GB"
LOCALE_LANGUAGE_NAMES = {
    "en-GB": "British English",
    "en-US": "English",
    "lv-LV": "Latvian",
}


def sanitize_locale(locale: str | None) -> str:
    """Return a supported speech locale, falling back to English."""
    return (locale if isinstance(locale, str) and locale in SUPPORTED_LOCALES
            else DEFAULT_LOCALE)


def adam_persona(locale: str = DEFAULT_LOCALE) -> str:
    """Prompt prefix used on every turn so Adam honors locale changes."""
    language = LOCALE_LANGUAGE_NAMES[sanitize_locale(locale)]
    return (
        f"(You are Adam, a voice assistant running on smart glasses. "
        f"Your answers are spoken aloud, so keep them to 1-3 concise, "
        f"conversational sentences unless the user asks for detail. "
        f"Reply in {language} on this turn. The user may reference things "
        f"they see; photos may be attached to queries. Do not mention "
        f"codebases or files unless asked.) "
    )


VOICE_PERSONA = adam_persona()
VISION_DISABLED_RESPONSE = "Camera access is disabled."
VISION_DISABLED_RESPONSES = {
    "en-GB": VISION_DISABLED_RESPONSE,
    "en-US": VISION_DISABLED_RESPONSE,
    "lv-LV": "Kameras piekļuve ir atspējota.",
}


def vision_disabled_response(locale: str = DEFAULT_LOCALE) -> str:
    return VISION_DISABLED_RESPONSES[sanitize_locale(locale)]


def build_adam_query(text: str, locale: str = DEFAULT_LOCALE) -> str:
    """Prefix every agent turn with Adam's concise, selected-language rules."""
    return adam_persona(locale) + text


# ── Conversation memory (same-day Hermes session) ─────────────────────────
SESSION_FILE = os.path.expanduser(
    os.environ.get(
        "HERMES_BRIDGE_SESSION_FILE",
        "~/.hermes_glasses_bridge_session.json",
    ) or "~/.hermes_glasses_bridge_session.json"
)


def _today() -> str:
    return datetime.date.today().isoformat()


def load_session() -> str | None:
    """Stored hermes session ID, if it is from today."""
    try:
        with open(SESSION_FILE, encoding="utf-8") as f:
            data = json.load(f)
        if (
            data.get("date") == _today()
            and data.get("session_id")
            and data.get("voice_profile") == voice_session_profile_signature()
        ):
            return data["session_id"]
    except (OSError, ValueError):
        pass
    return None


def store_session(session_id: str):
    """Persist a same-day session atomically with owner-only permissions."""
    temp_path = None
    try:
        session_path = Path(SESSION_FILE).expanduser()
        session_path.parent.mkdir(parents=True, exist_ok=True)
        fd, temp_path = tempfile.mkstemp(
            prefix=f".{session_path.name}.",
            dir=str(session_path.parent),
            text=True,
        )
        os.chmod(temp_path, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump({
                "session_id": session_id,
                "date": _today(),
                "voice_profile": voice_session_profile_signature(),
            }, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp_path, session_path)
        temp_path = None
    except OSError as e:
        print(f"[Bridge] Could not persist session: {e}")
    finally:
        if temp_path:
            try:
                os.unlink(temp_path)
            except OSError:
                pass


def clear_session():
    try:
        os.unlink(SESSION_FILE)
    except OSError:
        pass


def extract_session_id(stderr_text: str) -> str | None:
    match = re.search(r"session_id:\s*(\S+)", stderr_text)
    return match.group(1) if match else None


# ── Legacy Claude SDK brain (unused by the request path below, which now
# routes anthropic/openai/gemini through ask_provider(); kept for its
# tested same-day history helpers) ──────────────────────────────────────────
CLAUDE_HISTORY_FILE = os.path.expanduser("~/.hermes_glasses_claude_history.json")
CLAUDE_MAX_HISTORY = 40  # messages kept (20 turns)

CLAUDE_SYSTEM = adam_persona()


def load_claude_history() -> list:
    """Same-day conversation history for the Claude brain."""
    try:
        with open(CLAUDE_HISTORY_FILE) as f:
            data = json.load(f)
        if data.get("date") == _today():
            return data.get("messages", [])
    except (OSError, ValueError):
        pass
    return []


def store_claude_history(messages: list):
    try:
        with open(CLAUDE_HISTORY_FILE, "w") as f:
            json.dump({"date": _today(), "messages": messages}, f)
    except OSError as e:
        print(f"[Bridge] Could not persist Claude history: {e}")


def clear_claude_history():
    try:
        os.unlink(CLAUDE_HISTORY_FILE)
    except OSError:
        pass


def trim_claude_history(messages: list, max_messages: int = CLAUDE_MAX_HISTORY) -> list:
    return messages[-max_messages:] if len(messages) > max_messages else messages


def build_claude_user_content(text: str, photo: bytes | None) -> list:
    """User content blocks: optional glasses photo first, then the words."""
    content = []
    if photo:
        content.append({
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": "image/jpeg",
                "data": base64.b64encode(photo).decode(),
            },
        })
    content.append({"type": "text", "text": text})
    return content


# Retained legacy SDK helper - no longer on the request path (provider
# brains now go through ask_provider()/build_provider_request()); kept for
# reference and its tested same-day history helpers.
def ask_claude(text: str, photo: bytes | None = None) -> str | None:
    """Answer via the Claude API with same-day conversation memory.

    Fast path: no process spawn, no agent boot - typically 2-4s for a
    spoken-length reply. Photos go in as native image blocks.
    """
    try:
        import anthropic
    except ImportError:
        return "The Claude brain needs the anthropic package: pip install anthropic"

    history = load_claude_history()
    user_message = {"role": "user", "content": build_claude_user_content(text, photo)}

    try:
        client = anthropic.Anthropic()
        response = client.messages.create(
            model=CLAUDE_MODEL,
            max_tokens=1024,
            # Stable prefix cached; history rides behind it
            system=[{
                "type": "text",
                "text": CLAUDE_SYSTEM,
                "cache_control": {"type": "ephemeral"},
            }],
            messages=trim_claude_history(history + [user_message]),
        )
        reply = next(
            (b.text for b in response.content if b.type == "text"), None
        )
        if reply:
            # Persist text-only user turn (images would bloat the file and
            # re-bill on every later request)
            history.append({"role": "user", "content": text})
            history.append({"role": "assistant", "content": reply})
            store_claude_history(trim_claude_history(history))
        return reply
    except anthropic.AuthenticationError:
        return ("The Claude API key is missing or invalid. Set "
                "ANTHROPIC_API_KEY for the bridge.")
    except anthropic.APIStatusError as e:
        print(f"[Claude] API error {e.status_code}: {e.message}")
        return "Sorry, the Claude API returned an error."
    except anthropic.APIConnectionError:
        return "Sorry, I couldn't reach the Claude API."
    except Exception as e:
        print(f"[Claude] Error: {e}")
        return f"Error: {e}"

# ── Hermes Agent ────────────────────────────────────────────────────────────

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
BOX_CHARS = set("╭╮╰╯│─═╞╡┌┐└┘┤├")


def extract_hermes_reply(raw: str) -> str | None:
    """Pull just the assistant's reply out of the hermes CLI output.

    The CLI prints: a Query echo, spinner lines, then the reply inside a
    box whose top border contains 'Hermes', then a session footer.
    """
    text = ANSI_RE.sub("", raw).replace("\r", "\n")
    lines = text.split("\n")

    reply_lines = []
    in_box = False
    for line in lines:
        stripped = line.strip()
        if not in_box:
            if "Hermes" in stripped and BOX_CHARS & set(stripped):
                in_box = True
            continue
        # Bottom border (or any pure box-drawing line) ends the reply
        if stripped and set(stripped) <= (BOX_CHARS | set(" ")):
            break
        cleaned = stripped.strip("│").strip()
        reply_lines.append(cleaned)

    reply = "\n".join(reply_lines).strip()
    return reply or None


def ask_hermes(
    text: str,
    image_path: str | None = None,
    resume: str | None = None,
) -> tuple[str | None, str | None]:
    """Send text (and optionally an image) to Hermes Agent.

    Returns (reply, session_id). session_id enables conversation memory
    via --resume on the next query; either value may be None.
    """
    cmd = [
        HERMES_BIN,
        "chat",
        "-q",
        text,
        "-Q",
        "--cli",
        "--no-restore-cwd",
        "--in",
        BRIDGE_WORKDIR,
        "--max-turns",
        str(HERMES_MAX_TURNS),
        "--run-budget",
        str(HERMES_RUN_BUDGET),
    ]
    if image_path:
        cmd += ["--image", image_path]
    if resume:
        cmd += ["--resume", resume]
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=max(30, HERMES_RUN_BUDGET + 15),
            env={**os.environ, "HERMES_NO_COLOR": "1"},
        )
        session_id = extract_session_id(result.stderr)
        if result.returncode != 0:
            # Hermes stderr can contain provider details, filesystem paths, or
            # echoed tool diagnostics. Keep those out of the voice reply and
            # launchd logs; the exit status is enough to correlate with Hermes'
            # own private logs.
            print(f"[Hermes] CLI exited with status {result.returncode}")
            return "Sorry, Hermes could not answer that right now.", session_id
        output = result.stdout.strip()
        if output:
            # -Q should print only the reply; if box UI sneaks in, unwrap it
            if BOX_CHARS & set(output):
                reply = extract_hermes_reply(output)
                if reply:
                    return reply, session_id
            return output, session_id
        if result.stderr.strip():
            print("[Hermes] CLI returned no reply text")
            return "Sorry, Hermes could not answer that right now.", session_id
        return None, session_id
    except subprocess.TimeoutExpired:
        return "Sorry, Hermes took too long to respond.", None
    except Exception as e:
        # Exception strings can contain paths, arguments, provider details,
        # or echoed prompt fragments. Keep them out of both logs and speech.
        print(f"[Hermes] CLI invocation failed ({type(e).__name__})")
        return "Sorry, Hermes could not answer that right now.", None


# ── Hermes local realtime API ──────────────────────────────────────────────

_TOKEN_RE = re.compile(
    r"window\.__HERMES_SESSION_TOKEN__\s*=\s*(\"(?:\\.|[^\"\\])*\")"
)
_WAKE_PREFIX_RE = re.compile(
    r"^\s*adam\b[\s,.:;!?\-\u2013\u2014]*", re.IGNORECASE
)


def extract_dashboard_token(html: str) -> str | None:
    """Extract Hermes's JSON-escaped loopback session token from root HTML."""
    match = _TOKEN_RE.search(html or "")
    if not match:
        return None
    try:
        value = json.loads(match.group(1))
    except (TypeError, ValueError, json.JSONDecodeError):
        return None
    return value if isinstance(value, str) and value else None


def _loopback_http_base(value: str) -> bool:
    try:
        parsed = urllib.parse.urlsplit(value)
    except ValueError:
        return False
    return (
        parsed.scheme in {"http", "https"}
        and (parsed.hostname or "").lower() in {
            "127.0.0.1", "localhost", "::1"
        }
    )


def _hermes_private_paths(value: str) -> tuple[Path, Path]:
    """Return the venv Python and its Hermes checkout without dereferencing.

    Hermes's managed virtual-environment interpreter is a symlink. Resolving
    that symlink points into the runtime cache and loses the checkout root
    needed for ``python -m hermes_cli.main``.
    """
    python = Path(os.path.abspath(os.path.expanduser(value)))
    if not python.is_file():
        raise RuntimeError("Hermes private-backend Python is unavailable")
    try:
        agent_root = python.parents[2]
    except IndexError as error:
        raise RuntimeError("Hermes private-backend path is invalid") from error
    return python, agent_root


class HermesPrivateBackend:
    """Own one token-authenticated, loopback-only Hermes voice backend.

    Current Hermes correctly places fixed-port dashboards with a configured
    public URL behind interactive cookie auth. Adam is a non-interactive local
    service, so it starts the existing Desktop-private backend shape on an
    OS-assigned port instead of weakening or scraping that dashboard auth.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self.process: subprocess.Popen | None = None
        self.base_url: str | None = None
        self.token_value: str | None = None
        self.ready_file: Path | None = None

    def ensure(self) -> tuple[str, str]:
        with self._lock:
            if (
                self.process is not None
                and self.process.poll() is None
                and self.base_url
                and self.token_value
            ):
                return self.base_url, self.token_value

            self._stop_locked()
            python, agent_root = _hermes_private_paths(HERMES_PRIVATE_PYTHON)

            runtime_dir = (
                Path(os.environ.get("HERMES_HOME", "~/.hermes"))
                .expanduser()
                / "runtime"
                / "adam-voice"
            )
            runtime_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
            with contextlib.suppress(OSError):
                runtime_dir.chmod(0o700)
            ready_file = runtime_dir / f"backend-{os.getpid()}.json"
            with contextlib.suppress(FileNotFoundError):
                ready_file.unlink()

            token = secrets.token_urlsafe(32)
            environment = os.environ.copy()
            environment.update({
                "HERMES_DESKTOP": "1",
                "HERMES_DASHBOARD_SESSION_TOKEN": token,
                "HERMES_DESKTOP_READY_FILE": str(ready_file),
            })
            process = subprocess.Popen(
                [
                    str(python), "-m", "hermes_cli.main", "serve",
                    "--host", "127.0.0.1", "--port", "0",
                ],
                cwd=str(agent_root),
                env=environment,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            self.process = process
            self.ready_file = ready_file

            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    self._stop_locked()
                    raise RuntimeError("Hermes private voice backend exited during startup")
                try:
                    payload = json.loads(ready_file.read_text(encoding="utf-8"))
                    port = int(payload.get("port") or 0)
                except (FileNotFoundError, OSError, TypeError, ValueError,
                        json.JSONDecodeError):
                    port = 0
                if 1 <= port <= 65535:
                    self.base_url = f"http://127.0.0.1:{port}"
                    self.token_value = token
                    return self.base_url, token
                time.sleep(0.05)

            self._stop_locked()
            raise RuntimeError("Hermes private voice backend did not become ready")

    def stop(self) -> None:
        with self._lock:
            self._stop_locked()

    def _stop_locked(self) -> None:
        process, self.process = self.process, None
        if process is not None and process.poll() is None:
            with contextlib.suppress(OSError):
                process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(OSError):
                    process.kill()
                with contextlib.suppress(subprocess.TimeoutExpired):
                    process.wait(timeout=5)
        if self.ready_file is not None:
            with contextlib.suppress(FileNotFoundError, OSError):
                self.ready_file.unlink()
        self.ready_file = None
        self.base_url = None
        self.token_value = None


_PRIVATE_BACKEND = HermesPrivateBackend()


def pcm16_wav(
    pcm: bytes,
    sample_rate: int = HERMES_AUDIO_SAMPLE_RATE,
    channels: int = HERMES_AUDIO_CHANNELS,
) -> bytes:
    """Wrap little-endian signed PCM16 in an in-memory WAV container."""
    output = io.BytesIO()
    with wave.open(output, "wb") as wav_file:
        wav_file.setnchannels(channels)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(pcm)
    return output.getvalue()


def strip_adam_wake_word(text: str) -> str:
    """Remove a leading wake word if Whisper included it in the command."""
    return _WAKE_PREFIX_RE.sub("", (text or "").strip(), count=1).strip()


def is_donzo_command(text: str) -> bool:
    """Match only a standalone, punctuation-tolerant follow-up end phrase."""
    folded = unicodedata.normalize("NFKD", text or "").casefold()
    without_marks = "".join(
        character for character in folded
        if unicodedata.category(character) != "Mn"
    )
    return re.findall(r"[^\W_]+", without_marks, flags=re.UNICODE) == ["donzo"]


def _stt_language(locale: str) -> str:
    return "lv" if sanitize_locale(locale) == "lv-LV" else "en"


def _safe_vocabulary(value) -> list[str]:
    """Bound user vocabulary before it is appended to Whisper's prompt."""
    if not isinstance(value, list):
        return []
    result = []
    for item in value[:24]:
        if not isinstance(item, str):
            continue
        cleaned = " ".join(item.strip().split())[:48]
        if cleaned and cleaned not in result:
            result.append(cleaned)
    return result


class HermesLocalAPI:
    """Small loopback-only adapter for Hermes HTTP and WebSocket APIs."""

    def __init__(self, base_url: str = HERMES_API_BASE):
        self.base_url = base_url.rstrip("/")
        self._token: str | None = None

    def invalidate_token(self) -> None:
        self._token = None

    def token(self, refresh: bool = False) -> str:
        if self._token and not refresh:
            return self._token
        private_allowed = HERMES_PRIVATE_BACKEND not in {
            "0", "false", "no", "off", "disabled"
        }
        request = urllib.request.Request(
            self.base_url + "/",
            headers={"Accept": "text/html", "Cache-Control": "no-cache"},
        )
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                html = response.read().decode("utf-8", errors="replace")
        except (OSError, TimeoutError, urllib.error.URLError) as error:
            if private_allowed and _loopback_http_base(self.base_url):
                self.base_url, token = _PRIVATE_BACKEND.ensure()
            else:
                raise RuntimeError("Hermes voice backend is unavailable") from error
        else:
            token = extract_dashboard_token(html)
        if not token:
            if private_allowed and _loopback_http_base(self.base_url):
                self.base_url, token = _PRIVATE_BACKEND.ensure()
            else:
                raise RuntimeError(
                    "Hermes did not expose a loopback session token"
                )
        self._token = token
        return token

    def _post_json(self, path: str, payload: dict) -> dict:
        """POST JSON, refreshing Hermes's ephemeral token once on a 401."""
        for attempt in range(2):
            token = self.token(refresh=attempt > 0)
            request = urllib.request.Request(
                self.base_url + path,
                data=json.dumps(payload).encode("utf-8"),
                headers={
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "X-Hermes-Session-Token": token,
                },
                method="POST",
            )
            try:
                with urllib.request.urlopen(request, timeout=90) as response:
                    return json.loads(response.read().decode("utf-8"))
            except urllib.error.HTTPError as error:
                if error.code == 401 and attempt == 0:
                    self.invalidate_token()
                    continue
                detail = ""
                with contextlib.suppress(Exception):
                    body = json.loads(error.read().decode("utf-8"))
                    detail = str(body.get("detail") or "")
                raise RuntimeError(detail or f"Hermes HTTP {error.code}") from None
        raise RuntimeError("Hermes authentication failed")

    def transcribe(self, pcm: bytes, locale: str, vocabulary=None) -> dict:
        words = _safe_vocabulary(vocabulary)
        prompt = HERMES_STT_PROMPT
        if words:
            prompt += " Vocabulary: " + ", ".join(words) + "."
        wav_bytes = pcm16_wav(pcm)
        result = self._post_json("/api/audio/transcribe", {
            "data_url": "data:audio/wav;base64," + base64.b64encode(wav_bytes).decode("ascii"),
            "mime_type": "audio/wav",
            "language": _stt_language(locale),
            "prompt": prompt,
        })
        result["transcript"] = strip_adam_wake_word(
            str(result.get("transcript") or "")
        )
        return result

    def websocket_url(self, path: str) -> str:
        # Token resolution may replace an OAuth-protected fixed dashboard with
        # Adam's private loopback backend. Resolve it before parsing the host so
        # a first-use WebSocket cannot retain the stale dashboard port.
        token = self.token()
        parsed = urllib.parse.urlsplit(self.base_url)
        scheme = "wss" if parsed.scheme == "https" else "ws"
        query = urllib.parse.urlencode({"token": token})
        return urllib.parse.urlunsplit(
            (scheme, parsed.netloc, path, query, "")
        )


def prewarm_voice_backend() -> bool:
    """Start Hermes and load local STT before the first wake utterance."""
    try:
        api = HermesLocalAPI()
        # A short silent capture exercises the real transcription endpoint.
        # Backend VAD may drop it, while the configured local provider still
        # loads and caches its model. Kokoro warms independently at startup.
        silence = b"\0\0" * (HERMES_AUDIO_SAMPLE_RATE // 2)
        api.transcribe(silence, "en-GB", ["Adam", "Hermes", "Ray-Ban Meta"])
        print("[Hermes] Private voice backend and local STT are warm")
        return True
    except Exception as error:
        print(f"[Hermes] Voice prewarm failed ({type(error).__name__})")
        return False


def _timing_metadata(value) -> str:
    """Bound backend labels before including them in metadata-only logs."""
    return re.sub(r"[^A-Za-z0-9._-]+", "-", str(value or "unknown"))[:48]


def log_voice_timing(stage: str, started_at: float, **metadata) -> None:
    elapsed_ms = max(0, round((time.monotonic() - started_at) * 1000))
    suffix = "".join(
        f" {key}={_timing_metadata(value)}"
        for key, value in sorted(metadata.items())
        if value is not None
    )
    print(
        f"[Bridge] Voice timing stage={_timing_metadata(stage)} "
        f"elapsed_ms={elapsed_ms}{suffix}"
    )


class HermesGateway:
    """Persistent Hermes JSON-RPC chat session for one glasses connection."""

    def __init__(self, api: HermesLocalAPI):
        self.api = api
        self.websocket = None
        self.session_id: str | None = None
        self._rpc_id = 0
        self._turn_lock = asyncio.Lock()

    async def close(self) -> None:
        if self.websocket is not None:
            with contextlib.suppress(Exception):
                await self.websocket.close()
        self.websocket = None
        self.session_id = None

    async def reset(self) -> None:
        await self.close()
        clear_session()

    async def interrupt(self) -> None:
        """Best-effort stop for the active Hermes turn, then reset its socket.

        Closing after the interrupt prevents late events from the cancelled
        turn being mistaken for the next prompt on this session-scoped stream.
        The stored Hermes session remains resumable on the next request.
        """
        websocket = self.websocket
        session_id = self.session_id
        if websocket is not None and session_id:
            self._rpc_id += 1
            with contextlib.suppress(Exception):
                await websocket.send(json.dumps({
                    "jsonrpc": "2.0",
                    "id": f"adam-cancel-{self._rpc_id}",
                    "method": "session.interrupt",
                    "params": {"session_id": session_id},
                }))
        await self.close()

    async def _receive_json(self, timeout: float = 30) -> dict:
        if self.websocket is None:
            raise RuntimeError("Hermes gateway is not connected")
        raw = await asyncio.wait_for(self.websocket.recv(), timeout=timeout)
        if isinstance(raw, bytes):
            raise RuntimeError("Unexpected binary frame from Hermes gateway")
        value = json.loads(raw)
        if not isinstance(value, dict):
            raise RuntimeError("Invalid Hermes gateway frame")
        return value

    async def _rpc(self, method: str, params: dict, timeout: float = 30) -> dict:
        if self.websocket is None:
            raise RuntimeError("Hermes gateway is not connected")
        self._rpc_id += 1
        request_id = f"adam-{self._rpc_id}"
        await self.websocket.send(json.dumps({
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": params,
        }))
        deadline = time.monotonic() + timeout
        while True:
            frame = await self._receive_json(max(0.1, deadline - time.monotonic()))
            if frame.get("id") != request_id:
                continue
            if frame.get("error"):
                message = frame["error"].get("message") if isinstance(frame["error"], dict) else None
                raise RuntimeError(message or f"Hermes RPC {method} failed")
            result = frame.get("result")
            return result if isinstance(result, dict) else {}

    async def _connect(
        self,
        force_new: bool = False,
        inherit_profile: bool = False,
    ) -> None:
        if self.websocket is not None and self.session_id:
            return
        url = await asyncio.to_thread(self.api.websocket_url, "/api/ws")
        try:
            self.websocket = await websockets.connect(
                url,
                open_timeout=10,
                ping_interval=20,
                ping_timeout=20,
                max_size=4 * 1024 * 1024,
            )
            ready = await self._receive_json(15)
            params = ready.get("params") if isinstance(ready, dict) else None
            if not isinstance(params, dict) or params.get("type") != "gateway.ready":
                raise RuntimeError("Hermes gateway did not become ready")

            stored = None if force_new else load_session()
            if stored:
                try:
                    result = await self._rpc("session.resume", {
                        "session_id": stored,
                        "source": "adam_voice",
                        "defer_history": True,
                    })
                except Exception:
                    clear_session()
                    result = {}
                self.session_id = result.get("session_id")

            if not self.session_id:
                create_params = {
                    "title": "Adam Voice",
                    "source": "adam_voice",
                    "cwd": BRIDGE_WORKDIR,
                    "cols": 100,
                    "close_on_disconnect": False,
                }
                if not inherit_profile:
                    if HERMES_AGENT_MODEL:
                        create_params["model"] = HERMES_AGENT_MODEL
                    if HERMES_AGENT_PROVIDER:
                        create_params["provider"] = HERMES_AGENT_PROVIDER
                    if HERMES_AGENT_REASONING_EFFORT:
                        create_params["reasoning_effort"] = (
                            HERMES_AGENT_REASONING_EFFORT
                        )
                    create_params["fast"] = HERMES_AGENT_FAST
                result = await self._rpc("session.create", create_params)
                self.session_id = str(result.get("session_id") or "") or None
                stored = str(result.get("stored_session_id") or "")
                if stored and not inherit_profile:
                    store_session(stored)
            if not self.session_id:
                raise RuntimeError("Hermes did not create a voice session")
        except Exception:
            await self.close()
            raise

    async def ask(self, text: str, on_delta, on_attention=None) -> str:
        """Submit one prompt and deliver assistant text deltas as they arrive."""
        async with self._turn_lock:
            for attempt in range(2):
                try:
                    inherit_profile = attempt > 0
                    if inherit_profile:
                        clear_session()
                    await self._connect(
                        force_new=inherit_profile,
                        inherit_profile=inherit_profile,
                    )
                    return await self._ask_connected(text, on_delta, on_attention)
                except HermesAttentionRequired:
                    await self.close()
                    raise
                except Exception:
                    await self.close()
                    if attempt:
                        raise
            raise RuntimeError("Hermes gateway turn failed")

    async def _ask_connected(self, text: str, on_delta, on_attention=None) -> str:
        if self.websocket is None or not self.session_id:
            raise RuntimeError("Hermes gateway session is unavailable")

        self._rpc_id += 1
        request_id = f"adam-turn-{self._rpc_id}"
        await self.websocket.send(json.dumps({
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "prompt.submit",
            "params": {"session_id": self.session_id, "text": text},
        }))

        collected = []
        deadline = time.monotonic() + max(30, HERMES_RUN_BUDGET + 15)
        attention_types = {"approval.request", "clarify.request", "sudo.request"}
        while True:
            frame = await self._receive_json(max(0.1, deadline - time.monotonic()))
            if frame.get("id") == request_id and frame.get("error"):
                error = frame.get("error")
                message = error.get("message") if isinstance(error, dict) else None
                raise RuntimeError(message or "Hermes rejected the prompt")

            if frame.get("method") != "event":
                continue
            params = frame.get("params")
            if not isinstance(params, dict) or params.get("session_id") != self.session_id:
                continue
            event_type = params.get("type")
            payload = params.get("payload")
            payload = payload if isinstance(payload, dict) else {}
            if event_type == "message.delta":
                delta = str(payload.get("text") or "")
                if delta:
                    collected.append(delta)
                    await on_delta(delta)
            elif event_type in attention_types:
                if on_attention is not None:
                    await on_attention(event_type)
                # A voice-only surface cannot safely approve tools or answer a
                # clarification prompt. Interrupt the pending turn and close
                # this socket so the next wake reconnects to a clean event
                # stream instead of consuming the old turn's completion.
                self._rpc_id += 1
                with contextlib.suppress(Exception):
                    await self.websocket.send(json.dumps({
                        "jsonrpc": "2.0",
                        "id": f"adam-attention-{self._rpc_id}",
                        "method": "session.interrupt",
                        "params": {"session_id": self.session_id},
                    }))
                raise HermesAttentionRequired(event_type)
            elif event_type == "message.complete":
                final = str(payload.get("text") or "").strip()
                return final or "".join(collected).strip()


class HermesAttentionRequired(RuntimeError):
    """The desktop Hermes session needs a human action unavailable by voice."""


class HermesTTSStream:
    """Pipe Hermes's configured sentence streamer to the phone WebSocket."""

    def __init__(
        self,
        api,
        phone,
        request_id,
        send_lock,
        on_audio_start=None,
    ):
        self.api = api
        self.phone = phone
        self.request_id = request_id
        self.send_lock = send_lock
        self.websocket = None
        self.receiver: asyncio.Task | None = None
        self.phone_started = False
        self.ended = False
        self.bytes_sent = 0
        self.sample_rate = 24_000
        self.channels = 1
        # Hermes can advertise these in the start frame. Older servers do
        # not, so only use an explicitly configured bridge identity rather
        # than claiming a provider or voice that may not be active.
        self.provider = STREAM_TTS_PROVIDER
        self.voice = STREAM_TTS_VOICE
        self.on_audio_start = on_audio_start

    async def _phone_send(self, value) -> None:
        async with self.send_lock:
            await self.phone.send(value)

    async def open(self) -> bool:
        try:
            url = await asyncio.to_thread(
                self.api.websocket_url, "/api/audio/speak-stream"
            )
            self.websocket = await websockets.connect(
                url, open_timeout=10, ping_interval=20, ping_timeout=20
            )
            first = json.loads(await asyncio.wait_for(self.websocket.recv(), 15))
            if first.get("type") != "start":
                print(
                    "[Hermes] Streaming TTS unavailable "
                    f"(frame={_timing_metadata(first.get('type'))})"
                )
                await self.close(stop=True, end_phone=True)
                return False
            self.sample_rate = int(first.get("sample_rate") or 24_000)
            self.channels = int(first.get("channels") or 1)
            self.provider = (
                str(first.get("provider") or "").strip()
                or self.provider
            )
            self.voice = (
                str(first.get("voice") or "").strip()
                or self.voice
            )
            self.receiver = asyncio.create_task(self._receive())
            return True
        except Exception as error:
            print(
                "[Hermes] Streaming TTS unavailable "
                f"(error={type(error).__name__})"
            )
            await self.close(stop=True, end_phone=True)
            return False

    async def _start_phone_audio(self) -> None:
        """Switch the phone to playback only when real PCM is ready."""
        if self.phone_started:
            return
        self.phone_started = True
        callback, self.on_audio_start = self.on_audio_start, None
        if callback is not None:
            await callback(self.provider)
        await self._phone_send(json.dumps({
            "type": "audio_start",
            "request_id": self.request_id,
            "sample_rate": self.sample_rate,
            "channels": self.channels,
            "format": "pcm_s16le",
            "provider": self.provider,
            "voice": self.voice,
        }))

    async def _end_phone_audio(self) -> None:
        if not self.phone_started or self.ended:
            return
        self.ended = True
        await self._phone_send(json.dumps({
            "type": "audio_end",
            "request_id": self.request_id,
        }))

    async def _end_phone_segment(self) -> None:
        """Expose a natural sentence boundary without closing the response."""
        if not self.phone_started or self.ended:
            return
        await self._phone_send(json.dumps({
            "type": "audio_segment",
            "request_id": self.request_id,
        }))

    async def feed(self, text: str) -> None:
        if self.websocket is not None and text:
            await self.websocket.send(json.dumps({"text": text}))

    async def finish(self, end_phone: bool = True) -> bool:
        if self.websocket is None:
            return False
        with contextlib.suppress(Exception):
            await self.websocket.send(json.dumps({"done": True}))
        if self.receiver is not None:
            with contextlib.suppress(Exception):
                await asyncio.wait_for(self.receiver, timeout=90)
        await self.close()
        if end_phone:
            await self._end_phone_audio()
        return self.bytes_sent > 0

    async def complete_phone_audio(self) -> None:
        """Close the phone envelope after its final response metadata."""
        await self._end_phone_audio()

    async def _receive(self) -> None:
        if self.websocket is None:
            return
        try:
            async for frame in self.websocket:
                if isinstance(frame, bytes):
                    if not frame:
                        continue
                    await self._start_phone_audio()
                    await self._phone_send(frame)
                    self.bytes_sent += len(frame)
                    continue
                value = json.loads(frame)
                if value.get("type") == "segment_end":
                    await self._end_phone_segment()
                    continue
                if value.get("type") == "end":
                    return
        except Exception:
            pass

    async def close(self, stop: bool = False, end_phone: bool = False) -> None:
        upstream, self.websocket = self.websocket, None
        if upstream is not None:
            if stop:
                with contextlib.suppress(Exception):
                    await upstream.send(json.dumps({"stop": True}))
            with contextlib.suppress(Exception):
                await upstream.close()
        receiver, self.receiver = self.receiver, None
        current = asyncio.current_task()
        if receiver is not None and receiver is not current and not receiver.done():
            receiver.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await receiver
        if end_phone:
            with contextlib.suppress(Exception):
                await self._end_phone_audio()


async def process_audio_turn(
    websocket,
    capture: dict,
    conn_state: dict,
) -> None:
    """Transcribe one phone capture, ask persistent Hermes, and stream TTS."""
    request_id = capture["request_id"]
    locale = sanitize_locale(capture.get("locale"))
    pcm = bytes(capture["pcm"])
    send_lock = conn_state.setdefault("send_lock", asyncio.Lock())
    api = conn_state.setdefault("hermes_api", HermesLocalAPI())
    gateway = conn_state.setdefault("gateway", HermesGateway(api))
    tts = None
    fallback_audio_open = False
    turn_started_at = float(capture.get("ended_at") or time.monotonic())
    first_delta_logged = False
    first_audio_logged = False

    async def phone_send(payload) -> None:
        async with send_lock:
            await websocket.send(payload)

    try:
        stt_started_at = time.monotonic()
        transcription = await asyncio.to_thread(
            api.transcribe, pcm, locale, capture.get("vocabulary")
        )
        log_voice_timing(
            "stt",
            stt_started_at,
            provider=transcription.get("provider"),
            backend=transcription.get("backend"),
        )
        transcript = str(transcription.get("transcript") or "").strip()
        if capture.get("follow_up") and is_donzo_command(transcript):
            await phone_send(json.dumps({
                "type": "follow_up_ended",
                "request_id": request_id,
            }))
            return
        await phone_send(json.dumps({
            "type": "transcript",
            "text": transcript,
            "request_id": request_id,
            "provider": transcription.get("provider"),
        }))
        if not transcript:
            await phone_send(json.dumps({
                "type": "error",
                "request_id": request_id,
                "message": "I did not catch that. Say Adam and try again.",
            }))
            return

        await phone_send(json.dumps({
            "type": "response_start",
            "request_id": request_id,
            "tts": True,
        }))

        # Kokoro is English-only. Latvian deliberately uses the British/male
        # bridge fallback path until a local Latvian provider is available.
        async def on_first_audio(provider: str) -> None:
            nonlocal first_audio_logged
            if first_audio_logged:
                return
            first_audio_logged = True
            log_voice_timing(
                "first_spoken_pcm", turn_started_at, provider=provider
            )

        tts = HermesTTSStream(
            api,
            websocket,
            request_id,
            send_lock,
            on_audio_start=on_first_audio,
        )
        streaming_tts = locale != "lv-LV" and await tts.open()
        delta_text = []

        async def on_delta(delta: str) -> None:
            nonlocal first_delta_logged
            if not first_delta_logged:
                first_delta_logged = True
                log_voice_timing("first_agent_delta", turn_started_at)
            delta_text.append(delta)
            await phone_send(json.dumps({
                "type": "response_delta",
                "text": delta,
                "request_id": request_id,
            }))
            if streaming_tts:
                await tts.feed(delta)

        async def on_attention(kind: str) -> None:
            await phone_send(json.dumps({
                "type": "attention",
                "request_id": request_id,
                "kind": kind,
                "message": "Adam needs attention in Hermes on your Mac.",
            }))

        gate_action = detect_gate_action(transcript)
        if gate_action:
            accepted, response = await asyncio.to_thread(
                activate_gate_relay, gate_action
            )
            print(f"[Gate] voice response accepted={accepted}")
            await on_delta(response)
        else:
            try:
                response = await gateway.ask(
                    build_adam_query(transcript, locale), on_delta, on_attention
                )
            except HermesAttentionRequired:
                response = (
                    "Man vajadzīga tava uzmanība Hermes lietotnē Mac datorā."
                    if locale == "lv-LV"
                    else "I need your attention in Hermes on the Mac before I can continue."
                )
        if streaming_tts and not delta_text and response:
            await tts.feed(response)
        response_text = response or "I'm not sure what to say."

        response_sent = False
        produced_audio = False
        if streaming_tts:
            # If sentence streaming already produced PCM, publish the response
            # before the upstream done marker can close playback. Otherwise
            # finish with the phone envelope held open so response metadata
            # still arrives before audio_end.
            if tts.bytes_sent > 0:
                await phone_send(json.dumps({
                    "type": "response",
                    "text": response_text,
                    "request_id": request_id,
                    "tts": True,
                    "provider": tts.provider,
                    "voice": tts.voice,
                }))
                response_sent = True
            produced_audio = await tts.finish(end_phone=False)
            if not produced_audio:
                streaming_tts = False
            else:
                if not response_sent:
                    await phone_send(json.dumps({
                        "type": "response",
                        "text": response_text,
                        "request_id": request_id,
                        "tts": True,
                        "provider": tts.provider,
                        "voice": tts.voice,
                    }))
                await tts.complete_phone_audio()

        if not produced_audio:
            speech = _coerce_synthesized_speech(await asyncio.to_thread(
                synthesize_speech, response_text, locale
            ))
            await phone_send(json.dumps({
                "type": "response",
                "text": response_text,
                "request_id": request_id,
                "tts": speech is not None,
                "provider": speech.provider if speech else None,
                "voice": speech.voice if speech else None,
            }))
            if speech is not None:
                await phone_send(json.dumps({
                    "type": "audio_start",
                    "request_id": request_id,
                    "sample_rate": speech.sample_rate,
                    "channels": speech.channels,
                    "format": "pcm_s16le",
                    "provider": speech.provider,
                    "voice": speech.voice,
                }))
                fallback_audio_open = True
                await on_first_audio(speech.provider)
                for index in range(0, len(speech.pcm), 16_384):
                    await phone_send(speech.pcm[index:index + 16_384])
                await phone_send(json.dumps({
                    "type": "audio_end", "request_id": request_id
                }))
                fallback_audio_open = False
    except Exception as error:
        print(f"[Bridge] Realtime turn failed ({type(error).__name__})")
        await phone_send(json.dumps({
            "type": "error",
            "request_id": request_id,
            "message": "Adam could not complete that turn. Please try again.",
        }))
    except asyncio.CancelledError:
        # A user cancellation is a normal turn outcome. Do not emit an error
        # frame that could race the explicit turn_cancelled confirmation.
        raise
    finally:
        if tts is not None:
            await tts.close(stop=True, end_phone=True)
        if fallback_audio_open:
            with contextlib.suppress(Exception):
                await phone_send(json.dumps({
                    "type": "audio_end", "request_id": request_id
                }))


# ── Text-to-Speech ─────────────────────────────────────────────────────────

@dataclass(frozen=True)
class SynthesizedSpeech:
    """PCM plus the provider identity that actually produced it."""

    pcm: bytes
    provider: str
    voice: str
    sample_rate: int = 24_000
    channels: int = 1


def _coerce_synthesized_speech(value) -> SynthesizedSpeech | None:
    """Keep legacy extensions returning bytes safe during migration."""
    if isinstance(value, SynthesizedSpeech):
        return value if value.pcm else None
    if isinstance(value, bytes) and value:
        return SynthesizedSpeech(value, "bridge", "configured")
    return None


def select_macos_say_voice(voices: str, locale: str) -> str | None:
    """Select only a known British male macOS voice for Adam's fallback."""
    if sanitize_locale(locale) != "en-GB":
        return None
    for line in voices.splitlines():
        match = re.match(
            r"^(.+?)\s+([a-z]{2}_[A-Z]{2})\s+#", line.strip()
        )
        if (
            match
            and match.group(1).strip() == "Daniel"
            and match.group(2) == "en_GB"
        ):
            return "Daniel"
    return None


def synthesize_speech(
    text: str, locale: str = DEFAULT_LOCALE
) -> SynthesizedSpeech | None:
    """Convert text to PCM16 mono 24kHz with truthful voice metadata."""
    # Try Edge TTS first (better quality)
    try:
        import edge_tts

        mp3_tmp = tempfile.NamedTemporaryFile(suffix=".mp3", delete=False)
        mp3_tmp.close()
        wav_tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
        wav_tmp.close()
        try:
            voice = (
                "lv-LV-NilsNeural"
                if sanitize_locale(locale) == "lv-LV"
                else "en-GB-RyanNeural"
            )

            async def _synth():
                communicate = edge_tts.Communicate(text, voice)
                await communicate.save(mp3_tmp.name)

            asyncio.run(_synth())

            # Decode MP3 → PCM16 mono 24kHz WAV. afconvert on macOS,
            # ffmpeg elsewhere (Linux).
            if shutil.which("afconvert"):
                cmd = ["afconvert", "-f", "WAVE", "-d", "LEI16@24000", "-c", "1",
                       mp3_tmp.name, wav_tmp.name]
            elif shutil.which("ffmpeg"):
                cmd = ["ffmpeg", "-y", "-loglevel", "error", "-i", mp3_tmp.name,
                       "-ar", "24000", "-ac", "1", "-sample_fmt", "s16",
                       wav_tmp.name]
            else:
                cmd = None
                print("[TTS] Neither afconvert nor ffmpeg found")

            if cmd:
                result = subprocess.run(cmd, capture_output=True, timeout=30)
                if result.returncode == 0:
                    with wave.open(wav_tmp.name, "rb") as wf:
                        pcm = wf.readframes(wf.getnframes())
                    return SynthesizedSpeech(pcm, "edge", voice) if pcm else None
                print(f"[TTS] decode failed: {result.stderr.decode()[:200]}")
        finally:
            # NamedTemporaryFile(delete=False) - always clean up, whether
            # synthesis/decode succeeded, failed, or raised.
            for path in (mp3_tmp.name, wav_tmp.name):
                try:
                    os.unlink(path)
                except OSError:
                    pass
    except ImportError:
        pass
    except Exception as e:
        print(f"[TTS] Edge TTS error: {e}")

    # Fallback: macOS say command, directly as PCM16 24kHz WAV
    if not shutil.which("say"):
        print("[TTS] No 'say' fallback available on this platform")
        return None
    try:
        voices_result = subprocess.run(
            ["say", "-v", "?"], capture_output=True, timeout=10
        )
    except Exception as error:
        print(f"[TTS] Could not list macOS voices: {error}")
        return None
    voice = select_macos_say_voice(
        voices_result.stdout.decode("utf-8", errors="replace"), locale
    )
    if voices_result.returncode != 0 or voice is None:
        print("[TTS] No verified British male macOS voice is installed")
        return None
    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    tmp.close()
    try:
        result = subprocess.run(
            ["say", "-v", voice, "-o", tmp.name,
             "--file-format=WAVE", "--data-format=LEI16@24000", text],
            capture_output=True, timeout=30,
        )
        if result.returncode != 0:
            print(f"[TTS] 'say' failed: {result.stderr.decode()[:200]}")
            return None
        with wave.open(tmp.name, "rb") as wf:
            pcm = wf.readframes(wf.getnframes())
        return SynthesizedSpeech(pcm, "macos-say", voice) if pcm else None
    except Exception as e:
        print(f"[TTS] Error: {e}")
        return None
    finally:
        try:
            os.unlink(tmp.name)
        except OSError:
            pass


# ── WebSocket Handler ──────────────────────────────────────────────────────

async def await_photo(websocket, timeout: float = 25.0) -> bytes | None:
    """Wait for the app to answer a capture_photo request.

    Discards mic-audio (binary) frames that arrive meanwhile. Returns the
    decoded JPEG bytes, or None on photo_error or timeout.
    """
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            print("[Bridge] Photo wait timed out")
            return None
        try:
            message = await asyncio.wait_for(websocket.recv(), timeout=remaining)
        except asyncio.TimeoutError:
            print("[Bridge] Photo wait timed out")
            return None
        if isinstance(message, bytes):
            continue  # stray binary frame while waiting - drop it
        try:
            data = json.loads(message)
        except (json.JSONDecodeError, ValueError) as e:
            print(f"[Bridge] Malformed JSON while awaiting photo, ignored: {e}")
            continue
        if not isinstance(data, dict):
            print(f"[Bridge] Non-object JSON while awaiting photo, ignored: {data!r}")
            continue
        msg_type = data.get("type")
        if msg_type == "photo":
            try:
                return base64.b64decode(data.get("data", ""))
            except Exception as e:
                print(f"[Bridge] Bad photo payload: {e}")
                return None
        if msg_type == "photo_error":
            print(f"[Bridge] Photo error from app: {data.get('message')}")
            return None
        if msg_type == "debug":
            print(f"[App] {data.get('msg')}")
        # any other message type: keep waiting


async def send_response(
    websocket,
    response_text: str,
    bridge_tts: bool,
    request_id: str | None = None,
):
    """Send a text response and optional legacy bridge-side audio."""
    speech = None
    if bridge_tts:
        print("[Bridge] Generating speech...")
        speech = _coerce_synthesized_speech(
            await asyncio.to_thread(synthesize_speech, response_text)
        )
    payload = {
        "type": "response",
        "text": response_text,
        "tts": speech is not None,
    }
    if speech is not None:
        payload.update({"provider": speech.provider, "voice": speech.voice})
    if request_id:
        payload["request_id"] = request_id
    await websocket.send(json.dumps(payload))

    if speech is not None:
        # ── Server-side TTS (legacy fallback, HERMES_BRIDGE_TTS=1) ──
        await websocket.send(json.dumps({
            "type": "audio_start",
            "sample_rate": speech.sample_rate,
            "channels": speech.channels,
            "format": "pcm_s16le",
            "provider": speech.provider,
            "voice": speech.voice,
        }))

        # Send in chunks to avoid frame size limits
        chunk_size = 16384
        for i in range(0, len(speech.pcm), chunk_size):
            await websocket.send(speech.pcm[i:i + chunk_size])
            await asyncio.sleep(0.01)

        await websocket.send(json.dumps({"type": "audio_end"}))


async def process_query(websocket, text: str, conn_state: dict | None = None,
                        want_tts: bool | None = None,
                        locale: str | None = None,
                        request_id: str | None = None):
    """Answer a text query: photo capture if visual, Hermes, TTS reply.

    The app transcribes on-device and sends {"type":"query"} text.
    conn_state carries per-connection context: {"last_photo_at": float}.
    want_tts: app's per-query choice of bridge TTS; None falls back to the
    HERMES_BRIDGE_TTS env default.
    locale: requested speech locale; unsupported values fall back to English.
    """
    bridge_tts = BRIDGE_TTS if want_tts is None else bool(want_tts)
    locale = sanitize_locale(locale)
    if conn_state is None:
        conn_state = {"last_photo_at": 0.0}

    # Access control never enters the model/tool-selection path. Both open
    # and close map to the same configured dry-contact relay pulse.
    gate_action = detect_gate_action(text)
    if gate_action:
        accepted, response_text = await asyncio.to_thread(
            activate_gate_relay, gate_action
        )
        print(f"[Gate] text response accepted={accepted}")
        await send_response(
            websocket, response_text, bridge_tts, request_id
        )
        return

    # ── Capture a photo for visual/deictic queries ──
    photo = None
    query_text = text
    needs_photo = should_capture_photo(
        text,
        conn_state.get("last_photo_at", 0.0),
        time.monotonic(),
    )
    if needs_photo and not BRIDGE_VISION:
        print("[Bridge] Visual query rejected: camera access is disabled")
        await send_response(
            websocket,
            vision_disabled_response(locale),
            bridge_tts,
            request_id,
        )
        return
    if needs_photo:
        print("[Bridge] Visual query - requesting photo from glasses")
        await websocket.send(json.dumps({"type": "capture_photo"}))
        photo = await await_photo(websocket)
        if photo:
            conn_state["last_photo_at"] = time.monotonic()
            print(f"[Bridge] Photo received: {len(photo)} bytes")
        else:
            print("[Bridge] No photo - answering text-only")
            query_text = ("(No photo could be captured from the glasses.) "
                          + text)

    canon_brain = _canon_brain(BRAIN)
    if canon_brain in ("anthropic", "openai", "gemini"):
        # ── Ask the provider API directly (fast path) ──
        print(f"[Bridge] Asking {canon_brain} ({CLAUDE_MODEL})...")
        response = await asyncio.to_thread(
            ask_provider, canon_brain, query_text, photo, locale
        )
    else:
        # ── Ask Hermes (with same-day conversation memory) ──
        image_path = None
        if photo:
            img_tmp = tempfile.NamedTemporaryFile(suffix=".jpg", delete=False)
            img_tmp.write(photo)
            img_tmp.close()
            image_path = img_tmp.name
        resume = load_session()
        # Include the persona on every turn so a resumed session also honors
        # the current locale and concise spoken-response contract.
        agent_query = build_adam_query(query_text, locale)
        print(f"[Bridge] Asking Hermes... (session: {resume or 'new'})")
        try:
            response, session_id = await asyncio.to_thread(
                ask_hermes, agent_query, image_path, resume
            )
            if resume and not response:
                # Stored session may have been pruned - retry fresh once
                print("[Bridge] Resume failed - retrying with a fresh session")
                clear_session()
                response, session_id = await asyncio.to_thread(
                    ask_hermes, agent_query, image_path, None
                )
            if session_id:
                store_session(session_id)
        finally:
            if image_path:
                os.unlink(image_path)
    response_text = response or "I'm not sure what to say."

    print(f"[Bridge] Hermes response ready ({len(response_text)} chars)")
    # "tts": whether PCM audio follows. False → the app speaks the text
    # itself with on-device synthesis.
    await send_response(websocket, response_text, bridge_tts, request_id)
    print("[Bridge] Response complete.")


def validate_startup_config():
    """Fail closed before binding a socket when shared-secret auth is absent."""
    if not AUTH_TOKEN.strip():
        raise RuntimeError(
            "HERMES_BRIDGE_TOKEN must be set to a non-blank value before "
            "starting the bridge"
        )


def _request_headers(websocket):
    request = getattr(websocket, "request", None)
    headers = getattr(request, "headers", None) if request else None
    if headers is None:
        # Compatibility with websockets versions before the v15 Request API.
        headers = getattr(websocket, "request_headers", None)
    return headers


def _authorization_header(websocket) -> str | None:
    headers = _request_headers(websocket)
    if headers is None:
        return None
    try:
        # Headers is case-insensitive in websockets; plain test dictionaries
        # may not be, so check both common spellings.
        return headers.get("Authorization") or headers.get("authorization")
    except (AttributeError, TypeError):
        return None


def _bearer_value(header: str | None) -> str | None:
    if header is None:
        return None
    scheme, separator, value = header.partition(" ")
    if not separator or scheme.lower() != "bearer":
        return ""
    return value.strip()


def is_authorized(websocket) -> bool:
    """Authenticate only with ``Authorization: Bearer``.

    URL query credentials are deliberately rejected because URLs are commonly
    retained by proxies, diagnostics, and settings history.
    """
    expected = AUTH_TOKEN.strip()
    if not expected:
        return False

    # Reject the entire handshake when any query string is present, even if
    # the bearer header itself is valid. This prevents a copied legacy
    # `?token=...` URL from authenticating while still leaking its credential
    # into proxy, browser, or diagnostics logs.
    request = getattr(websocket, "request", None)
    path = getattr(request, "path", "") if request else ""
    if not path:
        path = getattr(websocket, "path", "")
    if "?" in path:
        return False

    presented = _bearer_value(_authorization_header(websocket))

    try:
        return hmac.compare_digest(presented or "", expected)
    except TypeError:
        return False


def welcome_message() -> str:
    """Return the handshake payload, including server capabilities."""
    return json.dumps({
        "type": "welcome",
        "protocol": 2,
        "capabilities": {
            "vision": BRIDGE_VISION,
            "audio_upload": True,
            "server_stt": True,
            "streaming_tts": True,
            "turn_cancel": True,
            "follow_up_mode": True,
        },
    })


def _validated_request_id(value) -> str | None:
    if not isinstance(value, str):
        return None
    value = value.strip()
    return value if value and len(value) <= 128 else None


async def _send_protocol_error(websocket, message: str, request_id=None) -> None:
    payload = {"type": "error", "message": message}
    if request_id:
        payload["request_id"] = request_id
    await websocket.send(json.dumps(payload))


async def handle_connection(websocket):
    """Handle a single glasses connection."""
    if not is_authorized(websocket):
        print(f"[Bridge] REJECTED unauthorized connection from "
              f"{websocket.remote_address}")
        await websocket.close(code=4401, reason="unauthorized")
        return

    print(f"[Bridge] Glasses connected from {websocket.remote_address}")

    # Send welcome to confirm connection and advertise optional capabilities.
    await websocket.send(welcome_message())
    # Per-connection context for photo-recency suppression
    conn_state = {
        "last_photo_at": 0.0,
        "audio_capture": None,
        "send_lock": asyncio.Lock(),
        "turn_task": None,
        "turn_request_id": None,
        "recent_turn_request_ids": [],
    }

    def remember_finished_turn(request_id: str | None) -> None:
        if not request_id:
            return
        recent = conn_state["recent_turn_request_ids"]
        if request_id in recent:
            recent.remove(request_id)
        recent.append(request_id)
        del recent[:-8]

    def turn_finished(task: asyncio.Task) -> None:
        if conn_state.get("turn_task") is task:
            remember_finished_turn(conn_state.get("turn_request_id"))
            conn_state["turn_task"] = None
            conn_state["turn_request_id"] = None
        if not task.cancelled():
            # Retrieve any unexpected exception so asyncio never reports an
            # unhandled background task. process_audio_turn already converts
            # ordinary failures to protocol errors.
            with contextlib.suppress(Exception):
                task.exception()

    try:
        async for message in websocket:
            if isinstance(message, bytes):
                capture = conn_state.get("audio_capture")
                if not capture:
                    await _send_protocol_error(
                        websocket, "Audio arrived before audio_start."
                    )
                    continue
                if capture.get("cancelled"):
                    continue
                if len(capture["pcm"]) + len(message) > HERMES_AUDIO_MAX_BYTES:
                    request_id = capture.get("request_id")
                    conn_state["audio_capture"] = None
                    await _send_protocol_error(
                        websocket,
                        f"Audio is limited to {HERMES_AUDIO_MAX_SECONDS} seconds.",
                        request_id,
                    )
                    continue
                capture["pcm"].extend(message)
                continue

            try:
                data = json.loads(message)
            except (json.JSONDecodeError, ValueError) as e:
                print(f"[Bridge] Malformed JSON frame ignored: {e}")
                continue
            if not isinstance(data, dict):
                print(f"[Bridge] Non-object JSON frame ignored: {data!r}")
                continue
            msg_type = data.get("type")

            if msg_type == "audio_start":
                active_turn = conn_state.get("turn_task")
                if active_turn is not None and not active_turn.done():
                    await _send_protocol_error(
                        websocket, "An audio turn is already active."
                    )
                    continue
                if conn_state.get("audio_capture") is not None:
                    await _send_protocol_error(
                        websocket, "An audio capture is already active."
                    )
                    continue
                request_id = _validated_request_id(data.get("request_id"))
                if request_id is None:
                    await _send_protocol_error(
                        websocket, "audio_start requires a valid request_id."
                    )
                    continue
                if (
                    data.get("format") != HERMES_AUDIO_FORMAT
                    or data.get("sample_rate") != HERMES_AUDIO_SAMPLE_RATE
                    or data.get("channels") != HERMES_AUDIO_CHANNELS
                ):
                    await _send_protocol_error(
                        websocket,
                        "Adam expects mono PCM16 audio at 16000 Hz.",
                        request_id,
                    )
                    continue
                follow_up = data.get("follow_up", False)
                if not isinstance(follow_up, bool):
                    await _send_protocol_error(
                        websocket,
                        "audio_start follow_up must be a boolean.",
                        request_id,
                    )
                    continue
                conn_state["audio_capture"] = {
                    "request_id": request_id,
                    "locale": sanitize_locale(data.get("locale")),
                    "vocabulary": _safe_vocabulary(data.get("vocabulary")),
                    "follow_up": follow_up,
                    "pcm": bytearray(),
                    "started_at": time.monotonic(),
                }
                await websocket.send(json.dumps({
                    "type": "audio_ready", "request_id": request_id
                }))

            elif msg_type in {"audio_end", "end_of_audio"}:
                capture = conn_state.get("audio_capture")
                request_id = _validated_request_id(data.get("request_id"))
                if not capture:
                    await _send_protocol_error(
                        websocket, "audio_end arrived without audio_start.", request_id
                    )
                    continue
                if request_id and request_id != capture["request_id"]:
                    await _send_protocol_error(
                        websocket, "audio_end request_id does not match.", request_id
                    )
                    continue
                conn_state["audio_capture"] = None
                if capture.get("cancelled"):
                    continue
                if len(capture["pcm"]) < 640 or len(capture["pcm"]) % 2:
                    await _send_protocol_error(
                        websocket,
                        "The audio capture was empty or malformed.",
                        capture["request_id"],
                    )
                    continue
                print(
                    f"[Bridge] Audio turn received ({len(capture['pcm'])} bytes)"
                )
                capture["ended_at"] = time.monotonic()
                log_voice_timing("upload_received", capture["started_at"])
                conn_state["turn_request_id"] = capture["request_id"]
                conn_state["turn_task"] = asyncio.create_task(
                    process_audio_turn(websocket, capture, conn_state)
                )
                conn_state["turn_task"].add_done_callback(turn_finished)

            elif msg_type == "cancel_turn":
                request_id = _validated_request_id(data.get("request_id"))
                active_turn = conn_state.get("turn_task")
                active_request_id = conn_state.get("turn_request_id")
                if request_id is None:
                    await _send_protocol_error(
                        websocket, "cancel_turn requires a valid request_id."
                    )
                    continue
                capture = conn_state.get("audio_capture")
                if capture is not None and request_id == capture.get("request_id"):
                    # Keep the cancelled envelope until audio_end so binary
                    # frames already queued by URLSession are silently drained.
                    capture["cancelled"] = True
                    await websocket.send(json.dumps({
                        "type": "turn_cancelled", "request_id": request_id
                    }))
                    continue
                if request_id in conn_state["recent_turn_request_ids"]:
                    # Playback can outlive server generation. Cancellation is
                    # idempotent once the correlated stream was delivered.
                    await websocket.send(json.dumps({
                        "type": "turn_cancelled", "request_id": request_id
                    }))
                    continue
                if request_id != active_request_id:
                    await _send_protocol_error(
                        websocket,
                        "cancel_turn request_id does not match the active turn.",
                        request_id,
                    )
                    continue
                if active_turn is not None and not active_turn.done():
                    active_turn.cancel()
                    with contextlib.suppress(asyncio.CancelledError):
                        await active_turn
                    gateway = conn_state.get("gateway")
                    if gateway is not None:
                        await gateway.interrupt()
                conn_state["turn_task"] = None
                conn_state["turn_request_id"] = None
                remember_finished_turn(request_id)
                await websocket.send(json.dumps({
                    "type": "turn_cancelled", "request_id": request_id
                }))

            elif msg_type == "query":
                # App transcribed on-device and sends text directly
                text = (data.get("text") or "").strip()
                if text:
                    request_id = data.get("request_id")
                    if not isinstance(request_id, str) or not request_id.strip() \
                            or len(request_id) > 128:
                        request_id = None
                    print(f"[Bridge] Query received ({len(text)} chars)")
                    await process_query(websocket, text, conn_state,
                                        data.get("tts"), data.get("locale"),
                                        request_id)
                else:
                    await websocket.send(json.dumps({
                        "type": "error",
                        "message": "Empty query."
                    }))

            elif msg_type == "new_session":
                # Reset is a cancellation barrier: no old turn or queued
                # upload may write into the newly-created conversation.
                capture = conn_state.get("audio_capture")
                if capture is not None:
                    capture["cancelled"] = True
                active_turn = conn_state.get("turn_task")
                if active_turn is not None and not active_turn.done():
                    active_turn.cancel()
                    with contextlib.suppress(asyncio.CancelledError):
                        await active_turn
                conn_state["turn_task"] = None
                conn_state["turn_request_id"] = None
                conn_state["recent_turn_request_ids"].clear()
                clear_claude_history()
                gateway = conn_state.get("gateway")
                if gateway is not None:
                    await gateway.interrupt()
                    await gateway.reset()
                else:
                    clear_session()
                conn_state["last_photo_at"] = 0.0
                print("[Bridge] Conversation reset by app")
                await websocket.send(json.dumps({"type": "session_reset"}))

            elif msg_type == "debug":
                print(f"[App] {data.get('msg')}")

            elif msg_type == "ping":
                await websocket.send(json.dumps({"type": "pong"}))

        # Test/fake sockets and normal disconnects can end the receive stream
        # immediately after audio_end. Drain the turn before closing so the
        # response is not abandoned.
        active_turn = conn_state.get("turn_task")
        if active_turn is not None and not active_turn.done():
            await active_turn

    except websockets.exceptions.ConnectionClosed:
        print("[Bridge] Glasses disconnected")
    except Exception as e:
        # Protocol/provider exceptions can contain frame contents or backend
        # diagnostics. Keep the launchd log metadata-only.
        print(f"[Bridge] Connection handler failed ({type(e).__name__})")
    finally:
        active_turn = conn_state.get("turn_task")
        if active_turn is not None and not active_turn.done():
            active_turn.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await active_turn
        gateway = conn_state.get("gateway")
        if gateway is not None:
            await gateway.close()
        print("[Bridge] Connection closed")


def local_ip() -> str:
    """Best-effort LAN IP for the connection hint."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return "<your-mac-ip>"


async def main():
    validate_startup_config()
    loopback_bind = HOST in {"127.0.0.1", "localhost", "::1", "[::1]"}
    connection_hint = (
        "Use private Tailscale Serve for phone access"
        if loopback_bind
        else f"Connect to ws://{local_ip()}:{PORT}/voice"
    )
    print(f"""
╔══════════════════════════════════════════════════════════╗
║              Hermes Glasses Bridge Server                ║
║                                                          ║
║  Listening on ws://{HOST}:{PORT}/voice                       ║
║  Wake: on iPhone · final STT: Hermes configured STT      ║
║  Brain: {BRAIN} {f"({CLAUDE_MODEL})" if _canon_brain(BRAIN) in ("anthropic", "openai", "gemini") else "(CLI agent)":<30}  ║
║                                                          ║
║  {connection_hint:<54}║
╚══════════════════════════════════════════════════════════╝
""")
    # Glasses photos arrive as a single large base64-encoded JSON text frame
    # (a 1-3 MB raw JPEG becomes an even bigger base64 string), so raise
    # max_size well above the websockets default of 1 MiB to avoid a 1009
    # close before the frame is fully received.
    if HERMES_PREWARM and _loopback_http_base(HERMES_API_BASE):
        threading.Thread(
            target=prewarm_voice_backend,
            name="adam-voice-prewarm",
            daemon=True,
        ).start()

    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signum in (signal.SIGINT, signal.SIGTERM):
        with contextlib.suppress(NotImplementedError):
            loop.add_signal_handler(signum, stop_event.set)
    try:
        async with websockets.serve(
            handle_connection, HOST, PORT, max_size=16 * 1024 * 1024
        ):
            await stop_event.wait()
    finally:
        await asyncio.to_thread(_PRIVATE_BACKEND.stop)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n[Bridge] Shutting down.")
