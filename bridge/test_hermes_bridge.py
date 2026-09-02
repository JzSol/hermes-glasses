import asyncio
import base64
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import hermes_bridge as hb
from hermes_bridge import (
    is_visual_query, await_photo, build_provider_request, parse_provider_reply,
    is_adam_finish_phrase, strip_adam_finish_phrase,
)


class TestIsVisualQuery(unittest.TestCase):
    def test_visual_phrases_match(self):
        for phrase in [
            "What am I looking at?",
            "can you see this",
            "READ THIS for me",
            "what is this thing in front of me",
            "take a picture",
            "use the camera",
        ]:
            self.assertTrue(is_visual_query(phrase), phrase)

    def test_non_visual_phrases_do_not_match(self):
        for phrase in [
            "what's the weather tomorrow",
            "tell me a joke",
            "who wrote hamlet",
            # bare 'picture'/'photo' must NOT trigger - meta-questions about
            # photos were re-photographing the room. (Note: a meta-question
            # containing the literal phrase 'take a picture' still triggers;
            # keyword matching cannot tell it from the command.)
            "why was a photo captured just now",
            "do you always talk this much",
        ]:
            self.assertFalse(is_visual_query(phrase), phrase)

    def test_deictic_covers_photo_reference(self):
        from hermes_bridge import should_capture_photo
        # "describe this photo" flows through the deictic path now
        self.assertTrue(should_capture_photo("describe this photo", 0.0, 1000.0))
        # ...but meta/degree deictics never capture
        self.assertFalse(should_capture_photo("do you always talk this much", 0.0, 1000.0))
        self.assertFalse(should_capture_photo("keep it short like this answer", 0.0, 1000.0))
        # auxiliary verbs after this/that must not trigger
        self.assertFalse(should_capture_photo("hi this is a test", 0.0, 1000.0))
        self.assertFalse(should_capture_photo("that was great", 0.0, 1000.0))
        self.assertFalse(should_capture_photo("this should work now", 0.0, 1000.0))


class TestGateCommand(unittest.TestCase):
    def test_exact_open_and_close_phrases_match(self):
        for phrase, action in [
            ("open gates", "open"),
            ("Open the gates.", "open"),
            ("Hermes, please open the gate!", "open"),
            ("Please Adam open gates", "open"),
            ("close gates", "close"),
            ("Close the gate.", "close"),
        ]:
            self.assertEqual(hb.detect_gate_action(phrase), action, phrase)

    def test_device_context_prefix_is_ignored(self):
        text = "[Context: Tuesday, online, at home]\n\nopen gates"
        self.assertEqual(hb.detect_gate_action(text), "open")

    def test_incidental_gate_words_do_not_match(self):
        for phrase in [
            "open Golden Gate Park",
            "can you open the gates later",
            "close the gate settings",
            "tell me whether the gates are open",
        ]:
            self.assertIsNone(hb.detect_gate_action(phrase), phrase)


class TestGateRelay(unittest.TestCase):
    class FakeResponse:
        status = 200

        def __init__(self, body):
            self.body = body

        def __enter__(self):
            return self

        def __exit__(self, *_):
            return False

        def read(self):
            return self.body

    def setUp(self):
        hb._gate_last_accepted_at = 0.0

    def tearDown(self):
        hb._gate_last_accepted_at = 0.0

    def test_reads_secret_file_without_executing_it(self):
        with tempfile.NamedTemporaryFile(mode="w", delete=False) as env_file:
            env_file.write(
                "IGNORED=one\nHASS_TOKEN='secret value'\n"
                "NOT VALID=$(touch /tmp/nope)\n"
            )
            path = Path(env_file.name)
        try:
            values = hb._env_file_values(path)
        finally:
            path.unlink()
        self.assertEqual(values["HASS_TOKEN"], "secret value")
        self.assertNotIn("NOT VALID", values)

    def test_open_and_close_pulse_only_the_allowlisted_ajax_relay(self):
        for action in ("open", "close"):
            with self.subTest(action=action):
                hb._gate_last_accepted_at = 0.0
                opener = mock.Mock(side_effect=[
                    self.FakeResponse(b'{"state":"off"}'),
                    self.FakeResponse(b"[]"),
                ])
                with mock.patch.object(hb, "AUTH_TOKEN", "bridge-secret"), \
                     mock.patch.object(
                         hb, "_home_assistant_config",
                         return_value=(
                             "http://127.0.0.1:8123", "ha-secret"
                         ),
                     ), mock.patch.object(
                         hb, "GATE_ENTITY", "switch.gate_relay"
                     ), mock.patch.object(
                         hb.time, "monotonic", return_value=100.0
                     ), mock.patch.object(
                         hb.urllib.request, "urlopen", opener
                     ):
                    accepted, message = hb.activate_gate_relay(action)

                self.assertTrue(accepted)
                self.assertIn("accepted", message.lower())
                state_request = opener.call_args_list[0].args[0]
                self.assertEqual(
                    state_request.full_url,
                    "http://127.0.0.1:8123/api/states/switch.gate_relay",
                )
                pulse_request = opener.call_args_list[1].args[0]
                self.assertEqual(
                    pulse_request.full_url,
                    "http://127.0.0.1:8123/api/services/switch/turn_on",
                )
                self.assertEqual(
                    json.loads(pulse_request.data.decode()),
                    {"entity_id": "switch.gate_relay"},
                )
                self.assertEqual(opener.call_count, 2)

    def test_duplicate_command_is_cooled_down(self):
        opener = mock.Mock(side_effect=[
            self.FakeResponse(b'{"state":"off"}'),
            self.FakeResponse(b"[]"),
        ])
        with mock.patch.object(hb, "AUTH_TOKEN", "bridge-secret"), \
             mock.patch.object(
                 hb, "_home_assistant_config",
                 return_value=("http://127.0.0.1:8123", "ha-secret"),
             ), mock.patch.object(hb, "GATE_ENTITY", "switch.gate_relay"), \
             mock.patch.object(
                 hb.time, "monotonic", side_effect=[100.0, 101.0]
             ), mock.patch.object(hb.urllib.request, "urlopen", opener):
            first = hb.activate_gate_relay("open")
            second = hb.activate_gate_relay("close")

        self.assertTrue(first[0])
        self.assertTrue(second[0])
        self.assertIn("already", second[1].lower())
        self.assertEqual(opener.call_count, 2)

    def test_unavailable_relay_is_not_activated(self):
        opener = mock.Mock(
            return_value=self.FakeResponse(b'{"state":"unavailable"}')
        )
        with mock.patch.object(hb, "AUTH_TOKEN", "bridge-secret"), \
             mock.patch.object(
                 hb, "_home_assistant_config",
                 return_value=("http://127.0.0.1:8123", "ha-secret"),
             ), mock.patch.object(hb, "GATE_ENTITY", "switch.gate_relay"), \
             mock.patch.object(hb.urllib.request, "urlopen", opener):
            accepted, message = hb.activate_gate_relay("open")

        self.assertFalse(accepted)
        self.assertIn("unavailable", message.lower())
        self.assertEqual(opener.call_count, 1)

    def test_gate_control_fails_closed_without_bridge_auth(self):
        with mock.patch.object(hb, "AUTH_TOKEN", ""):
            accepted, message = hb.activate_gate_relay("open")
        self.assertFalse(accepted)
        self.assertIn("authenticated", message.lower())

    def test_home_assistant_failure_does_not_claim_gate_position(self):
        with mock.patch.object(hb, "AUTH_TOKEN", "bridge-secret"), \
             mock.patch.object(
                 hb, "_home_assistant_config",
                 return_value=("http://127.0.0.1:8123", "ha-secret"),
             ), mock.patch.object(hb, "GATE_ENTITY", "switch.gate_relay"), \
             mock.patch.object(
                 hb.urllib.request, "urlopen",
                 side_effect=urllib.error.URLError("offline"),
             ):
            accepted, message = hb.activate_gate_relay("close")

        self.assertFalse(accepted)
        self.assertIn("failed", message.lower())
        self.assertNotIn("opened", message.lower())
        self.assertNotIn("closed", message.lower())


class FakeWebSocket:
    """Minimal stand-in exposing recv()/send() like websockets."""

    def __init__(self, messages):
        self._messages = list(messages)
        self.sent = []

    async def recv(self):
        if not self._messages:
            await asyncio.sleep(30)  # simulate silence until timeout
        return self._messages.pop(0)

    async def send(self, message):
        self.sent.append(message)


class AuthWebSocket:
    """Minimal request surface used by the bridge auth tests."""

    def __init__(self, authorization=None, path="/voice"):
        headers = {}
        if authorization is not None:
            headers["Authorization"] = authorization
        self.request = SimpleNamespace(path=path, headers=headers)


class ConnectionWebSocket:
    """Small async-iterable websocket for handshake tests."""

    def __init__(self, messages=()):
        self.messages = iter(messages)
        self.sent = []
        self.closed = None
        self.request = SimpleNamespace(path="/voice", headers={
            "Authorization": "Bearer test-token",
        })
        self.remote_address = ("127.0.0.1", 12345)

    def __aiter__(self):
        return self

    async def __anext__(self):
        try:
            return next(self.messages)
        except StopIteration:
            raise StopAsyncIteration

    async def send(self, message):
        self.sent.append(message)

    async def close(self, code=None, reason=None):
        self.closed = (code, reason)


