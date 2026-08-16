//
// Standalone tests for FaceMatcher. No XCTest target:
//   xcrun swiftc \
//     HermesGlasses/Services/People/RosterPerson.swift \
//     HermesGlasses/Services/People/FaceMatcher.swift \
//     tests/face-match/main.swift -o /tmp/face-match-tests \
//     && /tmp/face-match-tests
//
// This is where every false identification would come from, so the shape of
// the accept rule is pinned here: a threshold AND a runner-up margin.
// Cosine similarity always HAS a nearest neighbour, and a threshold alone
// will happily elect it - including for a face belonging to nobody in the
// roster. The person whose name would land on a stranger's face is standing
// right there, which is why `ambiguous` exists as an answer.
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)") }
}

/// L2-normalised vector at a given angle in the first two dimensions - lets
/// the tests state similarities directly as cos(angle).
func vec(_ radians: Float) -> [Float] { [cos(radians), sin(radians), 0, 0] }

let probe = vec(0)                    // similarity to vec(t) is cos(t)
let near = vec(0.20)                  // cos ~ 0.980
let mid = vec(0.50)                   // cos ~ 0.878
let far = vec(1.20)                   // cos ~ 0.362

func makePerson(_ name: String, _ embeddings: [[Float]]) -> RosterPerson {
    RosterPerson(name: name, photoFilenames: embeddings.map { _ in "x.jpg" },
                 embeddings: embeddings, modelID: "test")
}

var matcher = FaceMatcher(acceptThreshold: 0.60, margin: 0.08)

// MARK: - Cosine

expect(abs(FaceMatcher.cosine(probe, probe) - 1) < 1e-5, "a vector matches itself at 1")
expect(abs(FaceMatcher.cosine(probe, vec(.pi)) + 1) < 1e-5, "an opposite vector scores -1")
expect(FaceMatcher.cosine([1, 0], [1, 0, 0]) == 0,
       "mismatched dimensions score zero, never crash")
expect(FaceMatcher.cosine([], []) == 0, "empty vectors score zero")
expect(FaceMatcher.cosine([0, 0], [1, 0]) == 0, "a zero vector scores zero, not NaN")

// An un-normalised vector must not inflate the score past 1.
expect(abs(FaceMatcher.cosine([10, 0], [1, 0]) - 1) < 1e-5,
       "cosine normalises defensively")

// MARK: - Empty roster

if case .unknown(.emptyRoster) = matcher.match(probe: probe, gallery: []) {
    expect(true, "an empty roster is emptyRoster, not belowThreshold")
} else {
    expect(false, "an empty roster is emptyRoster, not belowThreshold")
}

// A roster of people with no embeddings is just as empty.
if case .unknown(.emptyRoster) = matcher.match(
    probe: probe, gallery: [makePerson("Details Only", [])]
) {
    expect(true, "people with no embeddings do not make a roster matchable")
} else {
    expect(false, "people with no embeddings do not make a roster matchable")
}

// MARK: - A clear winner

let winner = makePerson("Near", [near])
let loser = makePerson("Far", [far])
var result = matcher.match(probe: probe, gallery: [loser, winner])
if case .match(let id, let score) = result {
    expect(id == winner.id, "the closest person wins")
    expect(score > 0.97, "the score is the cosine similarity (got \(score))")
} else {
    expect(false, "a clear winner is a match (got \(result))")
}

// A roster of ONE has no runner-up, so the threshold stands alone.
result = matcher.match(probe: probe, gallery: [winner])
if case .match = result {
    expect(true, "a roster of one matches on the threshold alone")
} else {
    expect(false, "a roster of one matches on the threshold alone (got \(result))")
}

// MARK: - Below threshold

matcher = FaceMatcher(acceptThreshold: 0.95, margin: 0.02)
result = matcher.match(probe: probe, gallery: [makePerson("Mid", [mid])])
if case .unknown(.belowThreshold(let best)) = result {
    expect(abs(best - 0.878) < 0.01, "belowThreshold reports the best score (got \(best))")
} else {
    expect(false, "a too-distant best is belowThreshold (got \(result))")
}

// Below threshold beats ambiguous: two equally-distant strangers are not in
// the roster at all, and saying "too close to call" would imply they are.
result = matcher.match(probe: probe,
                       gallery: [makePerson("A", [far]), makePerson("B", [far])])
if case .unknown(.belowThreshold) = result {
    expect(true, "the threshold is checked before the margin")
} else {
    expect(false, "the threshold is checked before the margin (got \(result))")
}

// MARK: - Ambiguous: two people inside the margin

matcher = FaceMatcher(acceptThreshold: 0.60, margin: 0.08)
let twinA = makePerson("Twin A", [vec(0.20)])   // 0.980
let twinB = makePerson("Twin B", [vec(0.25)])   // 0.969 - inside 0.08
result = matcher.match(probe: probe, gallery: [twinA, twinB])
if case .unknown(.ambiguous(let best, let runnerUp)) = result {
    expect(best > runnerUp, "ambiguous reports best and runner-up in order")
    expect(best - runnerUp < 0.08, "and they are inside the margin")
} else {
    expect(false, "two people inside the margin is ambiguous, never a guess (got \(result))")
}

// Widen the gap and the same pair resolves.
let distant = makePerson("Distant", [vec(0.90)])  // 0.622, well outside
result = matcher.match(probe: probe, gallery: [twinA, distant])
if case .match(let id, _) = result {
    expect(id == twinA.id, "a clear gap resolves to the nearer person")
} else {
    expect(false, "a clear gap resolves (got \(result))")
}

// MARK: - A person's score is their BEST photo, not their average

// One good portrait and one poor one must not average into a rejection -
// which is exactly what a roster with a frontal and a profile shot has.
let twoPhotos = makePerson("Two Photos", [near, far])
result = matcher.match(probe: probe, gallery: [twoPhotos, makePerson("Other", [vec(1.4)])])
if case .match(let id, let score) = result {
    expect(id == twoPhotos.id, "the best photo carries the person")
    expect(score > 0.97, "and the score is that photo's, not a mean (got \(score))")
} else {
    expect(false, "max-over-photos matches (got \(result))")
}

// The margin is computed against a DIFFERENT person, never a second photo
// of the same one - otherwise everyone with two good portraits is ambiguous
// with themselves and can never be identified.
let sameTwice = makePerson("Same Twice", [vec(0.20), vec(0.21)])
result = matcher.match(probe: probe, gallery: [sameTwice, makePerson("Far", [far])])
if case .match(let id, _) = result {
    expect(id == sameTwice.id, "two near photos of one person are not ambiguous")
} else {
    expect(false, "two near photos of one person are not ambiguous (got \(result))")
}

// MARK: - Malformed input never matches

result = matcher.match(probe: [], gallery: [winner])
if case .unknown = result {
    expect(true, "an empty probe matches nobody")
} else {
    expect(false, "an empty probe matches nobody (got \(result))")
}

result = matcher.match(probe: [1, 0], gallery: [winner])  // wrong dimension
if case .unknown = result {
    expect(true, "a wrong-dimension probe matches nobody")
} else {
    expect(false, "a wrong-dimension probe matches nobody (got \(result))")
}

// A person carrying one good and one malformed embedding still matches on
// the good one - a corrupt vector costs a photo, never the person.
let halfBroken = makePerson("Half Broken", [[1, 0], near])
result = matcher.match(probe: probe, gallery: [halfBroken])
if case .match(let id, _) = result {
    expect(id == halfBroken.id, "a malformed embedding costs a photo, not the person")
} else {
    expect(false, "a malformed embedding costs a photo, not the person (got \(result))")
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
