import SwiftUI

/// Settings > Slideshow. A placeholder until the slideshow is built.
struct SlideshowSettingsView: View {
    var body: some View {
        Form {
            Text("Slideshow settings").foregroundStyle(.secondary)
        }
        .settingsForm()
    }
}
