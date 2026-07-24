//
// ShareSheet.swift
//
// Thin SwiftUI wrapper over UIActivityViewController for sharing a file
// (the exported PDF) to WhatsApp, Mail, Files, etc.
//

import SwiftUI

/// An exported file to share, wrapped so it can drive `.sheet(item:)` -
/// which passes the unwrapped value into the builder and avoids the empty
/// sheet you get racing `.sheet(isPresented:)` against a separate optional.
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
