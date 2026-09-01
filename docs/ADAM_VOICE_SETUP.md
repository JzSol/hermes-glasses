# Adam voice-only setup

AdamVoice is the camera-free target for talking to Hermes through Ray-Ban
Meta glasses. It uses standard Bluetooth hands-free audio rather than Meta's
Wearables Device Access Toolkit. You do not need a Meta developer project or
a paid Apple Developer membership for a personal prototype.

## What runs where

- Ray-Bans: Bluetooth HFP microphone and speaker.
- iPhone: the `Adam` wake word and utterance-boundary detection, generated
  listening cues, bounded HFP gain, and high-quality PCM playback.
- Mac: authenticated Hermes bridge, faster-whisper final transcription,
  persistent Hermes Agent session, and Kokoro MLX speech synthesis.
- Tailscale: private TLS WebSocket from the iPhone to the loopback-only bridge.

After `Adam` opens a command window, the captured mono PCM command is sent to
the Mac over the private Tailscale WebSocket. Apple's recognizer is used only
for wake/boundary detection; Hermes's local faster-whisper transcript is the
text shown as **Heard** and sent to the agent. English reply audio is generated
locally on the Mac and streamed back as PCM. Natural sentence boundaries are
queued on the iPhone, so George can begin the first sentence while Hermes is
still generating the rest of the answer.

## 1. Configure the bridge

From the repository root:

```bash
cd bridge
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
cp .env.example .env
```

Set at least these values in the ignored `bridge/.env`:

```dotenv
HERMES_BRIDGE_TOKEN=<a-random-32-byte-or-longer-secret>
HERMES_BRIDGE_HOST=127.0.0.1
HERMES_BRIDGE_PORT=8765
HERMES_BRIDGE_VISION=false
HERMES_BRIDGE_BRAIN=hermes
HERMES_BRIDGE_API_BASE=http://127.0.0.1:9119
```

The bridge refuses to bind without a token. Keep it on loopback and expose it
only through Tailscale Serve:

```bash
tailscale serve --https=8443 http://127.0.0.1:8765
tailscale serve status
```

The iPhone endpoint is then:

```text
wss://<mac-name>.<tailnet>.ts.net:8443/voice
```

Do not add the token to that URL. Adam sends it as a Bearer header.

Recent Hermes versions protect fixed-port dashboards with password/OAuth.
Leave that protection enabled. When port 9119 does not expose a loopback
session token, Adam starts a second Hermes backend on an OS-assigned loopback
port with a random per-process token. This backend uses the same `HERMES_HOME`,
subscription logins, model settings, and plugins; it cannot be reached through
Tailscale and is terminated with the bridge. Adam starts it and warms local
STT/Kokoro in the background when the bridge launches, so model startup is not
part of the first spoken turn. Set
`HERMES_BRIDGE_PRIVATE_BACKEND=false` only if `HERMES_BRIDGE_API_BASE` already
provides non-interactive authentication.

For a foreground bridge test:

```bash
bridge/.venv/bin/python bridge/hermes_bridge.py
```

For an always-on Mac setup, run the same executable from a user LaunchAgent
with its working directory set to `bridge`, `HERMES_HOME` set to the Hermes
profile containing your provider logins, `RunAtLoad`/`KeepAlive` enabled, and
`ProcessType` set to `Interactive`. The interactive process class matters for
local faster-whisper latency; macOS heavily throttles CPU inference inherited
from a `Background` LaunchAgent. The bridge-local `.env` remains the source of
its secret and runtime settings.

## 2. Provider subscriptions

The bridge uses Hermes's local dashboard/gateway APIs, so subscription
authentication lives in Hermes rather than in the iPhone app.

- Authenticate OpenAI/Codex in Hermes and use `openai-codex` as the primary
  provider.
- Authenticate Anthropic with `hermes auth add anthropic --type oauth`, then
  add an Anthropic model to Hermes's fallback providers.

Hermes can also discover a valid Claude Code subscription credential in the
user's standard Claude configuration. Do not paste either provider's token
into Adam or `bridge/.env`.

## 3. Install local speech on the Mac

Install and enable the Kokoro MLX plugin, then install its two runtime
dependencies into the same virtual environment as Hermes:

