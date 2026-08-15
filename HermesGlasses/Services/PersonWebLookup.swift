//
// PersonWebLookup.swift
//
// The Lookup app's web pass: a badge NAME (plus whatever org/title the
// badge offered) goes to the configured AI provider with web search on,
// and a couple of sentences about who that person is come back.
//
// What deliberately does NOT go out: the photo. The person is identified
// by the badge they chose to wear in public, never by their face - this
// app has no face recognition and this file is one of the places that
// keeps it that way. The call runs through `askOneShotText`, so nothing
// lands in the user's conversation memory either.
//

import Foundation

enum PersonWebLookup {
    /// The event the wearer is at, folded into the query so "J. Smith"
    /// finds the attendee, not the most famous J. Smith on earth.
    static let eventContext = "ICE 2026"

    /// How long one lookup may take before the wearer stops caring.
    static let timeout: TimeInterval = 30

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
}
