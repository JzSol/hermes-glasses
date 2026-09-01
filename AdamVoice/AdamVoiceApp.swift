//
// AdamVoiceApp.swift
//
// Entry point for the free-signing, voice-only Adam prototype.  It has no
// Meta Wearables SDK dependency; Ray-Ban audio is opened through AVAudioSession
// when the session requests the glasses HFP route.
//

import SwiftUI

@main
struct AdamVoiceApp: App {
    @State private var session: AdamVoiceSession

    init() {
        _session = State(initialValue: AdamVoiceSession())
    }

    var body: some Scene {
        WindowGroup {
            AdamVoiceView(session: session)
        }
    }
}
