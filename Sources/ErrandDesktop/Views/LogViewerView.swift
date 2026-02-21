import SwiftUI

/// Log viewer window with service filter.
struct LogViewerView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedService: String?

    private var filteredLogs: [LogEntry] {
        guard let service = selectedService else { return appState.logs }
        return appState.logs.filter { $0.service == service }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            HStack {
                Text("Service:")
                Picker("Service", selection: $selectedService) {
                    Text("All").tag(String?.none)
                    ForEach(appState.services) { service in
                        Text(service.displayName).tag(Optional(service.id))
                    }
                }
                .labelsHidden()
                .frame(width: 150)

                Spacer()

                Button("Copy") {
                    let text = filteredLogs.map { entry in
                        let ts = entry.timestamp.formatted(.dateTime.hour().minute().second())
                        return "[\(ts)] \(entry.service): \(entry.message)"
                    }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }

                Button("Clear") {
                    appState.logs.removeAll()
                }
            }
            .padding(10)

            Divider()

            // Log entries
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filteredLogs) { entry in
                            LogEntryRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: appState.logs.count) {
                    if let last = filteredLogs.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .background(.background)
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}

// MARK: - Log Entry Row

private struct LogEntryRow: View {
    let entry: LogEntry

    private static let serviceColors: [String: Color] = [
        "postgres": .blue,
        "valkey": .purple,
        "backend": .green,
        "worker": .orange,
        "litellm": .cyan,
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)

            Text(entry.service)
                .foregroundStyle(Self.serviceColors[entry.service] ?? .primary)
                .fontWeight(.medium)
                .frame(width: 70, alignment: .leading)

            Text(entry.message)
        }
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
    }
}
