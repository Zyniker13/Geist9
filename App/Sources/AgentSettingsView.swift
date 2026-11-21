// Agent access settings (DESIGN 9A): the person's one place to decide what
// agents may see, copy the client configuration, and read what agents did.
// The policy file this pane writes is the only channel to the MCP helper —
// the app never opens the archive for an agent itself. Every control saves
// as it changes; the helper reads the file when a client connects.

import ArchiveCore
import AppKit
import SwiftUI

struct AgentSettingsView: View {
    @EnvironmentObject private var model: ArchiveModel
    @State private var access: AgentAccess
    @State private var saveError: String?
    @State private var copied = false
    @State private var logLines: [AgentAccess.LogLine]?

    init() {
        if let loaded = AgentAccess.load() {
            _access = State(initialValue: loaded)
        } else {
            var fresh = AgentAccess()
            // Agents are off until the person turns them on (DESIGN 9A);
            // the first open of this pane starts there, not enabled.
            fresh.policy.enabled = false
            _access = State(initialValue: fresh)
        }
    }

    var body: some View {
        Form {
            masterSwitch
            exposure
            limits
            clientConfiguration
            activity
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 560)
        .task { loadActivity() }
    }

    /// Every edit writes the policy file through this single binding; the
    /// helper picks the file up the next time a client connects.
    private var policy: Binding<AccessPolicy> {
        Binding(
            get: { access.policy },
            set: { access.policy = $0; persist() }
        )
    }

    private func persist() {
        do {
            try access.save()
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    // MARK: Master switch

    private var masterSwitch: some View {
        Section {
            Toggle("Allow agents to search this archive", isOn: policy.enabled)
            Text(
                access.policy.enabled
                    ? "Agents connect through the helper inside the app bundle and see only what these settings allow. A client that is already running picks up changes the next time it connects."
                    : "Agents are turned off: every request is refused, and the helper spends none of the rate limit answering them."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        } header: {
            Text("Agent access")
        } footer: {
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: Exposure

    private var exposure: some View {
        Section {
            Toggle("Hide Junk and Trash", isOn: policy.excludeJunkAndTrash)
            Picker("Redaction", selection: policy.redaction) {
                ForEach(AccessPolicy.Redaction.allCases, id: \.self) { mode in
                    switch mode {
                    case .none: Text("Full message text").tag(mode)
                    case .contactDetails: Text("Hide contact details").tag(mode)
                    case .headersOnly: Text("Headers only (no bodies)").tag(mode)
                    }
                }
            }
            if model.store == nil {
                Text("Open an archive to choose which accounts, folders and labels to hide.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                disclosure("Accounts", access.policy.excludedAccounts.count) {
                    exclusionList(
                        model.accounts.map { ($0.email, "\($0.displayName) (\($0.messageCount))") },
                        into: \.excludedAccounts
                    )
                }
                disclosure("Folders", access.policy.excludedMailboxes.count) {
                    exclusionList(
                        model.mailboxes.map { ($0.name, $0.name) },
                        into: \.excludedMailboxes
                    )
                }
                disclosure("Labels", access.policy.excludedLabels.count) {
                    exclusionList(
                        model.labels.map { ($0.name, "\($0.name) (\($0.messageCount))") },
                        into: \.excludedLabels
                    )
                }
            }
        } header: {
            Text("What agents may see")
        } footer: {
            Text("Hidden by name, so an exclusion stays matched when new mail arrives; hidden things look simply absent to agents.")
        }
    }

    private func disclosure<C: View>(
        _ title: String, _ hidden: Int, @ViewBuilder content: @escaping () -> C
    ) -> some View {
        DisclosureGroup("\(title) — \(hidden) hidden") { content() }
    }

    /// One toggle per name the archive currently exposes. The policy stores
    /// names (decision 0053), so hiding is a plain set membership.
    private func exclusionList(
        _ items: [(name: String, label: String)],
        into keyPath: WritableKeyPath<AccessPolicy, Set<String>>
    ) -> some View {
        ForEach(items, id: \.name) { item in
            Toggle(item.label, isOn: Binding(
                get: { access.policy[keyPath: keyPath].contains(item.name) },
                set: { on in
                    if on {
                        access.policy[keyPath: keyPath].insert(item.name)
                    } else {
                        access.policy[keyPath: keyPath].remove(item.name)
                    }
                    persist()
                }
            ))
        }
    }

    // MARK: Limits

    private var limits: some View {
        Section {
            Stepper(
                "Results per call: \(access.policy.maxResultsPerCall)",
                value: policy.maxResultsPerCall, in: 10...500, step: 10)
            Stepper(
                "Content per call: \(access.policy.maxCharsPerCall.formatted(.number.grouping(.never))) characters",
                value: policy.maxCharsPerCall, in: 1_000...1_000_000, step: 1_000)
            Stepper(
                "Calls per minute: \(access.policy.callsPerMinute)",
                value: policy.callsPerMinute, in: 1...600)
        } header: {
            Text("Limits")
        } footer: {
            Text("A client that exceeds the call limit is refused until the next minute; refusals cost it nothing.")
        }
    }

    // MARK: Client configuration

    private var snippet: String {
        guard let directory = model.store?.directory else { return "" }
        return access.clientConfiguration(archivePath: directory.path(percentEncoded: false)) ?? ""
    }

    private var clientConfiguration: some View {
        Section {
            TextEditor(text: .constant(snippet))
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 140)
                .accessibilityLabel("Client configuration")
            HStack {
                Button(copied ? "Copied" : "Copy configuration") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }
                .disabled(snippet.isEmpty)
                Spacer()
            }
        } header: {
            Text("Client configuration")
        } footer: {
            Text("Paste this into an MCP client's mcpServers configuration. The helper inside the app bundle opens the archive read-only with exactly these settings.")
        }
    }

    // MARK: Activity

    private var activity: some View {
        Section {
            if let logLines, !logLines.isEmpty {
                ForEach(logLines.prefix(50)) { line in
                    HStack {
                        Text(line.time.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(line.tool)
                        Text(line.query ?? "")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if let count = line.resultCount {
                            Text("\(count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .font(.callout)
                }
            } else {
                Text("No agent activity yet.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Activity")
                Spacer()
                if let logLines, !logLines.isEmpty {
                    Button("Clear") {
                        try? AgentAccess.clearActivity()
                        loadActivity()
                    }
                }
            }
        } footer: {
            Text("Every tool call and resource read an agent makes, newest first. The log records what was asked, not what was returned.")
        }
    }

    private func loadActivity() {
        logLines = AgentAccess.readActivity()
    }
}