```bash
hermes plugins install JzSol/hermes-kokoro-mlx --enable
uv pip install --python ~/.hermes/hermes-agent/.venv/bin/python \
  "kokoro-mlx>=0.1.2,<0.2" \
  "en-core-web-sm @ https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"
hermes plugins doctor kokoro-mlx
```

Configure the relevant voice sections in `~/.hermes/config.yaml`:

```yaml
plugins:
  enabled:
    - kokoro-mlx
tts:
  provider: kokoro-mlx
  voice: bm_george
  speed: 1.0
  streaming:
    provider: kokoro-mlx
  kokoro-mlx:
    voice: bm_george
    speed: 1.0
    sample_rate: 24000
  edge:
    voice: en-GB-RyanNeural
stt:
  provider: local
  local:
    model: small
    language: ''
    device: cpu
    compute_type: int8
    beam_size: 1
    vad: true
    vad_min_silence_ms: 350
```

Restart the Adam bridge after changing plugins or voice configuration. If you
also keep the fixed-port dashboard running, restart that service separately:

```bash
hermes serve --host 127.0.0.1 --port 9119
```

The plugin warms George in the background; its first start downloads the
local model weights. Hermes also downloads faster-whisper `small` once.

## 4. Build with a free Apple ID

Create the ignored machine-local build configuration first:

```bash
cp Config/AdamVoice.example.xcconfig Config/AdamVoice.local.xcconfig
```

Set `ADAM_DEVELOPMENT_TEAM` to the Personal Team ID shown by Xcode and set
`ADAM_BRIDGE_ALLOWED_HOST` to the exact `*.ts.net` hostname from the endpoint
above. Set `ADAM_BRIDGE_DEFAULT_ENDPOINT` using the example's
`wss:/$()/.../voice` spelling (`//` starts a comment in an xcconfig; Xcode
expands this to `wss://`).
Adam pins that host in the built app; it will not send the bearer token to some
other tailnet hostname, and the endpoint is already filled on first launch.

Open `HermesGlasses.xcodeproj`, choose the **AdamVoice** scheme, and select the
connected iPhone. In **Signing & Capabilities**, choose the Personal Team tied
to the Apple ID signed into Xcode, then Run.

Free personal signing is enough for this prototype, but iOS normally requires
the app to be rebuilt periodically. The AdamVoice target has no Meta SDK,
camera, location, or glasses-registration permission.

## 5. First run

1. Pair the Ray-Bans to the iPhone in the Meta AI app and confirm they can act
   as a Bluetooth call device.
2. Keep the iPhone and Mac connected to the same tailnet.
3. In Adam, save the `wss://...:8443/voice` endpoint.
4. Paste the bridge token; it is stored in iPhone Keychain.
5. Select English or Latvian, tap **Start**, and grant microphone and speech
   recognition access.
6. Confirm the Input row says `Ray-Ban HFP`. If it says iPhone microphone,
   reconnect the glasses' Bluetooth audio and restart the session.
7. Say “Adam, what time is it?” or say “Adam”, wait for the flute/listening
   state, then speak the command. The **Heard** line is Hermes's final local
   transcript and English replies use George, a British male Kokoro voice.
8. Say `Adam` again for every new turn. Post-response conversation without the
   wake word is ignored.

The **Listening sounds** switch is enabled by default. One short, quiet
generated flute cue marks the open command window; recording itself stays
silent so the cue cannot contaminate Whisper. A droplet confirms that the
command was accepted. No recorded or licensed cue assets are used.

If Adam reports that the input is very quiet, confirm the Input row still names
the Ray-Bans. The app requests the route's highest supported hardware gain and
applies bounded amplification to separate wake-recognition and bridge-upload
copies; unsupported HFP gain controls are handled automatically. The original
recording buffer is not modified.

## Prototype limits

- No camera or “what am I looking at?” support in this target.
- The app must have been opened and started; iOS does not provide a systemwide
  third-party wake phrase from a terminated app.
- Background and lock-screen continuity must be verified on the target iPhone;
  iOS can restart long-running Speech recognition tasks.
- Ray-Ban HFP uses call-quality audio. If another Bluetooth call device wins
  the route, Adam reports the actual input instead of claiming it is the
  glasses.
- The generated flute is deliberately quiet and plays once when Adam begins
  accepting a command, not while merely waiting for the wake word, recording,
  processing, or speaking.
