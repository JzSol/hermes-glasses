//
// PersonWebLookup.swift
//
// The Lookup app's web pass. Two paths, tried in that order:
//
// 1. FACE: the frontal-face crop goes to the configured vision provider
//    with web search on. The provider returns a name plus a couple of
//    sentences about who they are. This is the primary path - the person
//    may not be wearing a badge at all.
// 2. BADGE (fallback): a badge NAME (plus whatever org/title the badge
//    offered) goes to the provider with web search on, exactly as before.
//
// The face photo leaves the device on path 1 - the person is identified by
// their face, not by a badge they chose to wear in public. Both calls run
// through the one-shot helpers (`askOneShot` / `askOneShotText`), so
// nothing lands in the user's conversation memory either.
//

import Foundation

enum PersonWebLookup {
    /// The event the wearer is at, folded into the query so "J. Smith"
    /// finds the attendee, not the most famous J. Smith on earth.
    static let eventContext = "ICE 2026"

    /// How long one lookup may take before the wearer stops caring.
    static let timeout: TimeInterval = 30

    /// The face path is a deeper search than the badge path: more web
    /// search invocations and a longer budget, because naming a stranger
    /// from a photo has to disambiguate namesakes the badge name never
    /// had to. Only Anthropic honours either knob.
    static let faceWebSearchMaxUses = 10
    static let faceTimeout: TimeInterval = 60

    static let systemPrompt = """
        You are a conference networking assistant on the user's smart \
        glasses. The user just met someone and read their name off the \
        conference badge they are wearing. Search the web for who this \
        person is professionally: role, organisation, notable work. \
        Reply with 2-3 short sentences suitable for a small heads-up \
        display - no headings, no lists, no links. Only report what you \
        actually found about a person who plausibly matches the badge; \
        if you cannot find them or cannot tell namesakes apart, say \
        "Couldn't find anything solid online" and stop. Never guess, \
        and never merge different people into one biography.
        """

    /// The face path: identify the person in the photo, no badge involved.
    static let faceSystemPrompt = """
        You are a conference networking assistant on the user's smart \
        glasses. The user is looking directly at a person (see the photo) \
        and wants to know who they are. Search the web for this specific \
        person: their name, role, organisation, and notable work. Put \
        their full name on the FIRST line of your reply and nothing else \
        on that line, then 2-3 short sentences about them suitable for a \
        small heads-up display - no headings, no lists, no links. Only \
        report what you actually found about a person who plausibly \
        matches the photo; if you cannot identify them or cannot tell \
        lookalikes apart, reply with exactly "NO_MATCH" and nothing else. \
        Never guess, and never merge different people into one biography.
        """

    /// The query text, from whatever the badge yielded. Pure, so the
    /// standalone suite can pin its shape.
    static func userText(name: String, org: String?, title: String?) -> String {
        var line = "I just met \(name) at \(eventContext)."
        if let org, !org.isEmpty { line += " Their badge says they're with \(org)." }
        if let title, !title.isEmpty { line += " Badge title: \(title)." }
        line += " Who are they?"
        return line
    }

    /// One web lookup. Throws the provider's own errors (missing key, HTTP)
    /// so the caller can show WHY nothing came back.
    static func lookup(
        name: String, org: String?, title: String?, client: DirectClient
    ) async throws -> String {
        let reply = try await client.askOneShotText(
            systemPrompt: systemPrompt,
            userText: userText(name: name, org: org, title: title),
            webSearch: true,
            timeout: timeout
        )
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One FACE lookup: the face crop goes out with a deep web search.
    /// Returns name + summary, or nil when the provider cannot identify
    /// the person (NO_MATCH) - the caller then falls back to the badge
    /// path. Throws the provider's own errors so the caller can decide
    /// whether to fall back as well.
    static func lookupByFace(
        photoJPEG: Data, client: DirectClient
    ) async throws -> (name: String, summary: String)? {
        let reply = try await client.askOneShot(
            systemPrompt: faceSystemPrompt,
            userText: "Who is the person in this photo? (We're at \(eventContext).)",
            photoJPEG: photoJPEG,
            webSearch: true,
            webSearchMaxUses: faceWebSearchMaxUses,
            timeout: faceTimeout
        )
        return parse(reply)
    }

    /// Split the provider's reply into (name, summary). The name is the
    /// first non-empty line; everything after it is the summary. Nil when
    /// the model said NO_MATCH, or returned nothing. Pure, so the
    /// standalone suite can pin it.
    static func parse(_ reply: String) -> (name: String, summary: String)? {
        var lines = reply
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let name = lines.first, name != "NO_MATCH" else { return nil }
        lines.removeFirst()
        return (name, lines.joined(separator: " "))
    }
}
