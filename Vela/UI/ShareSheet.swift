//
//  Sharesheet.swift
//  Vela
//
//  The system activity sheet, wrapped for SwiftUI.
//

import SwiftUI
import UIKit

// MARK: - Share sheet

/// A `UIActivityViewController` wrapper.
///
/// Shared links go out through the system sheet rather than a hand-built list,
/// which is what gives Vela the same set of destinations as every other app
/// without maintaining a target list.
struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