class StreamWebSocket:
    """Queue-backed socket covering recv(), iteration, send(), and close()."""

    def __init__(self, frames=()):
        self.frames = list(frames)
        self.sent = []
        self.closed = False

    async def recv(self):
        if not self.frames:
            raise RuntimeError("No frame available")
        return self.frames.pop(0)

    def __aiter__(self):
        return self

    async def __anext__(self):
        if not self.frames:
            raise StopAsyncIteration
        return self.frames.pop(0)

    async def send(self, message):
        self.sent.append(message)

    async def close(self):
        self.closed = True


class TestAwaitPhoto(unittest.TestCase):
    def test_photo_message_returns_decoded_bytes(self):
        jpeg = b"\xff\xd8\xff\xe0fakejpeg"
        ws = FakeWebSocket([
            b"\x00\x01binary-mic-audio-to-skip",
            '{"type":"debug","msg":"ignored"}',
            '{"type":"photo","data":"%s"}' % base64.b64encode(jpeg).decode(),
        ])
        result = asyncio.run(await_photo(ws, timeout=2.0))
        self.assertEqual(result, jpeg)

    def test_photo_error_returns_none(self):
        ws = FakeWebSocket(['{"type":"photo_error","message":"no camera"}'])
        result = asyncio.run(await_photo(ws, timeout=2.0))
        self.assertIsNone(result)

    def test_timeout_returns_none(self):
        ws = FakeWebSocket([])
        result = asyncio.run(await_photo(ws, timeout=0.2))
        self.assertIsNone(result)

    def test_malformed_json_frame_ignored_keeps_waiting(self):
        # A malformed text frame must not raise / abort the wait - it should
        # be logged and skipped, leaving the loop to pick up the next frame.
        jpeg = b"\xff\xd8\xff\xe0fakejpeg"
        ws = FakeWebSocket([
            "{not valid json",
            '{"type":"photo","data":"%s"}' % base64.b64encode(jpeg).decode(),
        ])
        result = asyncio.run(await_photo(ws, timeout=2.0))
        self.assertEqual(result, jpeg)

    def test_non_dict_json_frame_ignored_keeps_waiting(self):
        # Valid JSON that isn't an object (e.g. a bare array) must not raise
        # AttributeError from `.get` - it should be skipped like malformed
        # JSON.
        jpeg = b"\xff\xd8\xff\xe0fakejpeg"
        ws = FakeWebSocket([
            "[1]",
            '{"type":"photo","data":"%s"}' % base64.b64encode(jpeg).decode(),
        ])
        result = asyncio.run(await_photo(ws, timeout=2.0))
        self.assertEqual(result, jpeg)


class TestProcessQuery(unittest.TestCase):
    """process_query: text in → hermes → response + TTS out, incl. photo path."""

    def _run(self, text, ws, fake_reply="ok", fake_tts=b"\x00\x00",
             stored_session=None, bridge_tts=True):
        orig_ask, orig_tts = hb.ask_hermes, hb.synthesize_speech
        orig_bridge_tts = hb.BRIDGE_TTS
        orig_bridge_vision = hb.BRIDGE_VISION
        hb.BRIDGE_TTS = bridge_tts
        # The local development .env intentionally disables vision for Adam.
        # These legacy-path tests must pin their own capability instead of
        # changing behavior based on a developer's ignored runtime config.
        hb.BRIDGE_VISION = True
        # Pin the brain so an exported HERMES_BRIDGE_BRAIN can't route this
        # around the fake ask_hermes (KeyError, or a real HTTP call).
        orig_brain = hb.BRAIN
        hb.BRAIN = "hermes"
        orig_session_file = hb.SESSION_FILE
        tmp = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        tmp.close()
        os.unlink(tmp.name)  # start with no stored session
        hb.SESSION_FILE = tmp.name
        if stored_session:
            hb.store_session(stored_session)
        calls = {}

        def fake_ask(query, image_path=None, resume=None):
            calls["query"] = query
            calls["image_path"] = image_path
            calls["resume"] = resume
            return fake_reply, "20260710_000000_test"

        hb.ask_hermes = fake_ask
        hb.synthesize_speech = lambda t: fake_tts
        try:
            asyncio.run(hb.process_query(ws, text))
        finally:
            hb.ask_hermes, hb.synthesize_speech = orig_ask, orig_tts
            hb.BRIDGE_TTS = orig_bridge_tts
            hb.BRIDGE_VISION = orig_bridge_vision
            hb.BRAIN = orig_brain
            try:
                os.unlink(tmp.name)
            except OSError:
                pass
            hb.SESSION_FILE = orig_session_file
        return calls

    def test_default_no_bridge_tts(self):
        ws = FakeWebSocket([])
        self._run("tell me a joke", ws, bridge_tts=False)
        sent = [m for m in ws.sent if isinstance(m, str)]
        self.assertTrue(any('"tts": false' in m for m in sent))
        self.assertFalse(any('"audio_start"' in m for m in sent))
        self.assertFalse(any('"audio_end"' in m for m in sent))

    def test_plain_query_answers_without_photo(self):
        ws = FakeWebSocket([])
        calls = self._run("tell me a joke", ws)
        # Fresh session → persona preamble prefixed
        self.assertTrue(calls["query"].endswith("tell me a joke"))
        self.assertIn("voice assistant", calls["query"])
        self.assertIsNone(calls["resume"])
        self.assertIsNone(calls["image_path"])
        sent_types = [m for m in ws.sent if isinstance(m, str)]
        self.assertFalse(any('"capture_photo"' in m for m in sent_types))
        self.assertTrue(any('"response"' in m for m in sent_types))
        self.assertTrue(any('"audio_end"' in m for m in sent_types))

    def test_resumed_session_keeps_persona_and_locale(self):
        ws = FakeWebSocket([])
        calls = self._run("tell me a joke", ws, stored_session="sid123")
        self.assertTrue(calls["query"].endswith("tell me a joke"))
        self.assertIn("Reply in British English", calls["query"])
        self.assertEqual(calls["resume"], "sid123")

    def test_visual_query_requests_photo_and_passes_image(self):
        jpeg = b"\xff\xd8\xff\xe0fakejpeg"
        ws = FakeWebSocket([
            '{"type":"photo","data":"%s"}' % base64.b64encode(jpeg).decode(),
        ])
        calls = self._run("what am I looking at", ws)
        self.assertTrue(any('"capture_photo"' in m
                            for m in ws.sent if isinstance(m, str)))
        self.assertIsNotNone(calls["image_path"])
        self.assertTrue(calls["query"].endswith("what am I looking at"))

    def test_visual_query_photo_error_falls_back_to_text(self):
        ws = FakeWebSocket(['{"type":"photo_error","message":"no camera"}'])
        calls = self._run("what am I looking at", ws)
        self.assertIsNone(calls["image_path"])
        self.assertIn("No photo could be captured", calls["query"])

    def test_gate_command_activates_relay_without_calling_agent(self):
        ws = FakeWebSocket([])
        with mock.patch.object(
            hb, "activate_gate_relay",
            return_value=(True, "Gate relay activation command accepted."),
        ) as activate, mock.patch.object(hb, "ask_hermes") as ask:
            asyncio.run(
                hb.process_query(ws, "open gates", want_tts=False)
            )

        activate.assert_called_once_with("open")
        ask.assert_not_called()
        responses = [
            json.loads(message) for message in ws.sent
            if isinstance(message, str)
            and json.loads(message).get("type") == "response"
        ]
        self.assertEqual(len(responses), 1)
        self.assertEqual(
            responses[0]["text"],
            "Gate relay activation command accepted.",
        )
        self.assertFalse(responses[0]["tts"])

    def test_exact_open_and_close_commands_both_trigger_ajax_relay(self):
        for command, action in (("open gates", "open"),
                                ("close gates", "close")):
            with self.subTest(command=command):
                ws = FakeWebSocket([])
                with mock.patch.object(
                    hb, "activate_gate_relay",
                    return_value=(
                        True, "Gate relay activation command accepted."
                    ),
                ) as activate, mock.patch.object(hb, "ask_hermes") as ask:
                    asyncio.run(
                        hb.process_query(ws, command, want_tts=False)
                    )
                activate.assert_called_once_with(action)
                ask.assert_not_called()


class TestSessionStore(unittest.TestCase):
    def setUp(self):
        self.hb = hb
        self.tmp = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        self.tmp.close()
        self.orig = hb.SESSION_FILE
        hb.SESSION_FILE = self.tmp.name

    def tearDown(self):
        self.hb.SESSION_FILE = self.orig
        try:
            os.unlink(self.tmp.name)
        except OSError:
            pass

    def test_store_and_load_same_day(self):
        self.hb.store_session("20260710_120000_abc123")
        self.assertEqual(self.hb.load_session(), "20260710_120000_abc123")

    def test_stale_session_not_loaded(self):
        import json as j
        with open(self.tmp.name, "w") as f:
            j.dump({"session_id": "old", "date": "2020-01-01"}, f)
        self.assertIsNone(self.hb.load_session())

    def test_legacy_session_without_voice_profile_is_not_loaded(self):
        with open(self.tmp.name, "w") as f:
            json.dump({"session_id": "legacy", "date": hb._today()}, f)
        self.assertIsNone(self.hb.load_session())

    def test_session_with_changed_voice_profile_is_not_loaded(self):
        with open(self.tmp.name, "w") as f:
            json.dump({
                "session_id": "wrong-profile",
                "date": hb._today(),
                "voice_profile": "different",
            }, f)
        self.assertIsNone(self.hb.load_session())

    def test_clear(self):
        self.hb.store_session("x")
        self.hb.clear_session()
        self.assertIsNone(self.hb.load_session())


