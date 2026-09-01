# Adam Hermes clone setup

The **AdamVoice** scheme builds the complete HermesGlasses iPhone app under
the external app name **Adam** and bundle identifier
`com.vandret.adamvoice`. It does not contain a separate Adam runtime.
Both targets use the same Hermes entry point, Swift sources, assets,
frameworks, embedded frameworks, package products, Info.plist, entitlements,
permissions, and build configuration.

This means Adam has the same onboarding, navigation, conversation UI, voice
sessions, live transcription, camera and photo flows, settings, pairing,
permission prompts, error states, and accessibility behavior as
HermesGlasses. Changes to Hermes source or target phases automatically apply
to Adam.

## Intentional identity differences

| Setting | HermesGlasses | AdamVoice |
|---|---|---|
| Installed app name / product | Hermes Glasses | Adam |
| Bundle identifier | `com.flowsxr.hermesglasses` | `com.vandret.adamvoice` |
| Xcode scheme and target | HermesGlasses | AdamVoice |

Version, source membership, resources, dependencies, entitlements, permission
descriptions, URL scheme, and runtime configuration stay aligned. Signing and
provisioning are selected for the bundle identifier at build time.

## Meta Wearables configuration

Adam is a full Meta Wearables Device Access Toolkit app, not a Bluetooth
headset-only variant. Configure `Config/Secrets.xcconfig` from
`Config/Secrets.example.xcconfig` with the Meta App ID and Client Token used
by HermesGlasses. Keep the file untracked.

The Meta developer project must allow the Adam bundle identifier
`com.vandret.adamvoice` and the shared `hermesglasses` callback scheme. If
the bundle identifier is not registered for the Meta app, SDK registration or
pairing can fail even though the app builds correctly.

## Build and install

1. Open `HermesGlasses.xcodeproj`.
2. Select the **AdamVoice** scheme and the connected iPhone.
3. Select a signing team and provisioning profile that support the shared
   Hermes entitlements for `com.vandret.adamvoice`.
4. Run the app.
5. Complete onboarding, grant every requested permission, and register the
   glasses through the same Meta AI flow used by HermesGlasses.

The target requests the same camera, microphone, speech recognition,
Bluetooth, local-network, location, motion, external-accessory, background,
Wi-Fi information, hotspot, and keychain capabilities as HermesGlasses.
Personal/free provisioning may reject restricted capabilities; use a profile
that supports the canonical Hermes entitlements rather than removing them
from Adam.

If HermesGlasses and Adam are installed together, both advertise the same
`hermesglasses` callback scheme. iOS may choose either app for an external
callback. For unambiguous pairing tests, keep only the app currently under
test installed.

## Guarded testing branch

The `adam-testing` branch uses the project-local post-commit hook:

```bash
git switch adam-testing
git config core.hooksPath .githooks
```

After a reviewed commit, the hook checks that the worktree is clean, verifies
the allowed replacement paths, builds both HermesGlasses and AdamVoice
unsigned, and performs a normal fast-forward push. It never stages files,
creates commits, or force-pushes.

To retry a transient failed push without creating another commit:

```bash
scripts/push-adam-testing.sh
```

## Device parity checklist

After installing Adam, validate the following on the physical iPhone and
glasses:

- onboarding and every permission prompt;
- Meta registration, pairing, reconnect, and disconnect states;
- app navigation, settings persistence, and appearance;
- voice session start/stop, transcription, reply playback, and cancellation;
- camera preview, still capture, photo attachment, and vision requests;
- display/glasses interactions supported by the paired model;
- background transitions, errors, retry actions, and accessibility labels.

Build-time parity does not prove hardware behavior. Meta registration,
provisioning, permissions, Bluetooth routing, camera streaming, and display
behavior must be confirmed on the intended device and glasses.
