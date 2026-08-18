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
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(snapshot.displayedAlerts) { alert in
                        AlertRow(alert: alert)
                    }
                }
            }
            .scrollClipDisabled()
            HStack {
                Spacer()
                Button("Acknowledge", action: acknowledge)
                    .scaleEffect(1.2)
                    .padding(.vertical, 2)
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
}

@MainActor
private struct AlertRow: View {
    let alert: Alert

    @State private var isHovering = false
    @State private var showTooltip = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Text(rowText)
            .font(.system(size: 18))
            .foregroundStyle(.blue)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover(perform: handleHover)
            .onDisappear { cancelHover(hideTooltip: true) }
            .overlay(alignment: .topLeading) {
                if showTooltip {
                    tooltip
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(y: 26)
                }
            }
            .zIndex(showTooltip ? 1 : 0)
            .contextMenu {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(alert.message, forType: .string)
                }
            }
            .accessibilityLabel(Text(verbatim: "\(String(describing: alert.severity)) : \(alert.message)"))
            .accessibilityHint(Text(verbatim: tooltipText))
    }

    private var rowText: String {
        "\(formatted(alert.occurrenceTime)) · \(alert.message)"
    }

    private var tooltipText: String {
        var lines = [alert.message, "Rule: \(alert.ruleName)"]
        if let attributes = alert.attributes, !attributes.isEmpty {
            lines.append(contentsOf: attributes.keys.sorted().map { key in
                "\(key): \(stringValue(attributes[key] ?? .null))"
            })
        }
        return lines.joined(separator: "\n")
    }

    private var tooltip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(alert.message)
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
            Text("Rule: \(alert.ruleName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator.opacity(0.45))
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func handleHover(_ hovering: Bool) {
        isHovering = hovering
        cancelHover(hideTooltip: !hovering)
        guard hovering else { return }
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, isHovering else { return }
            showTooltip = true
        }
    }

    private func cancelHover(hideTooltip: Bool) {
        hoverTask?.cancel()
        hoverTask = nil
        if hideTooltip { showTooltip = false }
    }

    private func formatted(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.year().month().day().hour().minute())
    }

    private func stringValue(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .boolean(let flag): flag ? "true" : "false"
        case .number(let number): number
        case .string(let string): string
        case .array: "[…]"
        case .object: "{…}"
        }
    }
}
