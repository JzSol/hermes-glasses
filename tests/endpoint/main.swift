// Standalone tests for HermesEndpointValidator. Build with:
//   xcrun swiftc HermesGlasses/Services/VoiceLocale.swift \
//     HermesGlasses/Services/HermesEndpointPolicy.swift \
//     HermesGlasses/Services/BridgeCredentials.swift \
//     HermesGlasses/Services/HermesAPIClient.swift \
//     tests/endpoint/main.swift -o /tmp/endpoint-tests && /tmp/endpoint-tests

import Foundation

var failures = 0
func expect(_ condition: Bool, _ label: String) {
    if condition {
        print("PASS \(label)")
    } else {
        failures += 1
        print("FAIL \(label)")
    }
}

let tailnet = HermesEndpointValidationMode.release(allowedHosts: ["mac.example.ts.net"])
let strict = HermesEndpointValidationMode.release(allowedHosts: ["bridge.example"])

expect((try? HermesEndpointValidator.validate(
    "wss://mac.example.ts.net:8443/voice", mode: tailnet)) != nil,
       "release accepts allow-listed WSS endpoint")
expect((try? HermesEndpointValidator.validate(
    "wss://bridge.example/voice", mode: strict)) != nil,
       "release accepts explicit custom allow-list")
expect((try? HermesEndpointValidator.validate(
    "wss://other.example/voice", mode: strict)) == nil,
       "release rejects arbitrary WSS host")
expect((try? HermesEndpointValidator.validate(
    "ws://mac.example.ts.net/voice", mode: tailnet)) == nil,
       "release rejects insecure WS")
expect((try? HermesEndpointValidator.validate(
    "https://mac.example.ts.net/voice", mode: tailnet)) == nil,
       "release rejects HTTP")
expect((try? HermesEndpointValidator.validate(
    "wss://mac.example.ts.net/voice?token=secret", mode: tailnet)) == nil,
       "endpoint query is rejected so secrets cannot enter URL")

expect((try? HermesEndpointValidator.validate(
    "ws://127.0.0.1:8765/voice", mode: .debug)) != nil,
       "debug permits IPv4 loopback WS")
expect((try? HermesEndpointValidator.validate(
    "ws://localhost:8765/voice", mode: .debug)) != nil,
       "debug permits localhost WS")
expect((try? HermesEndpointValidator.validate(
    "ws://192.168.1.20:8765/voice", mode: .debug)) == nil,
       "debug rejects non-loopback insecure WS")
expect((try? HermesEndpointValidator.validate(
    "wss://mac.example.ts.net/voice", mode: .debug)) != nil,
       "debug still permits secure tailnet endpoint")

// The client puts the bearer token in the request header only, and carries
// the selected locale in the query JSON rather than in the URL.
let client = HermesAPIClient(
    endpoint: "wss://bridge.example/voice",
    token: "test-token",
    locale: .latvianLV,
    validationMode: strict
)
if let request = try? client.makeConnectRequest() {
    expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token",
           "client uses bearer authorization header")
    expect(!(request.url?.absoluteString.contains("test-token") ?? true),
           "token never appears in request URL")
} else {
    expect(false, "client builds token-authenticated request")
}
let missingTokenClient = HermesAPIClient(
    endpoint: "wss://bridge.example/voice",
    token: "   ",
    locale: .englishGB,
    validationMode: strict
)
expect((try? missingTokenClient.makeConnectRequest()) == nil,
       "client rejects missing bearer token")

let migrated = HermesAPIClient.migrateLegacyEndpoint(
    "wss://bridge.example/voice?token=legacy-secret"
)
expect(migrated.endpoint == "wss://bridge.example/voice",
       "legacy migration strips token from endpoint")
expect(migrated.token == "legacy-secret",
       "legacy migration retains token only in memory")
expect(
    BridgeCredentials(endpoint: "wss://one.example/voice").account
        != BridgeCredentials(endpoint: "wss://two.example/voice").account,
    "different bridge hosts use different Keychain accounts"
)
expect(
    BridgeCredentials(endpoint: "wss://ONE.example/voice?token=old").account
        == BridgeCredentials(endpoint: "wss://one.example/voice").account,
    "endpoint Keychain account ignores legacy token and host case"
)
expect(
    BridgeCredentials(endpoint: "wss://one.example/voice").account
        == BridgeCredentials(endpoint: "wss://one.example:443/voice").account,
    "endpoint Keychain account normalizes the default secure port"
)

