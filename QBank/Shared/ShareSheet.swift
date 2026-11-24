import SwiftUI
import UIKit

/// The system share sheet for one file, shown over the screen that asked for it.
struct ShareSheet: UIViewControllerRepresentable {
    let file: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [file], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// A file named for the sheet that shares it; the file's address is its identity.
struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}
