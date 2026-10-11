import SwiftUI

struct DownloadsView: View {
    @ObservedObject var manager: DownloadManager
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            if manager.jobs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle").font(.largeTitle)
                    Text("暂无下载").font(.headline)
                    Text("从在线书库下载的图书会自动加入书库。").font(.subheadline)
                }.foregroundColor(.secondary).frame(maxWidth: .infinity).padding(.vertical, 32)
            }
            ForEach(manager.jobs) { job in
                VStack(alignment: .leading, spacing: 8) {
                    Text(job.title).font(.headline)
                    HStack { Text(label(job.state)).font(.caption).foregroundColor(.secondary); Spacer(); if job.state == .downloading { Text("\(Int(job.progress*100))%").font(.caption.monospacedDigit()) } }
                    if job.state == .downloading { ProgressView(value: job.progress) }
                    if let error = job.error { Text(error).font(.caption).foregroundColor(.red) }
                    if [.queued, .downloading].contains(job.state) { Button("取消") { manager.cancel(job.id) } }
                    if [.failed, .cancelled].contains(job.state) { Button("重新下载") { manager.retry(job.id) } }
                }.padding(.vertical, 6)
            }
        }.navigationTitle("下载").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) { Button("关闭") { dismiss() } }
            ToolbarItem(placement: .navigationBarTrailing) {
                if manager.hasHistory { Button("清除历史") { manager.clearHistory() } }
            }
        }
    }
    private func label(_ state: DownloadJob.State) -> String {
        switch state { case .queued: return "等待下载"; case .downloading: return "正在下载"; case .importing: return "正在加入书库"; case .finished: return "已加入书库"; case .failed: return "下载失败"; case .cancelled: return "已取消" }
    }
}

struct DownloadsToolbarButton: View {
    @ObservedObject var manager: DownloadManager
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
                .accessibilityLabel("下载")
                .accessibilityValue("\(manager.activeCount) 项进行中，\(manager.failedCount) 项失败")
                .sheet(isPresented: $presented) {
                    NavigationView { DownloadsView(manager: manager) }.navigationViewStyle(.stack)
                }
            }
        }
    }
}