class TestSessionIdExtraction(unittest.TestCase):
    def test_extracts_from_stderr(self):
        from hermes_bridge import extract_session_id
        self.assertEqual(
            extract_session_id("\nsession_id: 20260710_162225_7c1fec\n"),
            "20260710_162225_7c1fec",
        )
        self.assertIsNone(extract_session_id("no id here"))


class TestShouldCapturePhoto(unittest.TestCase):
    def test_explicit_keyword_always_captures(self):
        from hermes_bridge import should_capture_photo
        self.assertTrue(should_capture_photo("take a picture", 100.0, 110.0))

    def test_deictic_triggers_capture(self):
        from hermes_bridge import should_capture_photo
        for phrase in ["how do I make this drink", "what's that building",
                       "is the one on the left better"]:
            self.assertTrue(should_capture_photo(phrase, 0.0, 1000.0), phrase)

    def test_deictic_suppressed_by_recent_photo(self):
        from hermes_bridge import should_capture_photo
        # photo 30s ago → deictic follow-up uses memory, no re-capture
        self.assertFalse(
            should_capture_photo("how do I make this drink", 970.0, 1000.0))

    def test_non_visual_never_captures(self):
        from hermes_bridge import should_capture_photo
        self.assertFalse(should_capture_photo("tell me a joke", 0.0, 1000.0))


# Tests for the retained legacy SDK helper (ask_claude / build_claude_user_content
# / trim_claude_history) - not on the live request path, which now goes through
# ask_provider()/build_provider_request(); kept for reference.
class TestClaudeBrain(unittest.TestCase):
    def test_user_content_text_only(self):
        from hermes_bridge import build_claude_user_content
        content = build_claude_user_content("hello there", None)
        self.assertEqual(content, [{"type": "text", "text": "hello there"}])

    def test_user_content_with_photo(self):
        from hermes_bridge import build_claude_user_content
        content = build_claude_user_content("what is this", b"\xff\xd8jpegbytes")
        self.assertEqual(content[0]["type"], "image")
        self.assertEqual(content[0]["source"]["type"], "base64")
        self.assertEqual(content[0]["source"]["media_type"], "image/jpeg")
        self.assertEqual(content[1], {"type": "text", "text": "what is this"})

    def test_history_trimmed_to_cap(self):
        from hermes_bridge import trim_claude_history
        history = [{"role": "user", "content": f"m{i}"} for i in range(100)]
        trimmed = trim_claude_history(history, max_messages=40)
        self.assertEqual(len(trimmed), 40)
        self.assertEqual(trimmed[-1]["content"], "m99")

    def test_claude_history_store_same_day(self):
        tmp = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        tmp.close()
        os.unlink(tmp.name)
        orig = hb.CLAUDE_HISTORY_FILE
        hb.CLAUDE_HISTORY_FILE = tmp.name
        try:
            hb.store_claude_history([{"role": "user", "content": "hi"}])
            self.assertEqual(len(hb.load_claude_history()), 1)
            hb.clear_claude_history()
            self.assertEqual(hb.load_claude_history(), [])
        finally:
            try:
                os.unlink(tmp.name)
            except OSError:
                pass
            hb.CLAUDE_HISTORY_FILE = orig


class ProviderRequestTests(unittest.TestCase):
    def test_anthropic_request_shape(self):
        url, headers, body = build_provider_request(
            "anthropic", "claude-opus-4-8", "https://api.anthropic.com",
            "sk-ant", "hello", None)
        self.assertEqual(url, "https://api.anthropic.com/v1/messages")
        self.assertEqual(headers["x-api-key"], "sk-ant")
        self.assertEqual(body["model"], "claude-opus-4-8")

    def test_anthropic_request_has_persona_system_prompt(self):
        from hermes_bridge import CLAUDE_SYSTEM
        _, _, body = build_provider_request(
            "anthropic", "claude-opus-4-8", "https://api.anthropic.com",
            "sk-ant", "hello", None)
        self.assertIsInstance(body["system"], str)
        self.assertTrue(body["system"])
        self.assertEqual(body["system"], CLAUDE_SYSTEM)

    def test_openai_request_shape_with_image(self):
        url, headers, body = build_provider_request(
            "openai", "gpt-4o", "https://api.openai.com", "sk-oai", "look", "QUJD")
        self.assertEqual(url, "https://api.openai.com/v1/chat/completions")
        self.assertEqual(headers["Authorization"], "Bearer sk-oai")
        content = body["messages"][-1]["content"]
        self.assertTrue(any(p.get("type") == "image_url" for p in content))

    def test_openai_request_has_persona_system_message_first(self):
        from hermes_bridge import CLAUDE_SYSTEM
        _, _, body = build_provider_request(
            "openai", "gpt-4o", "https://api.openai.com", "sk-oai", "look", None)
        self.assertEqual(body["messages"][0],
                          {"role": "system", "content": CLAUDE_SYSTEM})

    def test_gemini_request_shape(self):
        url, headers, body = build_provider_request(
            "gemini", "gemini-2.5-flash",
            "https://generativelanguage.googleapis.com", "g-key", "hi", None)
        self.assertTrue(url.endswith(":generateContent"))
        # The key belongs in a header, not the query string (proxy logs).
        self.assertNotIn("key=", url)
        self.assertEqual(headers["x-goog-api-key"], "g-key")

    def test_gemini_request_has_persona_system_instruction(self):
        _, _, body = build_provider_request(
            "gemini", "gemini-2.5-flash",
            "https://generativelanguage.googleapis.com", "g-key", "hi", None)
        text = body["systemInstruction"]["parts"][0]["text"]
        self.assertIsInstance(text, str)
        self.assertTrue(text)

    def test_parse_replies(self):
        self.assertEqual(
            parse_provider_reply("anthropic", 200,
                b'{"content":[{"type":"text","text":"a"}]}'), "a")
        self.assertEqual(
            parse_provider_reply("openai", 200,
                b'{"choices":[{"message":{"content":"b"}}]}'), "b")
        self.assertEqual(
            parse_provider_reply("gemini", 200,
                b'{"candidates":[{"content":{"parts":[{"text":"c"}]}}]}'), "c")

    def test_claude_is_alias_for_anthropic(self):
        url, _, _ = build_provider_request(
            "claude", "claude-opus-4-8", "https://api.anthropic.com", "k", "hi", None)
        self.assertTrue(url.endswith("/v1/messages"))


class BridgeConfigurationTests(unittest.TestCase):
    def test_supported_locales_and_unknown_locale_fallback(self):
        self.assertEqual(hb.sanitize_locale("en-US"), "en-US")
        self.assertEqual(hb.sanitize_locale("en-GB"), "en-GB")
        self.assertEqual(hb.sanitize_locale("lv-LV"), "lv-LV")
        self.assertEqual(hb.sanitize_locale("fr-FR"), "en-GB")
        self.assertEqual(hb.sanitize_locale(None), "en-GB")

    def test_startup_requires_non_blank_auth_token(self):
        original = hb.AUTH_TOKEN
        try:
            hb.AUTH_TOKEN = "  "
            with self.assertRaisesRegex(RuntimeError, "HERMES_BRIDGE_TOKEN"):
                hb.validate_startup_config()
        finally:
            hb.AUTH_TOKEN = original

    def test_startup_accepts_auth_token(self):
        original = hb.AUTH_TOKEN
        try:
            hb.AUTH_TOKEN = "test-token"
            self.assertIsNone(hb.validate_startup_config())
        finally:
            hb.AUTH_TOKEN = original


class BridgeAuthenticationTests(unittest.TestCase):
    def setUp(self):
        self.original = hb.AUTH_TOKEN
        hb.AUTH_TOKEN = "test-token"

    def tearDown(self):
        hb.AUTH_TOKEN = self.original

    def test_missing_bearer_header_is_rejected(self):
        self.assertFalse(hb.is_authorized(AuthWebSocket()))

    def test_wrong_bearer_token_is_rejected(self):
        self.assertFalse(hb.is_authorized(AuthWebSocket("Bearer wrong")))

    def test_correct_bearer_token_is_accepted(self):
        self.assertTrue(hb.is_authorized(AuthWebSocket("Bearer test-token")))

    def test_query_string_token_is_rejected(self):
        self.assertFalse(hb.is_authorized(
            AuthWebSocket(path="/voice?token=test-token")))

    def test_query_string_is_rejected_even_with_valid_bearer_header(self):
        self.assertFalse(hb.is_authorized(AuthWebSocket(
            "Bearer test-token",
            path="/voice?token=test-token",
        )))


