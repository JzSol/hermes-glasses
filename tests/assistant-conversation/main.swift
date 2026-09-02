import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() {
        print("PASS \(label)")
    } else {
        failures += 1
        print("FAIL \(label)")
    }
}

let t0 = Date(timeIntervalSince1970: 100)
let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
let thirdID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

var history = AssistantConversationHistory(limit: 2)
history.append(ConversationTurn(
    id: firstID,
    userText: "one",
    agentText: "first",
    timestamp: t0
))
history.append(ConversationTurn(
    id: secondID,
    userText: "two",
    agentText: "second",
    timestamp: t0.addingTimeInterval(1)
))

expect(history.turns.count == 2, "history keeps turns below its limit")
expect(history.turns.first?.id == firstID, "history preserves stable turn identity")

let photo = Data([0xFF, 0xD8, 0xFF])
history.append(ConversationTurn(
    id: thirdID,
    userText: "what is this?",
    agentText: "an attachment",
    timestamp: t0.addingTimeInterval(2),
    photo: photo,
    photoSource: "Ray-Ban camera"
))

expect(history.turns.count == 2, "history remains bounded")
expect(history.turns.first?.id == secondID, "history evicts the oldest turn first")
expect(history.turns.last?.photo == photo, "attachment data survives history storage")
expect(history.turns.last?.photoSource == "Ray-Ban camera", "attachment source survives history storage")

let choice = AssistantReplyChoice(id: "AParis", label: "Paris")
expect(choice.id == "AParis" && choice.label == "Paris", "reply choice preserves presentation identity")
expect(
    AssistantConversationActivity.processing("Thinking…")
        == .processing("Thinking…"),
    "activity state preserves product-specific status text"
)

history.clear()
expect(history.turns.isEmpty, "new conversation clears presentation history")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
