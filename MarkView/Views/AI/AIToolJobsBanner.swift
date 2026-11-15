import SwiftUI

struct AIToolJobsBanner: View {
    @Environment(\.palette) private var palette
    @ObservedObject var jobs: AIToolJobs

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(jobs.jobs) { job in
                HStack(spacing: 8) {
                    switch job.phase {
                    case .running:
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(job.title).uiFont(size: 11, weight: .semibold).foregroundColor(palette.text)
                            Text(job.stage).uiFont(size: 10).foregroundColor(palette.textDim)
                        }
                        Button("Stop") { jobs.cancel(job.id) }.buttonStyle(.bordered).controlSize(.small)
                    case .failed(let message):
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(palette.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(job.title) failed").uiFont(size: 11, weight: .semibold).foregroundColor(palette.text)
                            Text(message).uiFont(size: 10).foregroundColor(palette.textDim).lineLimit(3)
                        }
                        Button("Dismiss") { jobs.dismiss(job.id) }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .padding(10)
                .frame(maxWidth: 420, alignment: .leading)
                .background(palette.bg.opacity(0.97))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.textDim.opacity(0.4)))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
    }
}
