//
// ShareSheet.swift
//
// Thin SwiftUI wrapper over UIActivityViewController for sharing a file
// (the exported PDF) to WhatsApp, Mail, Files, etc.
//

import SwiftUI

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
