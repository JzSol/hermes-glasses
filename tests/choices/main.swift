//
// Standalone tests for ChoiceDetector. No XCTest target, so build via swiftc:
//   xcrun swiftc \
//     HermesGlasses/Services/ChoiceDetector.swift \
//     tests/choices/main.swift -o /tmp/choice-tests && /tmp/choice-tests
//
// The bar these have to clear: fire on a real multiple-choice reply, and
// stay silent on ordinary prose that merely contains a bracket or a dash.
// A wrong hit replaces Stop/Repeat on the lens with nonsense buttons.
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)") }
}
func expectLabels(_ text: String, _ want: [String], _ label: String) {
    let got = ChoiceDetector.choices(in: text).map(\.label)
    expect(got == want, "\(label)\n     got  \(got)\n     want \(want)")
}
func expectNone(_ text: String, _ label: String) {
    let got = ChoiceDetector.choices(in: text)
    expect(got.isEmpty, "\(label) (got \(got.map(\.label)))")
}

// MARK: - Lettered, the case from the field

expectLabels(
    "Sure! Here's one: What's the capital of Australia? A) Sydney, B) Melbourne, C) Canberra, or D) Perth. What's your guess?",
    ["Sydney", "Melbourne", "Canberra", "Perth"],
    "lettered inline with a trailing 'or' and a following sentence"
)

expectLabels(
    "Pick one: A. Coffee B. Tea C. Water",
    ["Coffee", "Tea", "Water"],
    "lettered with full stops and no commas"
)

expectLabels(
    "Options are (a) walk, (b) drive.",
    ["walk", "drive"],
    "parenthesised lowercase letters"
)

// MARK: - Numbered

expectLabels(
    "Which one? 1) Red 2) Green 3) Blue",
    ["Red", "Green", "Blue"],
    "numbered inline"
)

expectLabels(
    "Choose:\n1. Espresso\n2. Latte\n3. Flat white\n",
    ["Espresso", "Latte", "Flat white"],
    "numbered on separate lines"
)

// MARK: - Bulleted lines

expectLabels(
    "Here are the options:\n- Walk there\n- Take the bus\n- Drive",
    ["Walk there", "Take the bus", "Drive"],
    "hyphen bullets"
)

expectLabels(
    "Options:\n• Yes\n• No",
    ["Yes", "No"],
    "bullet character"
)

// MARK: - Must NOT fire

expectNone(
    "That's a Monstera deliciosa. The yellowing on the lower leaf usually means it's getting too much water.",
    "ordinary prose"
)
expectNone(
    "I'd go with option B) it's closer.",
    "a single marker is not a list"
)
expectNone(
    "The meeting is at 3) no wait, 4pm.",
    "one stray marker mid-sentence"
)
expectNone(
    "Turn right on Market - 200 m",
    "a hyphen in prose is not a bullet"
)
expectNone("", "empty reply")
expectNone("Yes.", "one-word reply")

// Out-of-order markers are almost certainly not a list.
expectNone(
    "See section C) and then A) for details",
    "markers out of sequence"
)

// MARK: - Shape of the result

let choices = ChoiceDetector.choices(
    in: "What's the capital of Australia? A) Sydney, B) Melbourne, C) Canberra, or D) Perth."
)
expect(choices.count == 4, "four choices found")
expect(choices[0].key == "A", "key preserved for the lens button")
expect(choices[2].label == "Canberra", "third label")
// What gets sent back is the words, not the letter - "C" alone reads as
// noise to the assistant, "Canberra" is an answer.
expect(choices[2].reply == "Canberra", "reply text is the label")
expect(choices.allSatisfy { !$0.label.isEmpty }, "no empty labels")

// MARK: - Lens fit

let long = ChoiceDetector.choices(
    in: "Pick: A) The first extremely long option that would never fit on a lens button B) Short"
)
expect(long.count == 2, "long options still parsed")
expect(long[0].shortLabel.count <= 24, "shortLabel is trimmed for a button")
expect(long[0].reply.contains("extremely long"), "full text kept for the reply")

// A reply with more options than a lens can show is capped, not mangled.
let many = ChoiceDetector.choices(
    in: "1) one 2) two 3) three 4) four 5) five 6) six 7) seven"
)
expect(many.count <= ChoiceDetector.maxChoices,
       "capped at \(ChoiceDetector.maxChoices) (got \(many.count))")
expect(many.first?.label == "one", "cap keeps the first options, in order")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