class BridgeVisionTests(unittest.TestCase):
    def test_disabled_visual_query_never_requests_photo_or_calls_hermes(self):
        original = hb.BRIDGE_VISION
        hb.BRIDGE_VISION = False
        ws = FakeWebSocket([])
        with mock.patch.object(hb, "ask_hermes",
                               side_effect=AssertionError("Hermes called")):
            try:
                asyncio.run(hb.process_query(ws, "what am I looking at"))
            finally:
                hb.BRIDGE_VISION = original
        sent = [json.loads(item) for item in ws.sent if isinstance(item, str)]
        self.assertEqual([item["type"] for item in sent], ["response"])
        self.assertFalse(any(item.get("type") == "capture_photo" for item in sent))
        self.assertEqual(sent[0]["text"], hb.VISION_DISABLED_RESPONSE)

    def test_disabled_visual_query_uses_selected_locale(self):
        original = hb.BRIDGE_VISION
        hb.BRIDGE_VISION = False
        ws = FakeWebSocket([])
        try:
            asyncio.run(hb.process_query(ws, "what am I looking at?",
                                         locale="lv-LV"))
        finally:
            hb.BRIDGE_VISION = original
        payload = json.loads(ws.sent[0])
        self.assertEqual(payload["text"], "Kameras piekļuve ir atspējota.")

class BridgeWelcomeTests(unittest.TestCase):
    def test_welcome_advertises_vision_capability(self):
        original = hb.BRIDGE_VISION
        try:
            hb.BRIDGE_VISION = False
            payload = json.loads(hb.welcome_message())
            self.assertEqual(payload["protocol"], 2)
            self.assertFalse(payload["capabilities"]["vision"])
            self.assertTrue(payload["capabilities"]["audio_upload"])
            self.assertTrue(payload["capabilities"]["server_stt"])
            self.assertTrue(payload["capabilities"]["streaming_tts"])
            self.assertTrue(payload["capabilities"]["turn_cancel"])
            self.assertTrue(payload["capabilities"]["follow_up_mode"])
            hb.BRIDGE_VISION = True
            payload = json.loads(hb.welcome_message())
            self.assertTrue(payload["capabilities"]["vision"])
        finally:
            hb.BRIDGE_VISION = original

    def test_handler_sends_capabilities_in_welcome_frame(self):
        original_token = hb.AUTH_TOKEN
        original_vision = hb.BRIDGE_VISION
        hb.AUTH_TOKEN = "test-token"
        hb.BRIDGE_VISION = False
        websocket = ConnectionWebSocket()
        try:
            asyncio.run(hb.handle_connection(websocket))
        finally:
            hb.AUTH_TOKEN = original_token
            hb.BRIDGE_VISION = original_vision
        self.assertFalse(json.loads(websocket.sent[0])["capabilities"]["vision"])


