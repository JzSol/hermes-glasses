import asyncio
import base64
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import hermes_bridge as hb
from hermes_bridge import (
    is_visual_query, await_photo, build_provider_request, parse_provider_reply,
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


class BridgeStreamingTTSTests(unittest.TestCase):
    def test_phone_playback_starts_on_first_pcm_and_always_ends(self):
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
            return phone.sent, stream

        sent, stream = asyncio.run(run())
        self.assertEqual(json.loads(sent[0])["type"], "audio_start")
        self.assertEqual(sent[1], b"\x01\x00\x02\x00")
        self.assertEqual(json.loads(sent[2]), {
            "type": "audio_segment", "request_id": "reply-1"
        })
        self.assertEqual(json.loads(sent[3]), {
            "type": "audio_end", "request_id": "reply-1"
        })
        self.assertEqual(stream.bytes_sent, 4)

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


class BridgeGatewayTests(unittest.TestCase):
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