if let body = try? client.makeQueryData(
    "cik ir pulkstenis",
    bridgeTTS: false,
    requestID: "request-123"
),
   let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
    expect(json["locale"] as? String == "lv-LV", "query carries selected locale")
    expect(json["text"] as? String == "cik ir pulkstenis", "query carries user text")
    expect(json["tts"] as? Bool == false, "query carries local TTS choice")
    expect(json["request_id"] as? String == "request-123",
           "query carries request identity")
} else {
    expect(false, "client builds query JSON")
}

let welcome = #"{"type":"welcome","capabilities":{"vision":false}}"#.data(using: .utf8)!
expect(HermesAPIClient.parseCapabilities(from: welcome)?.vision == false,
       "welcome parser reads disabled vision")
expect(HermesAPIClient.parseCapabilities(from: welcome)?.turnCancel == false,
       "welcome parser defaults missing turn cancellation to false")
expect(HermesAPIClient.parseCapabilities(from: welcome)?.followUpMode == false,
       "welcome parser defaults missing follow-up mode to false")
let cancellableWelcome = #"{"type":"welcome","capabilities":{"turn_cancel":true,"follow_up_mode":true}}"#.data(using: .utf8)!
expect(HermesAPIClient.parseCapabilities(from: cancellableWelcome)?.turnCancel == true,
       "welcome parser reads turn cancellation capability")
expect(HermesAPIClient.parseCapabilities(from: cancellableWelcome)?.followUpMode == true,
       "welcome parser reads follow-up mode capability")
let noVisionKey = #"{"type":"welcome"}"#.data(using: .utf8)!
expect(HermesAPIClient.parseCapabilities(from: noVisionKey)?.vision == false,
       "welcome parser defaults missing vision to false")
expect(HermesAPIClient.parseCapabilities(from: Data("{}".utf8)) == nil,
       "non-welcome frame is not capabilities")
let adamWelcome = #"{"type":"welcome","capabilities":{"audio_upload":true,"server_stt":true,"streaming_tts":true}}"#.data(using: .utf8)!
expect(HermesAPIClient.parseCapabilities(from: adamWelcome)?.supportsAdamVoice == true,
       "Adam accepts a welcome with every required server speech capability")
let incompleteAdamWelcome = #"{"type":"welcome","capabilities":{"audio_upload":true,"server_stt":true,"streaming_tts":false}}"#.data(using: .utf8)!
expect(HermesAPIClient.parseCapabilities(from: incompleteAdamWelcome)?.supportsAdamVoice == false,
       "Adam rejects a welcome missing a required server speech capability")

if let body = try? client.makeAudioStartData(
    requestID: "follow-up-123",
    vocabulary: ["Donzo", "Vārti"],
    followUp: true
),
   let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
    expect(json["type"] as? String == "audio_start",
           "audio capture builder emits opening frame")
    expect(json["request_id"] as? String == "follow-up-123",
           "audio capture carries request identity")
    expect(json["follow_up"] as? Bool == true,
           "audio capture identifies follow-up turns")
    expect(json["wake_verified"] as? Bool == true,
           "audio capture retains verified wake provenance")
} else {
    expect(false, "client builds follow-up audio start JSON")
}

// Adam's rolling pre-roll buffer trims old PCM with removeFirst(). Foundation
// Data retains its original indices after that operation, so upload chunking
// must use startIndex/endIndex rather than assuming a zero-based collection.
var rollingAudio = Data(repeating: 0x5A, count: 50_000)
rollingAudio.removeFirst(12_345)
let uploadRanges = HermesAPIClient.audioUploadRanges(
    for: rollingAudio,
    chunkSize: 16_384
)
expect(rollingAudio.startIndex == 12_345,
       "regression fixture has non-zero Data start index")
expect(uploadRanges.first?.lowerBound == rollingAudio.startIndex,
       "audio upload begins at the recording's actual start index")
expect(uploadRanges.last?.upperBound == rollingAudio.endIndex,
       "audio upload ends at the recording's actual end index")
expect(uploadRanges.reduce(0) { $0 + $1.count } == rollingAudio.count,
       "audio upload chunks cover every recorded byte exactly once")
expect(uploadRanges.allSatisfy { $0.count <= 16_384 },
       "audio upload chunks respect the WebSocket frame limit")
expect(
    uploadRanges.allSatisfy {
        rollingAudio.indices.contains($0.lowerBound)
            && $0.upperBound <= rollingAudio.endIndex
    },
    "every audio upload range is valid for the source Data"
)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
