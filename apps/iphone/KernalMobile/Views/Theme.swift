import SwiftUI

enum KernalTheme {
    static let background = Color(red: 0.035, green: 0.065, blue: 0.11)
    static let surface = Color(red: 0.07, green: 0.11, blue: 0.17)
    static let accent = Color(red: 0.31, green: 0.86, blue: 0.77)
}

@MainActor
struct StatusPill: View {
    let title: String
    var symbol: String = "checkmark.shield"

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(KernalTheme.accent.opacity(0.12), in: Capsule())
            .foregroundStyle(KernalTheme.accent)
    }
}

@MainActor
struct CapabilityUnavailableView: View {
    let title: String
    let symbol: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol,
            description: Text("This capability is unavailable in this offline build."))
    }
}

@MainActor
struct PlainOutput: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(verbatim: text.isEmpty ? "(empty)" : text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(KernalTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}
