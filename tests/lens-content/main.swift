//
// Standalone tests for LensContent. No XCTest target, so build via swiftc:
//   xcrun swiftc \
//     HermesGlasses/Services/Navigation/NavigationTypes.swift \
//     HermesGlasses/Services/ChoiceDetector.swift \
//     HermesGlasses/Services/LensContent.swift \
//     tests/lens-content/main.swift -o /tmp/lens-content-tests \
//     && /tmp/lens-content-tests
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)") }
}
func expectEqual(_ got: String?, _ want: String?, _ label: String) {
    expect(got == want, "\(label) (got \(got ?? "nil"), want \(want ?? "nil"))")
}

// MARK: - blank

expect(LensContent.blank.isBlank, "blank is blank")
expect(!LensContent.recording.isBlank, "recording is not blank")
expectEqual(LensContent.blank.body, "", "blank body is empty")
expectEqual(LensContent.blank.label, nil, "blank has no label")
expectEqual(LensContent.blank.statusLine, nil, "blank has no status line")
expect(!LensContent.blank.isLive, "blank is not live")

// MARK: - listening

let listening = LensContent.listening(partial: "how often should I water it")
expectEqual(listening.label, "LISTENING", "listening label")
expectEqual(listening.body, "how often should I water it", "listening body is the partial")
expectEqual(listening.statusLine, "listening", "listening status line")
expect(listening.isLive, "listening is live")
expectEqual(LensContent.listening(partial: "").body, "", "empty partial gives empty body")

// MARK: - thinking

let thinking = LensContent.thinking(query: "what's on my calendar")
expectEqual(thinking.label, nil, "thinking has no label - the query is the content")
expectEqual(thinking.body, "what's on my calendar", "thinking body is the query")
expectEqual(thinking.statusLine, "thinking…", "thinking status line")

// MARK: - reply

let speaking = LensContent.reply(text: "It's a Monstera.", speaking: true)
let spoken = LensContent.reply(text: "It's a Monstera.", speaking: false)
expectEqual(speaking.body, "It's a Monstera.", "reply body")
expectEqual(speaking.statusLine, "speaking", "reply shows speaking while TTS plays")
expectEqual(spoken.statusLine, nil, "reply drops the status line after speech")
expectEqual(speaking.label, nil, "reply has no label")
expect(speaking.isLive && spoken.isLive, "replies are live")
expect(speaking != spoken, "speaking flag participates in equality")

// A reply that offered options says so instead of "speaking" - the wearer
// needs to know there is something to tap.
let withChoices = LensContent.reply(
    text: "A) Sydney, B) Melbourne", speaking: false,
    choices: ChoiceDetector.choices(in: "A) Sydney, B) Melbourne")
)
expectEqual(withChoices.statusLine, "2 options - tap one",
            "a reply with options advertises them")
expect(withChoices != LensContent.reply(text: "A) Sydney, B) Melbourne", speaking: false),
       "choices participate in equality, so the buttons redraw")

// MARK: - definition

let defWithImage = LensContent.definition(text: "A tree.", imageURL: "https://x/y.jpg")
let defNoImage = LensContent.definition(text: "A tree.", imageURL: nil)
expectEqual(defWithImage.imageURL, "https://x/y.jpg", "definition exposes its image")
expectEqual(defNoImage.imageURL, nil, "definition without an image")
expectEqual(defWithImage.body, "A tree.", "definition body")
expect(defWithImage != defNoImage, "image URL participates in equality")

// MARK: - navigation

let nav = LensContent.navigation(
    title: "Blue Bottle Coffee", step: "Turn right on Market - 200 m",
    eta: "6 min", mapURL: "https://api.mapbox.com/x", mode: .walking
)
expectEqual(nav.label, "NAVIGATION", "navigation label")
expectEqual(nav.body, "Turn right on Market - 200 m", "navigation body is the step")
expectEqual(nav.statusLine, "walking · 6 min to Blue Bottle Coffee",
            "navigation status line names the mode, eta and destination")
expectEqual(nav.imageURL, "https://api.mapbox.com/x", "navigation exposes the map URL")
let navNoMap = LensContent.navigation(
    title: "Home", step: "Continue", eta: "2 min", mapURL: nil, mode: .driving
)
expectEqual(navNoMap.imageURL, nil, "navigation without a token has no map URL")
expectEqual(navNoMap.statusLine, "driving · 2 min to Home",
            "status line works without a map, and shows driving")

// The mode is part of identity: a walk and a drive to the same place are
// different lens states, and the buttons must redraw.
expect(
    LensContent.navigation(title: "A", step: "B", eta: "C", mapURL: nil, mode: .walking)
        != LensContent.navigation(title: "A", step: "B", eta: "C", mapURL: nil, mode: .driving),
    "transport mode participates in equality"
)

// MARK: - social

expectEqual(LensContent.encounterPrompt.label, "WHO IS THIS?", "encounter prompt label")
expectEqual(
    LensContent.encounterPrompt.statusLine, "waiting for a note",
    "encounter prompt status line"
)
expectEqual(LensContent.recording.label, "RECORDING", "recording label")
expectEqual(
    LensContent.recording.statusLine, "say \"stop recording\" to finish",
    "recording tells you how to stop"
)
expectEqual(
    LensContent.encounterSaved(note: "Sarah, AR team").body, "Sarah, AR team",
    "saved shows the note back"
)
expectEqual(
    LensContent.encounterSaved(note: "").body, "Note saved",
    "an empty note still confirms the save"
)
expect(!LensContent.encounterSaved(note: "x").isLive, "confirmations are not live")

// MARK: - flashes

expectEqual(LensContent.photoCaptured.body, "Photo captured", "photo flash body")
expectEqual(LensContent.newConversation.body, "New conversation", "new chat flash body")
expect(!LensContent.photoCaptured.isLive, "photo flash is not live")
expect(!LensContent.newConversation.isLive, "new chat flash is not live")

// MARK: - every case answers every question

let all: [LensContent] = [
    .blank, .listening(partial: "a"), .thinking(query: "b"), .photoCaptured,
    .reply(text: "c", speaking: true), .definition(text: "d", imageURL: nil),
    .navigation(title: "e", step: "f", eta: "g", mapURL: nil, mode: .walking),
    .encounterPrompt, .recording, .encounterSaved(note: "h"), .newConversation,
    .personSighted(name: "i", subtitle: "j"),
]
expect(all.count == 12, "all 12 cases covered")
// No case may trap: exercising each accessor is the assertion.
for content in all {
    _ = content.label
    _ = content.body
    _ = content.statusLine
    _ = content.imageURL
    _ = content.isLive
    _ = content.isBlank
}
expect(true, "every accessor is total over all cases")

// MARK: - personSighted

let named = LensContent.personSighted(name: "Sarah Chen", subtitle: "Radiology")
expectEqual(named.label, "PERSON", "person sighting is labelled PERSON")
expectEqual(named.body, "Sarah Chen", "named sighting shows the name")
expectEqual(named.statusLine, "Radiology", "subtitle becomes the status line")
expect(!named.isLive, "a sighting flash is not live")
expectEqual(named.imageURL, nil, "a sighting has no remote image")
expect(!named.isBlank, "a sighting is not blank")

let unnamed = LensContent.personSighted(name: nil, subtitle: nil)
expectEqual(unnamed.body, "Photo captured", "unnamed sighting falls back to the flash text")
expectEqual(unnamed.statusLine, nil, "no subtitle means no status line")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
