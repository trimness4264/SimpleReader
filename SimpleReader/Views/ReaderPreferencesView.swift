import SwiftUI

struct ReaderPreferencesView: View {
    let settings: ReaderSettings
    var supportsScrolling = true
    let update: ((inout ReaderSettings) -> Void) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        Form {
            if supportsScrolling {
                Section(header: Text("Reading Mode")) {
                    Picker("Reading Mode", selection: preference(\.layout)) {
                        Text("Paginated").tag(ReadingLayout.paginated)
                        Text("Continuous Scrolling").tag(ReadingLayout.scroll)
                    }.pickerStyle(.segmented)
                }
                Section(header: Text("Typography")) {
                    Picker("Font", selection: preference(\.font)) {
                        Text("Book Serif").tag(ReaderFont.serif)
                        Text("System Sans Serif").tag(ReaderFont.system)
                    }
                    VStack(alignment: .leading) {
                        Text("Font size: \(Int(settings.fontSize))%")
                        Slider(value: preference(\.fontSize), in: 80...200, step: 10)
                            .accessibilityLabel("Font size")
                    }
                    VStack(alignment: .leading) {
                        Text("Line spacing: \(settings.lineHeight, specifier: "%.2f")×")
                        Slider(value: preference(\.lineHeight), in: 1.2...2.0, step: 0.05)
                            .accessibilityLabel("Line spacing")
                    }
                    VStack(alignment: .leading) {
                        Text("Page margins: \(settings.pageMargins, specifier: "%.2f")×")
                        Slider(value: preference(\.pageMargins), in: 0.5...2.0, step: 0.25)
                            .accessibilityLabel("Page margins")
                    }
                }
            }
            Picker("Theme", selection: preference(\.theme)) {
                Text("System").tag(ReaderTheme.system)
                Text("Light").tag(ReaderTheme.light)
                Text("Dark").tag(ReaderTheme.dark)
            }
        }
        .navigationTitle("Reading Settings").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
        .errorAlert($error)
    }
    private func preference<Value>(_ key: WritableKeyPath<ReaderSettings, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: key] }, set: { value in
            do { try update { $0[keyPath: key] = value } }
            catch { self.error = error.localizedDescription }
        })
    }
}
