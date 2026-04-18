import SwiftUI

struct HostListView: View {
    @Environment(AppModel.self) private var appModel
    @Binding var selection: HostRecord.ID?

    let onCreate: () -> Void
    let onEdit: (HostRecord) -> Void
    let onDelete: (IndexSet) -> Void
    let onDeleteHost: (HostRecord) -> Void
    let onResetEverything: () -> Void

    var body: some View {
        List(selection: $selection) {
            if appModel.hosts.isEmpty {
                ContentUnavailableView(
                    "No Saved Hosts",
                    systemImage: "server.rack",
                    description: Text("Save an SSH host to start building the workspace flow.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(appModel.hosts) { host in
                    Button {
                        selection = host.id
                    } label: {
                        HostRow(host: host)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit Host") {
                            onEdit(host)
                        }
                        Button("Delete Host", role: .destructive) {
                            onDeleteHost(host)
                        }
                    }
                    .tag(host.id)
                }
                .onDelete(perform: onDelete)
            }
        }
        .navigationTitle("Hosts")
        .toolbar {
            if !appModel.hosts.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive, action: onResetEverything) {
                        Label("Reset Everything", systemImage: "arrow.counterclockwise")
                    }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if appModel.hosts.isEmpty {
                Button(action: onCreate) {
                    Label("Add Host", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
        }
    }
}

private struct HostRow: View {
    let host: HostRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(host.nickname)
                .font(.headline)
            Text(host.connectionSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let browserURL = host.browserURLString, !browserURL.isEmpty {
                Label(browserURL, systemImage: host.browserUsesTunnel ? "point.3.connected.trianglepath.dotted" : "safari")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
