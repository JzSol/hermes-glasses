# Adam voice-only setup

AdamVoice is the camera-free target for talking to Hermes through Ray-Ban
Meta glasses. It uses standard Bluetooth hands-free audio rather than Meta's
Wearables Device Access Toolkit. You do not need a Meta developer project or
a paid Apple Developer membership for a personal prototype.

## What runs where

- Ray-Bans: Bluetooth HFP microphone and speaker.
- iPhone: the `Adam` wake word, English/Latvian speech recognition, generated
  listening cues, and local speech synthesis.
- Mac: authenticated Hermes bridge and Hermes Agent.
- Tailscale: private TLS WebSocket from the iPhone to the loopback-only bridge.

Audio is not sent to the Mac. The app sends only finalized command text and
receives reply text. Apple Speech may use Apple's service when the selected
language is not available for on-device recognition; the app shows that
capability explicitly.

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
HERMES_BRIDGE_TTS=0
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

For a foreground bridge test:

```bash
bridge/.venv/bin/python bridge/hermes_bridge.py
```

For an always-on Mac setup, run the same executable from a user LaunchAgent
with its working directory set to `bridge`, `HERMES_HOME` set to the Hermes
profile containing your provider logins, and `RunAtLoad`/`KeepAlive` enabled.
The bridge-local `.env` remains the source of its secret and runtime settings.

## 2. Provider subscriptions

The bridge invokes the normal Hermes CLI, so subscription authentication lives
in Hermes rather than in the iPhone app.

- Authenticate OpenAI/Codex in Hermes and use `openai-codex` as the primary
  provider.
- Authenticate Anthropic with `hermes auth add anthropic --type oauth`, then
  add an Anthropic model to Hermes's fallback providers.

Hermes can also discover a valid Claude Code subscription credential in the
user's standard Claude configuration. Do not paste either provider's token
into Adam or `bridge/.env`.

## 3. Build with a free Apple ID

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

## 4. First run

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
   state, then speak the command. Adam answers with the best installed British
   male voice when English is selected.
8. For the next 30 seconds after an answer, ask follow-up questions without
   repeating `Adam`. Partial speech extends that window; after it closes, say
   `Adam` again.

The **Continuous follow-ups** and **Listening sounds** switches are enabled by
default. Listening sounds use a quiet generated flute loop on the Ray-Ban HFP
route and a short opening cue on the iPhone-mic fallback. A droplet confirms
that the command was accepted. No recorded or licensed audio assets are used.

If Adam reports that the input is very quiet, confirm the Input row still names
the Ray-Bans. The app requests the route's highest supported hardware gain and
applies bounded recognition-only amplification; unsupported HFP gain controls
are handled automatically. To install a different British voice, use iPhone
**Settings → Accessibility → Spoken Content → Voices → English (UK)**.

## Prototype limits

- No camera or “what am I looking at?” support in this target.
- The app must have been opened and started; iOS does not provide a systemwide
  third-party wake phrase from a terminated app.
- Background and lock-screen continuity must be verified on the target iPhone;
  iOS can restart long-running Speech recognition tasks.
- Ray-Ban HFP uses call-quality audio. If another Bluetooth call device wins
  the route, Adam reports the actual input instead of claiming it is the
  glasses.
- The generated flute is deliberately quiet and runs only while Adam is
  actively accepting a command, not while merely waiting for the wake word,
  processing, or speaking.