class BridgeHermesPrivateBackendTests(unittest.TestCase):
    @staticmethod
    def _response(html):
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = html.encode("utf-8")
        return response

    def test_loopback_detection_is_strict(self):
        for value in (
            "http://127.0.0.1:9119", "https://localhost:9119", "http://[::1]",
        ):
            self.assertTrue(hb._loopback_http_base(value), value)
        for value in (
            "https://adam.example.com", "file:///tmp/hermes", "not a url",
        ):
            self.assertFalse(hb._loopback_http_base(value), value)

    def test_websocket_uses_backend_selected_during_token_resolution(self):
        api = hb.HermesLocalAPI("http://127.0.0.1:9119")

        def select_private_backend():
            api.base_url = "http://127.0.0.1:54321"
            return "private-token"

        with mock.patch.object(api, "token", side_effect=select_private_backend):
            url = api.websocket_url("/api/audio/speak-stream")

        parsed = hb.urllib.parse.urlsplit(url)
        self.assertEqual(parsed.scheme, "ws")
        self.assertEqual(parsed.hostname, "127.0.0.1")
        self.assertEqual(parsed.port, 54321)
        self.assertEqual(
            hb.urllib.parse.parse_qs(parsed.query),
            {"token": ["private-token"]},
        )

    def test_private_python_keeps_venv_symlink_and_checkout_root(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            agent_root = Path(temp_dir) / "hermes-agent"
            interpreter = agent_root / ".venv" / "bin" / "python"
            interpreter.parent.mkdir(parents=True)
            interpreter.symlink_to(Path(sys.executable).resolve())

            python, discovered_root = hb._hermes_private_paths(str(interpreter))

        self.assertEqual(python, interpreter)
        self.assertEqual(discovered_root, agent_root)

    def test_existing_dashboard_token_is_used_without_private_backend(self):
        html = '<script>window.__HERMES_SESSION_TOKEN__ = "fixed-token";</script>'
        api = hb.HermesLocalAPI("http://127.0.0.1:9119")
        with mock.patch.object(
            hb.urllib.request, "urlopen", return_value=self._response(html)
        ), mock.patch.object(hb._PRIVATE_BACKEND, "ensure") as ensure:
            self.assertEqual(api.token(), "fixed-token")
        ensure.assert_not_called()
        self.assertEqual(api.base_url, "http://127.0.0.1:9119")

    def test_loopback_login_page_uses_private_backend(self):
        api = hb.HermesLocalAPI("http://127.0.0.1:9119")
        with mock.patch.object(hb, "HERMES_PRIVATE_BACKEND", "auto"), \
             mock.patch.object(
                 hb.urllib.request, "urlopen",
                 return_value=self._response("<html>Sign in</html>"),
             ), mock.patch.object(
                 hb._PRIVATE_BACKEND, "ensure",
                 return_value=("http://127.0.0.1:54321", "private-token"),
             ) as ensure:
            self.assertEqual(api.token(), "private-token")
        ensure.assert_called_once_with()
        self.assertEqual(api.base_url, "http://127.0.0.1:54321")

    def test_unavailable_loopback_service_uses_private_backend(self):
        api = hb.HermesLocalAPI("http://127.0.0.1:9119")
        with mock.patch.object(hb, "HERMES_PRIVATE_BACKEND", "auto"), \
             mock.patch.object(
                 hb.urllib.request, "urlopen",
                 side_effect=hb.urllib.error.URLError("offline"),
             ), mock.patch.object(
                 hb._PRIVATE_BACKEND, "ensure",
                 return_value=("http://127.0.0.1:54322", "private-token"),
             ) as ensure:
            self.assertEqual(api.token(), "private-token")
        ensure.assert_called_once_with()

    def test_remote_login_page_never_starts_private_backend(self):
        api = hb.HermesLocalAPI("https://adam.example.com")
        with mock.patch.object(hb, "HERMES_PRIVATE_BACKEND", "auto"), \
             mock.patch.object(
                 hb.urllib.request, "urlopen",
                 return_value=self._response("<html>Sign in</html>"),
             ), mock.patch.object(hb._PRIVATE_BACKEND, "ensure") as ensure:
            with self.assertRaisesRegex(RuntimeError, "session token"):
                api.token()
        ensure.assert_not_called()

    def test_prewarm_loads_local_stt_with_silence(self):
        with mock.patch.object(hb, "HermesLocalAPI") as api_type:
            self.assertTrue(hb.prewarm_voice_backend())

        api = api_type.return_value
        api.transcribe.assert_called_once()
        pcm, locale, vocabulary = api.transcribe.call_args.args
        self.assertEqual(len(pcm), hb.HERMES_AUDIO_SAMPLE_RATE)
        self.assertEqual(locale, "en-GB")
        self.assertIn("Adam", vocabulary)


class BridgeAudioProtocolTests(unittest.TestCase):
    def setUp(self):
        self.original_token = hb.AUTH_TOKEN
        hb.AUTH_TOKEN = "test-token"

    def tearDown(self):
        hb.AUTH_TOKEN = self.original_token

    def test_pcm_capture_is_bounded_and_routed_to_realtime_turn(self):
        request_id = "turn-audio-1"
        websocket = ConnectionWebSocket([
            json.dumps({
                "type": "audio_start",
                "request_id": request_id,
                "format": "pcm_s16le",
                "sample_rate": 16_000,
                "channels": 1,
                "locale": "en-GB",
                "vocabulary": ["Tailscale", "Ray-Ban Meta"],
                "follow_up": True,
            }),
            b"\x01\x00" * 320,
            json.dumps({"type": "audio_end", "request_id": request_id}),
        ])
        realtime_turn = mock.AsyncMock()

        with mock.patch.object(hb, "process_audio_turn", realtime_turn):
            asyncio.run(hb.handle_connection(websocket))

        realtime_turn.assert_awaited_once()
        capture = realtime_turn.await_args.args[1]
        self.assertEqual(capture["request_id"], request_id)
        self.assertEqual(capture["locale"], "en-GB")
        self.assertEqual(capture["vocabulary"], ["Tailscale", "Ray-Ban Meta"])
        self.assertTrue(capture["follow_up"])
        self.assertEqual(bytes(capture["pcm"]), b"\x01\x00" * 320)
        payloads = [json.loads(item) for item in websocket.sent if isinstance(item, str)]
        self.assertEqual(payloads[1], {"type": "audio_ready", "request_id": request_id})

    def test_wrong_capture_format_is_rejected_without_starting_turn(self):
        websocket = ConnectionWebSocket([json.dumps({
            "type": "audio_start",
            "request_id": "bad-format",
            "format": "aac",
            "sample_rate": 44_100,
            "channels": 2,
        })])
        realtime_turn = mock.AsyncMock()

        with mock.patch.object(hb, "process_audio_turn", realtime_turn):
            asyncio.run(hb.handle_connection(websocket))

        realtime_turn.assert_not_awaited()
        error = json.loads(websocket.sent[1])
        self.assertEqual(error["type"], "error")
        self.assertEqual(error["request_id"], "bad-format")
        self.assertIn("16000 Hz", error["message"])

    def test_follow_up_defaults_false_for_old_clients(self):
        request_id = "old-client-turn"
        websocket = ConnectionWebSocket([
            json.dumps({
                "type": "audio_start",
                "request_id": request_id,
                "format": "pcm_s16le",
                "sample_rate": 16_000,
                "channels": 1,
            }),
            b"\x01\x00" * 320,
            json.dumps({"type": "audio_end", "request_id": request_id}),
        ])
        realtime_turn = mock.AsyncMock()

        with mock.patch.object(hb, "process_audio_turn", realtime_turn):
            asyncio.run(hb.handle_connection(websocket))

        self.assertFalse(realtime_turn.await_args.args[1]["follow_up"])

    def test_non_boolean_follow_up_is_rejected(self):
        websocket = ConnectionWebSocket([json.dumps({
            "type": "audio_start",
            "request_id": "bad-follow-up",
            "format": "pcm_s16le",
            "sample_rate": 16_000,
            "channels": 1,
            "follow_up": "yes",
        })])

        asyncio.run(hb.handle_connection(websocket))

        error = json.loads(websocket.sent[1])
        self.assertEqual(error["type"], "error")
        self.assertIn("boolean", error["message"])

    def test_finish_phrase_defaults_false_for_old_clients(self):
        websocket = ConnectionWebSocket([
            json.dumps({
                "type": "audio_start",
                "request_id": "old-finish-client",
                "format": "pcm_s16le",
                "sample_rate": 16_000,
                "channels": 1,
            }),
            b"\x01\x00" * 320,
            json.dumps({"type": "audio_end", "request_id": "old-finish-client"}),
        ])
        realtime_turn = mock.AsyncMock()
        with mock.patch.object(hb, "process_audio_turn", realtime_turn):
            asyncio.run(hb.handle_connection(websocket))
        self.assertFalse(realtime_turn.await_args.args[1]["finish_phrase"])

    def test_non_boolean_finish_phrase_is_rejected(self):
        websocket = ConnectionWebSocket([json.dumps({
            "type": "audio_start",
            "request_id": "bad-finish-phrase",
            "format": "pcm_s16le",
            "sample_rate": 16_000,
            "channels": 1,
            "finish_phrase": "yes",
        })])
        asyncio.run(hb.handle_connection(websocket))
        error = json.loads(websocket.sent[1])
        self.assertEqual(error["type"], "error")
        self.assertIn("boolean", error["message"])

    def test_finish_phrase_is_forwarded_when_true(self):
        websocket = ConnectionWebSocket([
            json.dumps({
                "type": "audio_start",
                "request_id": "finish-client",
                "format": "pcm_s16le",
                "sample_rate": 16_000,
                "channels": 1,
                "finish_phrase": True,
            }),
            b"\x01\x00" * 320,
            json.dumps({"type": "audio_end", "request_id": "finish-client"}),
        ])
        realtime_turn = mock.AsyncMock()
        with mock.patch.object(hb, "process_audio_turn", realtime_turn):
            asyncio.run(hb.handle_connection(websocket))
        self.assertTrue(realtime_turn.await_args.args[1]["finish_phrase"])


    def test_pcm_wav_wrapper_has_expected_wire_format(self):
        import io
        import wave

        pcm = b"\x01\x00" * 320
        with wave.open(io.BytesIO(hb.pcm16_wav(pcm)), "rb") as wav:
            self.assertEqual(wav.getnchannels(), 1)
            self.assertEqual(wav.getsampwidth(), 2)
            self.assertEqual(wav.getframerate(), 16_000)
            self.assertEqual(wav.readframes(wav.getnframes()), pcm)

    def test_local_api_threads_locale_and_vocabulary_prompt(self):
        api = hb.HermesLocalAPI("http://127.0.0.1:9119")
        captured = {}

        def fake_post(path, payload):
            captured.update({"path": path, "payload": payload})
            return {"success": True, "provider": "local", "transcript": "Adam, hello."}

        api._post_json = fake_post
        result = api.transcribe(b"\x00\x00" * 320, "en-GB", ["Vandret"])

        self.assertEqual(result["transcript"], "hello.")
        self.assertEqual(captured["path"], "/api/audio/transcribe")
        self.assertEqual(captured["payload"]["language"], "en")
        self.assertIn("Vandret", captured["payload"]["prompt"])
        self.assertTrue(captured["payload"]["data_url"].startswith("data:audio/wav;base64,"))

    def test_cancel_turn_stops_task_and_interrupts_gateway(self):
        async def run():
            started = asyncio.Event()
            gateway = mock.AsyncMock()

            class YieldingConnection(ConnectionWebSocket):
                async def __anext__(self):
                    value = await super().__anext__()
                    if isinstance(value, str) and '"type": "cancel_turn"' in value:
                        await started.wait()
                    else:
                        await asyncio.sleep(0)
                    return value

            request_id = "cancel-me"
            websocket = YieldingConnection([
                json.dumps({
                    "type": "audio_start",
                    "request_id": request_id,
                    "format": "pcm_s16le",
                    "sample_rate": 16_000,
                    "channels": 1,
                }),
                b"\x01\x00" * 320,
                json.dumps({"type": "audio_end", "request_id": request_id}),
                json.dumps({"type": "cancel_turn", "request_id": request_id}),
            ])

            async def blocked_turn(_websocket, _capture, state):
                state["gateway"] = gateway
                started.set()
                await asyncio.Future()

            with mock.patch.object(hb, "process_audio_turn", side_effect=blocked_turn):
                await hb.handle_connection(websocket)
            return websocket, gateway

        websocket, gateway = asyncio.run(run())
        gateway.interrupt.assert_awaited_once()
        payloads = [
            json.loads(item) for item in websocket.sent if isinstance(item, str)
        ]
        self.assertIn(
            {"type": "turn_cancelled", "request_id": "cancel-me"}, payloads
        )

    def test_cancel_during_upload_drains_queued_frames_without_errors(self):
        request_id = "cancel-upload"
        websocket = ConnectionWebSocket([
            json.dumps({
                "type": "audio_start",
                "request_id": request_id,
                "format": "pcm_s16le",
                "sample_rate": 16_000,
                "channels": 1,
            }),
            json.dumps({"type": "cancel_turn", "request_id": request_id}),
            b"\x01\x00" * 320,
            json.dumps({"type": "audio_end", "request_id": request_id}),
        ])
        realtime_turn = mock.AsyncMock()

        with mock.patch.object(hb, "process_audio_turn", realtime_turn):
            asyncio.run(hb.handle_connection(websocket))

        realtime_turn.assert_not_awaited()
        payloads = [
            json.loads(item) for item in websocket.sent if isinstance(item, str)
        ]
        self.assertIn(
            {"type": "turn_cancelled", "request_id": request_id}, payloads
        )
        self.assertFalse(any(item.get("type") == "error" for item in payloads))

    def test_cancel_after_server_completion_is_idempotent_for_playback(self):
        async def run():
            request_id = "cancel-playback"

            class YieldingConnection(ConnectionWebSocket):
                async def __anext__(self):
                    value = await super().__anext__()
                    await asyncio.sleep(0)
                    return value

            websocket = YieldingConnection([
                json.dumps({
                    "type": "audio_start",
                    "request_id": request_id,
                    "format": "pcm_s16le",
                    "sample_rate": 16_000,
                    "channels": 1,
                }),
                b"\x01\x00" * 320,
                json.dumps({"type": "audio_end", "request_id": request_id}),
                json.dumps({"type": "cancel_turn", "request_id": request_id}),
            ])
            with mock.patch.object(hb, "process_audio_turn", mock.AsyncMock()):
                await hb.handle_connection(websocket)
            return websocket

        websocket = asyncio.run(run())
        payloads = [
            json.loads(item) for item in websocket.sent if isinstance(item, str)
        ]
        self.assertIn(
            {"type": "turn_cancelled", "request_id": "cancel-playback"},
            payloads,
        )
        self.assertFalse(any(item.get("type") == "error" for item in payloads))

    def test_new_session_cancels_active_turn_before_gateway_reset(self):
        async def run():
            started = asyncio.Event()
            cancelled = asyncio.Event()
            gateway = mock.AsyncMock()

            class ResetConnection(ConnectionWebSocket):
                async def __anext__(self):
                    value = await super().__anext__()
                    if isinstance(value, str) and '"type": "new_session"' in value:
                        await started.wait()
                    else:
                        await asyncio.sleep(0)
                    return value

            websocket = ResetConnection([
                json.dumps({
                    "type": "audio_start",
                    "request_id": "old-turn",
                    "format": "pcm_s16le",
                    "sample_rate": 16_000,
                    "channels": 1,
                }),
                b"\x01\x00" * 320,
                json.dumps({"type": "audio_end", "request_id": "old-turn"}),
                json.dumps({"type": "new_session"}),
            ])

            async def blocked_turn(_websocket, _capture, state):
                state["gateway"] = gateway
                started.set()
                try:
                    await asyncio.Future()
                finally:
                    cancelled.set()

            with mock.patch.object(hb, "process_audio_turn", side_effect=blocked_turn):
                await hb.handle_connection(websocket)
            return websocket, gateway, cancelled

        websocket, gateway, cancelled = asyncio.run(run())
        self.assertTrue(cancelled.is_set())
        gateway.interrupt.assert_awaited_once()
        gateway.reset.assert_awaited_once()
        payloads = [
            json.loads(item) for item in websocket.sent if isinstance(item, str)
        ]
        self.assertIn({"type": "session_reset"}, payloads)

    def test_twenty_consecutive_audio_turns_finish_without_overlap(self):
        async def run():
            frames = []
            for index in range(20):
                request_id = f"turn-{index}"
                frames.extend([
                    json.dumps({
                        "type": "audio_start",
                        "request_id": request_id,
                        "format": "pcm_s16le",
                        "sample_rate": 16_000,
                        "channels": 1,
                    }),
                    b"\x01\x00" * 320,
                    json.dumps({"type": "audio_end", "request_id": request_id}),
                ])

            class YieldingConnection(ConnectionWebSocket):
                async def __anext__(self):
                    value = await super().__anext__()
                    await asyncio.sleep(0)
                    return value

            websocket = YieldingConnection(frames)
            realtime_turn = mock.AsyncMock()
            with mock.patch.object(hb, "process_audio_turn", realtime_turn):
                await hb.handle_connection(websocket)
            return websocket, realtime_turn

        websocket, realtime_turn = asyncio.run(run())
        self.assertEqual(realtime_turn.await_count, 20)
        errors = [
            json.loads(item) for item in websocket.sent
            if isinstance(item, str) and json.loads(item).get("type") == "error"
        ]
        self.assertEqual(errors, [])


class AdamFinishPhraseTests(unittest.TestCase):
    def test_standalone_finish_phrase_normalization(self):
        for phrase in (
            "That's it", "Thats it!", "THAT IS IT.", "That’s it…",
            "Thatʼs it", "that s it", "thatsit", "that'sit",
        ):
            self.assertTrue(is_adam_finish_phrase(phrase), phrase)

    def test_embedded_and_longer_phrases_do_not_trigger(self):
        for phrase in ("do that's it", "that's it please", "that is it now"):
            self.assertFalse(is_adam_finish_phrase(phrase), phrase)

    def test_marker_strips_only_trailing_exact_finish_phrase(self):
        for transcript in (
            "open the door That's it", "open the door, that is it.",
            "open the door that s it", "open the door thatsit",
        ):
            self.assertEqual(strip_adam_finish_phrase(transcript), "open the door")
        self.assertEqual(strip_adam_finish_phrase("That's it"), "")
        self.assertEqual(strip_adam_finish_phrase("open that's it please"), "open that's it please")

    def test_process_strips_marked_transcript_but_not_unmarked(self):
        def run(marked):
            websocket = FakeWebSocket([])
            api = mock.MagicMock()
            api.transcribe.return_value = {
                "transcript": "open the door That's it",
                "provider": "local",
                "backend": "mlx-whisper",
            }
            gateway = SimpleNamespace(ask=mock.AsyncMock(return_value="Done."))
            state = {"send_lock": asyncio.Lock(), "hermes_api": api, "gateway": gateway}
            capture = {
                "request_id": "finish-turn",
                "locale": "en-GB",
                "pcm": bytearray(b"\x01\x00" * 320),
                "vocabulary": [],
                "follow_up": False,
                "finish_phrase": marked,
            }
            with mock.patch.object(hb, "HermesTTSStream") as stream_type, \
                 mock.patch.object(hb, "synthesize_speech", return_value=b""):
                stream = stream_type.return_value
                stream.open = mock.AsyncMock(return_value=False)
                stream.close = mock.AsyncMock()
                asyncio.run(hb.process_audio_turn(websocket, capture, state))
            return [json.loads(item) for item in websocket.sent if isinstance(item, str)]

        marked = run(True)
        unmarked = run(False)
        self.assertEqual(marked[0]["text"], "open the door")
        self.assertEqual(unmarked[0]["text"], "open the door That's it")


class BridgeGateRealtimeTests(unittest.TestCase):
    def test_audio_gate_command_bypasses_agent_and_keeps_voice_response(self):
        websocket = FakeWebSocket([])
        api = mock.MagicMock()
        api.transcribe.return_value = {
            "transcript": "close gates",
            "provider": "local",
            "backend": "mlx-whisper",
        }
        gateway = SimpleNamespace(ask=mock.AsyncMock())
        stream = mock.MagicMock()
        stream.open = mock.AsyncMock(return_value=False)
        stream.close = mock.AsyncMock()
        stream.provider = "kokoro-mlx"
        stream.voice = "bm_george"
        capture = {
            "request_id": "gate-turn",
            "locale": "en-GB",
            "pcm": bytearray(b"\x01\x00" * 320),
            "vocabulary": ["Adam"],
            "follow_up": False,
        }
        state = {
            "send_lock": asyncio.Lock(),
            "hermes_api": api,
            "gateway": gateway,
        }

        with mock.patch.object(
            hb, "HermesTTSStream", return_value=stream
        ), mock.patch.object(
            hb, "activate_gate_relay",
            return_value=(True, "Gate relay activation command accepted."),
        ) as activate, mock.patch.object(
            hb, "synthesize_speech", return_value=b""
        ):
            asyncio.run(hb.process_audio_turn(websocket, capture, state))

        activate.assert_called_once_with("close")
        gateway.ask.assert_not_awaited()
        payloads = [
            json.loads(item) for item in websocket.sent
            if isinstance(item, str)
        ]
        self.assertIn(
            "Gate relay activation command accepted.",
            [item.get("text") for item in payloads],
        )
        response = next(item for item in payloads if item.get("type") == "response")
        self.assertFalse(response["tts"])
        self.assertNotIn("audio_start", [item.get("type") for item in payloads])
        self.assertNotIn("audio_end", [item.get("type") for item in payloads])

    def test_finished_open_gate_command_still_activates_relay(self):
        websocket = FakeWebSocket([])
        api = mock.MagicMock()
        api.transcribe.return_value = {
            "transcript": "open gates That's it",
            "provider": "local",
            "backend": "mlx-whisper",
        }
        gateway = SimpleNamespace(ask=mock.AsyncMock())
        stream = mock.MagicMock()
        stream.open = mock.AsyncMock(return_value=False)
        stream.close = mock.AsyncMock()
        stream.provider = "kokoro-mlx"
        stream.voice = "bm_george"
        capture = {
            "request_id": "finished-gate-turn",
            "locale": "en-GB",
            "pcm": bytearray(b"\x01\x00" * 320),
            "vocabulary": ["Adam"],
            "follow_up": False,
            "finish_phrase": True,
        }
        state = {
            "send_lock": asyncio.Lock(),
            "hermes_api": api,
            "gateway": gateway,
        }

        with mock.patch.object(
            hb, "HermesTTSStream", return_value=stream
        ), mock.patch.object(
            hb, "activate_gate_relay",
            return_value=(True, "Gate relay activation command accepted."),
        ) as activate, mock.patch.object(
            hb, "synthesize_speech", return_value=b""
        ):
            asyncio.run(hb.process_audio_turn(websocket, capture, state))

        activate.assert_called_once_with("open")
        gateway.ask.assert_not_awaited()


class BridgeFollowUpTests(unittest.TestCase):
    @staticmethod
    def _run_turn(transcript, follow_up):
        websocket = FakeWebSocket([])
        api = mock.MagicMock()
        api.transcribe.return_value = {
            "transcript": transcript,
            "provider": "local",
            "backend": "mlx-whisper",
        }
        gateway = SimpleNamespace(ask=mock.AsyncMock(return_value="All right."))
        stream = mock.MagicMock()
        stream.open = mock.AsyncMock(return_value=False)
        stream.close = mock.AsyncMock()
        stream.provider = "kokoro-mlx"
        stream.voice = "bm_george"
        capture = {
            "request_id": "follow-up-turn",
            "locale": "en-GB",
            "pcm": bytearray(b"\x01\x00" * 320),
            "vocabulary": ["Donzo"],
            "follow_up": follow_up,
        }
        state = {
            "send_lock": asyncio.Lock(),
            "hermes_api": api,
            "gateway": gateway,
        }
        with mock.patch.object(hb, "HermesTTSStream", return_value=stream), \
             mock.patch.object(hb, "synthesize_speech", return_value=b""):
            asyncio.run(hb.process_audio_turn(websocket, capture, state))
        payloads = [
            json.loads(item) for item in websocket.sent if isinstance(item, str)
        ]
        return payloads, gateway

    def test_standalone_donzo_ends_follow_up_without_agent_or_tts(self):
        for phrase in ("donzo", "DONZO!", "Dónzo.", "ＤＯＮＺＯ"):
            payloads, gateway = self._run_turn(phrase, True)
            self.assertEqual(payloads, [{
                "type": "follow_up_ended",
                "request_id": "follow-up-turn",
            }])
            gateway.ask.assert_not_awaited()

    def test_longer_donzo_phrase_remains_a_normal_follow_up_command(self):
        payloads, gateway = self._run_turn("donzo please", True)
        self.assertEqual(payloads[0]["type"], "transcript")
        self.assertIn("response", [payload["type"] for payload in payloads])
        gateway.ask.assert_awaited_once()

    def test_donzo_outside_follow_up_remains_a_normal_command(self):
        payloads, gateway = self._run_turn("donzo", False)
        self.assertEqual(payloads[0]["type"], "transcript")
        self.assertIn("response_start", [payload["type"] for payload in payloads])
        gateway.ask.assert_awaited_once()


class BridgeStreamingTTSTests(unittest.TestCase):
    def test_response_metadata_precedes_stream_end_after_tail_flush(self):
        websocket = FakeWebSocket([])
        api = mock.MagicMock()
        api.transcribe.return_value = {
            "transcript": "hello Adam",
            "provider": "local",
            "backend": "mlx-whisper",
        }
        gateway = SimpleNamespace(
            ask=mock.AsyncMock(return_value="Good morning.")
        )

        class TailFlushStream:
            provider = "kokoro-mlx"
            voice = "bm_george"
            bytes_sent = 0

            async def open(self):
                return True

            async def feed(self, _text):
                return None

            async def finish(self, end_phone=True):
                self.bytes_sent = 4
                await websocket.send(json.dumps({
                    "type": "audio_start",
                    "request_id": "stream-turn",
                    "provider": self.provider,
                    "voice": self.voice,
                }))
                await websocket.send(b"\x01\x00\x02\x00")
                return True

            async def complete_phone_audio(self):
                await websocket.send(json.dumps({
                    "type": "audio_end", "request_id": "stream-turn"
                }))

            async def close(self, **_kwargs):
                return None

        capture = {
            "request_id": "stream-turn",
            "locale": "en-GB",
            "pcm": bytearray(b"\x01\x00" * 320),
            "vocabulary": ["Adam"],
            "follow_up": False,
        }
        state = {
            "send_lock": asyncio.Lock(),
            "hermes_api": api,
            "gateway": gateway,
        }
        stream = TailFlushStream()
        with mock.patch.object(hb, "HermesTTSStream", return_value=stream), \
             mock.patch.object(hb, "synthesize_speech") as fallback:
            asyncio.run(hb.process_audio_turn(websocket, capture, state))

        fallback.assert_not_called()
        frames = [
            json.loads(item) if isinstance(item, str) else item
            for item in websocket.sent
        ]
        response_index = next(
            index for index, item in enumerate(frames)
            if isinstance(item, dict) and item.get("type") == "response"
        )
        end_index = next(
            index for index, item in enumerate(frames)
            if isinstance(item, dict) and item.get("type") == "audio_end"
        )
        self.assertLess(response_index, end_index)
        self.assertEqual(frames[response_index]["provider"], "kokoro-mlx")
        self.assertEqual(frames[response_index]["voice"], "bm_george")

    def test_phone_playback_starts_on_first_pcm_and_caller_ends_it(self):
        async def run():
            phone = FakeWebSocket([])
            stream = hb.HermesTTSStream(
                SimpleNamespace(), phone, "reply-1", asyncio.Lock()
            )
            stream.websocket = StreamWebSocket([
                json.dumps({"type": "segment_start"}),
                b"\x01\x00\x02\x00",
                json.dumps({"type": "segment_end"}),
                json.dumps({"type": "end"}),
            ])
            await stream._receive()
            before_end = list(phone.sent)
            await stream.complete_phone_audio()
            return before_end, phone.sent, stream

        before_end, sent, stream = asyncio.run(run())
        self.assertEqual(json.loads(sent[0])["type"], "audio_start")
        self.assertEqual(sent[1], b"\x01\x00\x02\x00")
        self.assertEqual(json.loads(sent[2]), {
            "type": "audio_segment", "request_id": "reply-1"
        })
        self.assertEqual(len(before_end), 3)
        self.assertEqual(json.loads(sent[3]), {
            "type": "audio_end", "request_id": "reply-1"
        })
        self.assertEqual(stream.bytes_sent, 4)

    def test_start_frame_supplies_truthful_voice_identity(self):
        async def run():
            phone = FakeWebSocket([])
            stream = hb.HermesTTSStream(
                SimpleNamespace(
                    websocket_url=lambda _path: "ws://127.0.0.1/tts"
                ),
                phone,
                "reply-identity",
                asyncio.Lock(),
            )
            upstream = StreamWebSocket([
                json.dumps({
                    "type": "start",
                    "sample_rate": 24_000,
                    "channels": 1,
                    "provider": "openai",
                    "voice": "cedar",
                }),
            ])

            async def connect(*_args, **_kwargs):
                return upstream

            with mock.patch.object(hb.websockets, "connect", new=connect):
                opened = await stream.open()
                await asyncio.sleep(0)
                await stream.close()
            return opened, stream

        opened, stream = asyncio.run(run())
        self.assertTrue(opened)
        self.assertEqual(stream.provider, "openai")
        self.assertEqual(stream.voice, "cedar")

    def test_failure_cleanup_balances_started_phone_audio_once(self):
        async def run():
            phone = FakeWebSocket([])
            stream = hb.HermesTTSStream(
                SimpleNamespace(), phone, "reply-2", asyncio.Lock()
            )
            await stream._start_phone_audio()
            await stream.close(end_phone=True)
            await stream.close(end_phone=True)
            return phone.sent

        sent = asyncio.run(run())
        self.assertEqual(
            [json.loads(item)["type"] for item in sent],
            ["audio_start", "audio_end"],
        )


class BridgeFallbackTTSTests(unittest.TestCase):
    def test_british_macos_voice_selector_requires_daniel(self):
        voices = """\
Samantha            en_US    # Hello!
Daniel              en_GB    # Hello! My name is Daniel.
"""
        self.assertEqual(
            hb.select_macos_say_voice(voices, "en-GB"),
            "Daniel",
        )
        self.assertIsNone(
            hb.select_macos_say_voice("Samantha en_US # Hello!", "en-GB")
        )
        self.assertIsNone(hb.select_macos_say_voice(voices, "lv-LV"))

    def test_macos_fallback_uses_explicit_daniel_and_reports_it(self):
        fake_wave = mock.MagicMock()
        fake_wave.getnframes.return_value = 2
        fake_wave.readframes.return_value = b"\x01\x00\x02\x00"
        process_results = [
            subprocess.CompletedProcess(
                ["say", "-v", "?"], 0,
                stdout=b"Daniel en_GB # Hello!", stderr=b"",
            ),
            subprocess.CompletedProcess(["say"], 0, stdout=b"", stderr=b""),
        ]
        with mock.patch.dict(sys.modules, {"edge_tts": None}), \
             mock.patch.object(hb.shutil, "which", side_effect=lambda name: (
                 "/usr/bin/say" if name == "say" else None
             )), \
             mock.patch.object(hb.subprocess, "run", side_effect=process_results) as run, \
             mock.patch.object(hb.wave, "open") as wave_open:
            wave_open.return_value.__enter__.return_value = fake_wave
            speech = hb.synthesize_speech("Good morning", "en-GB")

        self.assertIsNotNone(speech)
        self.assertEqual(speech.pcm, b"\x01\x00\x02\x00")
        self.assertEqual(speech.provider, "macos-say")
        self.assertEqual(speech.voice, "Daniel")
        synthesis_command = run.call_args_list[1].args[0]
        self.assertEqual(synthesis_command[:3], ["say", "-v", "Daniel"])

    def test_edge_success_reports_the_voice_that_generated_pcm(self):
        class FakeCommunicate:
            selected_voice = None

            def __init__(self, _text, voice):
                FakeCommunicate.selected_voice = voice

            async def save(self, _path):
                return None

        fake_edge = SimpleNamespace(Communicate=FakeCommunicate)
        fake_wave = mock.MagicMock()
        fake_wave.getnframes.return_value = 2
        fake_wave.readframes.return_value = b"\x01\x00\x02\x00"
        converted = subprocess.CompletedProcess(
            ["afconvert"], 0, stdout=b"", stderr=b""
        )
        with mock.patch.dict(sys.modules, {"edge_tts": fake_edge}), \
             mock.patch.object(hb.shutil, "which", side_effect=lambda name: (
                 "/usr/bin/afconvert" if name == "afconvert" else None
             )), \
             mock.patch.object(hb.subprocess, "run", return_value=converted), \
             mock.patch.object(hb.wave, "open") as wave_open:
            wave_open.return_value.__enter__.return_value = fake_wave
            speech = hb.synthesize_speech("Good morning", "en-GB")

        self.assertIsNotNone(speech)
        self.assertEqual(speech.provider, "edge")
        self.assertEqual(speech.voice, "en-GB-RyanNeural")
        self.assertEqual(FakeCommunicate.selected_voice, speech.voice)


class BridgeGatewayTests(unittest.TestCase):
    def test_fast_voice_profile_is_applied_only_to_primary_session(self):
        async def connect(inherit_profile):
            socket = StreamWebSocket([
                json.dumps({
                    "method": "event",
                    "params": {"type": "gateway.ready"},
                }),
                json.dumps({
                    "jsonrpc": "2.0",
                    "id": "adam-1",
                    "result": {
                        "session_id": "runtime-session",
                        "stored_session_id": "stored-session",
                    },
                }),
            ])
            api = SimpleNamespace(
                websocket_url=lambda _path: "ws://127.0.0.1/private"
            )
            gateway = hb.HermesGateway(api)
            async def fake_connect(*_args, **_kwargs):
                return socket

            with mock.patch.object(hb.websockets, "connect", new=fake_connect), \
                 mock.patch.object(hb, "load_session", return_value=None), \
                 mock.patch.object(hb, "store_session") as store:
                await gateway._connect(
                    force_new=inherit_profile,
                    inherit_profile=inherit_profile,
                )
            request = json.loads(socket.sent[0])
            return request["params"], store

        primary_params, primary_store = asyncio.run(connect(False))
        self.assertEqual(primary_params["provider"], hb.HERMES_AGENT_PROVIDER)
        self.assertEqual(primary_params["model"], hb.HERMES_AGENT_MODEL)
        self.assertEqual(
            primary_params["reasoning_effort"],
            hb.HERMES_AGENT_REASONING_EFFORT,
        )
        self.assertEqual(primary_params["fast"], hb.HERMES_AGENT_FAST)
        primary_store.assert_called_once_with("stored-session")

        inherited_params, inherited_store = asyncio.run(connect(True))
        for key in ("provider", "model", "reasoning_effort", "fast"):
            self.assertNotIn(key, inherited_params)
        inherited_store.assert_not_called()

    def test_failed_fast_profile_retries_with_inherited_profile(self):
        async def run():
            gateway = hb.HermesGateway(SimpleNamespace())
            gateway._connect = mock.AsyncMock()
            gateway._ask_connected = mock.AsyncMock(
                side_effect=[RuntimeError("unsupported profile"), "fallback reply"]
            )
            with mock.patch.object(hb, "clear_session") as clear:
                result = await gateway.ask("hello", mock.AsyncMock())
            return result, gateway, clear

        result, gateway, clear = asyncio.run(run())
        self.assertEqual(result, "fallback reply")
        self.assertEqual(
            gateway._connect.await_args_list,
            [
                mock.call(force_new=False, inherit_profile=False),
                mock.call(force_new=True, inherit_profile=True),
            ],
        )
        clear.assert_called_once_with()

    def test_interrupt_sends_rpc_and_closes_socket(self):
        async def run():
            gateway = hb.HermesGateway(SimpleNamespace())
            gateway.websocket = StreamWebSocket()
            gateway.session_id = "session-1"
            upstream = gateway.websocket
            await gateway.interrupt()
            return gateway, upstream

        gateway, upstream = asyncio.run(run())
        request = json.loads(upstream.sent[0])
        self.assertEqual(request["method"], "session.interrupt")
        self.assertEqual(request["params"]["session_id"], "session-1")
        self.assertTrue(upstream.closed)
        self.assertIsNone(gateway.websocket)

    def test_attention_event_interrupts_turn_and_closes_event_stream(self):
        async def run():
            api = SimpleNamespace()
            gateway = hb.HermesGateway(api)
            gateway.websocket = StreamWebSocket([json.dumps({
                "method": "event",
                "params": {
                    "session_id": "session-1",
                    "type": "approval.request",
                    "payload": {},
                },
            })])
            upstream = gateway.websocket
            gateway.session_id = "session-1"
            attention = []

            async def on_delta(_delta):
                return None

            async def on_attention(kind):
                attention.append(kind)

            with self.assertRaises(hb.HermesAttentionRequired):
                await gateway.ask("hello", on_delta, on_attention)
            return upstream, gateway, attention

        upstream, gateway, attention = asyncio.run(run())
        methods = [json.loads(item).get("method") for item in upstream.sent]
        self.assertEqual(methods, ["prompt.submit", "session.interrupt"])
        self.assertEqual(attention, ["approval.request"])
        self.assertTrue(upstream.closed)
        self.assertIsNone(gateway.websocket)


class BridgeLocaleTests(unittest.TestCase):
    def test_locale_instruction_is_sent_on_every_hermes_query(self):
        original_ask = hb.ask_hermes
        original_session_file = hb.SESSION_FILE
        original_brain = hb.BRAIN
        original_bridge_tts = hb.BRIDGE_TTS
        original_vision = hb.BRIDGE_VISION
        temp_path = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        temp_path.close()
        os.unlink(temp_path.name)
        calls = []

        def fake_ask(query, image_path=None, resume=None):
            calls.append((query, resume))
            return "atbilde", "session-lv"

        hb.ask_hermes = fake_ask
        hb.SESSION_FILE = temp_path.name
        hb.BRAIN = "hermes"
        hb.BRIDGE_TTS = False
        hb.BRIDGE_VISION = True
        try:
            asyncio.run(hb.process_query(FakeWebSocket([]), "cik ir pulkstenis?",
                                         locale="lv-LV"))
            asyncio.run(hb.process_query(FakeWebSocket([]), "un rīt?",
                                         locale="lv-LV"))
        finally:
            hb.ask_hermes = original_ask
            hb.SESSION_FILE = original_session_file
            hb.BRAIN = original_brain
            hb.BRIDGE_TTS = original_bridge_tts
            hb.BRIDGE_VISION = original_vision
            try:
                os.unlink(temp_path.name)
            except OSError:
                pass
        self.assertEqual(len(calls), 2)
        self.assertTrue(all("Latvian" in query for query, _ in calls))
        self.assertTrue(calls[0][0].endswith("cik ir pulkstenis?"))
        self.assertEqual(calls[1][1], "session-lv")


class BridgeHermesInvocationTests(unittest.TestCase):
    def test_cli_contains_execution_bounds_and_workdir_without_yolo(self):
        original = (hb.HERMES_BIN, hb.BRIDGE_WORKDIR,
                    hb.HERMES_MAX_TURNS, hb.HERMES_RUN_BUDGET)
        captured = {}

        def fake_run(cmd, **kwargs):
            captured["cmd"] = cmd
            captured["kwargs"] = kwargs
            return subprocess.CompletedProcess(cmd, 0, stdout="reply", stderr="")

        hb.HERMES_BIN = "/tmp/hermes"
        hb.BRIDGE_WORKDIR = "/tmp/adam-workdir"
        hb.HERMES_MAX_TURNS = 7
        hb.HERMES_RUN_BUDGET = 11
        try:
            with mock.patch("subprocess.run", side_effect=fake_run):
                reply, session = hb.ask_hermes("hello")
        finally:
            (hb.HERMES_BIN, hb.BRIDGE_WORKDIR,
             hb.HERMES_MAX_TURNS, hb.HERMES_RUN_BUDGET) = original
        self.assertEqual(reply, "reply")
        self.assertIsNone(session)
        cmd = captured["cmd"]
        self.assertIn("--no-restore-cwd", cmd)
        self.assertEqual(cmd[cmd.index("--in") + 1], "/tmp/adam-workdir")
        self.assertEqual(cmd[cmd.index("--max-turns") + 1], "7")
        self.assertEqual(cmd[cmd.index("--run-budget") + 1], "11")
        self.assertNotIn("--yolo", cmd)

    def test_cli_failure_does_not_expose_stderr_in_voice_reply(self):
        secret_detail = "provider failed at /private/path with token-shaped detail"

        def fake_run(cmd, **kwargs):
            return subprocess.CompletedProcess(
                cmd, 2, stdout="", stderr=secret_detail
            )

        with mock.patch("subprocess.run", side_effect=fake_run):
            reply, _ = hb.ask_hermes("hello")

        self.assertEqual(reply, "Sorry, Hermes could not answer that right now.")
        self.assertNotIn(secret_detail, reply)

    def test_cli_exception_does_not_expose_details_in_log_or_reply(self):
        secret_detail = "private prompt at /private/path"
        with mock.patch("subprocess.run", side_effect=OSError(secret_detail)), \
                mock.patch("builtins.print") as output:
            reply, _ = hb.ask_hermes("hello")

        self.assertEqual(reply, "Sorry, Hermes could not answer that right now.")
        rendered = " ".join(str(call) for call in output.call_args_list)
        self.assertNotIn(secret_detail, rendered)
        self.assertNotIn("/private/path", rendered)


class BridgeRequestIdentityTests(unittest.TestCase):
    def test_response_echoes_request_id(self):
        ws = FakeWebSocket([])
        asyncio.run(hb.send_response(ws, "ok", False, "request-123"))
        payload = json.loads(ws.sent[0])
        self.assertEqual(payload["request_id"], "request-123")

    def test_response_omits_absent_request_id_for_old_clients(self):
        ws = FakeWebSocket([])
        asyncio.run(hb.send_response(ws, "ok", False))
        payload = json.loads(ws.sent[0])
        self.assertNotIn("request_id", payload)


class BridgeSessionStoreTests(unittest.TestCase):
    def test_store_creates_parent_atomically_with_private_permissions(self):
        root = tempfile.mkdtemp()
        path = os.path.join(root, "nested", "adam-session.json")
        original = hb.SESSION_FILE
        hb.SESSION_FILE = path
        try:
            hb.store_session("sid")
            self.assertEqual(hb.load_session(), "sid")
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
            self.assertTrue(os.path.isdir(os.path.dirname(path)))
            self.assertFalse(os.path.exists(path + ".tmp"))
        finally:
            hb.SESSION_FILE = original
            try:
                os.unlink(path)
            except OSError:
                pass
            try:
                os.rmdir(os.path.dirname(path))
                os.rmdir(root)
            except OSError:
                pass


if __name__ == "__main__":
    unittest.main()
