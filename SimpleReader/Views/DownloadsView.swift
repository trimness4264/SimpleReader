import SwiftUI

struct DownloadsView: View {
    @ObservedObject var manager: DownloadManager
    let environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var reading: Book?
    var body: some View {
        List {
            if manager.jobs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle").font(.largeTitle)
                    Text("No Downloads").font(.headline)
                    Text("Books downloaded from an online library appear in your library automatically.").font(.subheadline)
                }.foregroundColor(.secondary).frame(maxWidth: .infinity).padding(.vertical, 32)
            }
            ForEach(manager.jobs) { job in
                let actions = manager.actions(for: job)
                VStack(alignment: .leading, spacing: 8) {
                    Text(job.title).font(.headline)
                    HStack { Text(label(job.state, bookID: actions.bookID)).font(.caption).foregroundColor(.secondary); Spacer(); if job.state == .downloading { Text("\(Int(job.progress*100))%").font(.caption.monospacedDigit()) } }
                    if job.state == .downloading { ProgressView(value: job.progress) }
                    if let error = job.error { Text(error).font(.caption).foregroundColor(.red) }
                    if actions.canCancel { Button("Cancel") { manager.cancel(job.id) } }
                    if actions.canRetry { Button("Download Again") { manager.retry(job.id) } }
                    if let id = actions.bookID { Button("Read") { reading = environment.store.book(id) } }
                }.padding(.vertical, 6)
            }
        }.navigationTitle("Downloads").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) { Button("Close") { dismiss() } }
            ToolbarItem(placement: .navigationBarTrailing) {
                if manager.hasHistory { Button("Clear History") { manager.clearHistory() } }
            }
        }
        .fullScreenCover(item: $reading) { book in ReaderView(bookID: book.id, environment: environment) }
    }
    private func label(_ state: DownloadJob.State, bookID: UUID?) -> LocalizedStringKey {
        switch state { case .queued: return "Queued"; case .downloading: return "Downloading"; case .importing: return "Adding to library"; case .finished: return bookID == nil ? "Removed from library" : "Added to library"; case .failed: return "Download failed"; case .cancelled: return "Canceled" }
    }
}

struct DownloadsToolbarButton: View {
    @ObservedObject var manager: DownloadManager
    let environment: AppEnvironment
    var alwaysVisible = false
    @State private var presented = false

    var body: some View {
        Group {
            if alwaysVisible || !manager.jobs.isEmpty {
                Button { presented = true } label: {
                    Image(systemName: "arrow.down.circle")
                        .overlay(alignment: .topTrailing) {
                            if manager.activeCount + manager.failedCount > 0 {
                                Text("\(manager.activeCount + manager.failedCount)")
                                    .font(.caption2.bold()).monospacedDigit()
                                    .foregroundColor(.white).padding(.horizontal, 4)
                                    .background(manager.failedCount > 0 ? Color.red : Color.accentColor, in: Capsule())
                                    .offset(x: 9, y: -8)
                            }
                        }
                }
                .accessibilityLabel("Downloads")
                .accessibilityValue("\(manager.activeCount) active, \(manager.failedCount) failed")
                .sheet(isPresented: $presented) {
                    NavigationStack { DownloadsView(manager: manager, environment: environment) }
                }
            }
        }
    }
}
