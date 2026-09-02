import Foundation

var failures = 0

func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() {
        print("PASS \(label)")
    } else {
        failures += 1
        print("FAIL \(label)")
    }
}

let migrated = HermesAPIClient.migrateLegacyEndpoint(
    "wss://bridge.example.test:8443/voice?token=legacy-secret"
)
expect(migrated.endpoint == "wss://bridge.example.test:8443/voice",
       "legacy token stripped from URL")
expect(migrated.token == "legacy-secret", "legacy token retained in memory")

let validation = HermesEndpointValidationMode.release(
    allowedHosts: ["bridge.example.test"]
)
let client = HermesAPIClient(
    endpoint: migrated.endpoint,
    token: migrated.token ?? "",
    validationMode: validation
)
let request = try? client.makeConnectRequest()
expect(request?.url?.absoluteString == "wss://bridge.example.test:8443/voice",
       "connect request uses sanitized URL")
expect(request?.value(forHTTPHeaderField: "Authorization")
       == "Bearer legacy-secret", "connect request uses bearer header")

let missingTokenClient = HermesAPIClient(
    endpoint: "wss://bridge.example.test:8443/voice",
    token: "",
    validationMode: validation
)
expect((try? missingTokenClient.makeConnectRequest()) == nil,
       "connect request fails closed without bearer token")

expect(
    BridgeCredentials.endpointAccount("wss://Bridge.Example.Test/voice")
        == "endpoint-v1|wss|bridge.example.test|443|/voice",
    "credential account is endpoint scoped"
)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
