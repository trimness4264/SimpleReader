import SwiftUI

struct DownloadsView: View {
    @ObservedObject var manager: DownloadManager
    var body: some View {
        List {
            if manager.jobs.isEmpty { Text("从在线书库选择图书后，下载会显示在这里。").foregroundColor(.secondary) }
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
        }.navigationTitle("下载")
    }
    private func label(_ state: DownloadJob.State) -> String {
        switch state { case .queued: return "等待下载"; case .downloading: return "正在下载"; case .importing: return "正在加入书库"; case .finished: return "已加入书库"; case .failed: return "下载失败"; case .cancelled: return "已取消" }
    }
}
