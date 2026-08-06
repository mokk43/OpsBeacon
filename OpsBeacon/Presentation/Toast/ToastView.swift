import SwiftUI

@MainActor
struct ToastView: View {
    let snapshot: AlertSnapshot
    let acknowledge: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("OpsBeacon", systemImage: severitySymbol)
                    .accessibilityLabel("OpsBeacon \(severityLabel) alerts")
                Spacer()
                Text("\(snapshot.displayedAlerts.count) alerts")
                if snapshot.omittedCount > 0 { Text("+\(snapshot.omittedCount) omitted") }
            }
            .font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(snapshot.displayedAlerts) { alert in
                        Text("\(formatted(alert.occurrenceTime)) · \(alert.sourceName) · \(alert.message)")
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(alert.message)
                            .contextMenu { Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(alert.message, forType: .string) } }
                            .accessibilityLabel(Text(verbatim: "\(String(describing: alert.severity)) alert from \(alert.sourceName): \(alert.message)"))
                    }
                }
            }
            HStack {
                Spacer()
                Button("Acknowledge all", action: acknowledge)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Acknowledge all displayed alerts")
            }
        }
        .padding(14)
        .background(.regularMaterial)
    }

    private var severityLabel: String { snapshot.highestSeverity.map { "\($0)" } ?? "no" }

    private var severitySymbol: String {
        switch snapshot.highestSeverity {
        case .critical: "exclamationmark.triangle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .info: "info.circle.fill"
        case nil: "bell"
        }
    }

    private func formatted(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.year().month().day().hour().minute())
    }
}
