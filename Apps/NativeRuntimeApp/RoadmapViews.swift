import SwiftUI

@MainActor
struct VulnerabilitiesView: View {
    var body: some View {
        List {
            Section {
                ContentUnavailableView(
                    "Feed integration is planned",
                    systemImage: "shield.lefthalf.filled",
                    description: Text("This milestone does not fetch CISA KEV or NVD feeds. No vulnerability records or applicability claims are available yet.")
                )
                .listRowBackground(Color.clear)
            }
            Section("Later milestones") {
                Label("Source citations and fetched timestamps", systemImage: "link")
                Label("Validated records and offline cache", systemImage: "externaldrive")
                Label("Inventory correlation with explicit unknowns", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle("Vulnerabilities")
    }
}

@MainActor
struct AssetsView: View {
    var body: some View {
        List {
            Section {
                ContentUnavailableView(
                    "Inventory comes later",
                    systemImage: "server.rack",
                    description: Text("No assets have been imported or discovered. Future inventory onboarding will record your chosen products and versions.")
                )
                .listRowBackground(Color.clear)
            }
            Section("Action policy") {
                Text("Remote scanning, patching and deployment require explicit approval through reviewed integrations in a later milestone.")
                Text("Model output is untrusted guidance. Review authoritative sources before remediation.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Assets")
    }
}
