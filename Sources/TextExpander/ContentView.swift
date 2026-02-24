import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

struct ContentView: View {
    struct GroupSection: Identifiable {
        let name: String
        let indices: [Int]
        var id: String { name }
    }

    enum SettingsPanel: String, CaseIterable, Identifiable {
        case behavior = "Behavior"
        case data = "Data"
        case groups = "Groups"
        case permissions = "Permissions"
        case diagnostics = "Diagnostics"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .behavior:
                return "switch.2"
            case .data:
                return "tray.full"
            case .groups:
                return "folder"
            case .permissions:
                return "lock.shield"
            case .diagnostics:
                return "waveform.path.ecg"
            }
        }
    }

    enum FocusField: Hashable {
        case search
        case abbreviation
        case phrase
    }

    @ObservedObject var store: SnippetStore
    @ObservedObject var engine: TextExpansionEngine

    @State private var accessibilityTrusted = AccessibilityPermission.isTrusted(prompt: false)
    @State private var inputMonitoringGranted = InputMonitoringPermission.isGranted()
    @State private var secureInputEnabled = IsSecureEventInputEnabled()
    @State private var alertMessage: String?
    @State private var showSettings = false
    @State private var selectedSettingsPanel: SettingsPanel = .behavior
    @State private var collapsedGroups = Set<String>()
    @State private var selectedSnippetID: UUID?
    @State private var searchText = ""
    @State private var groupNameDrafts: [String: String] = [:]
    @FocusState private var focusedField: FocusField?

    private let permissionRefreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private let expansionSoundOptions = [
        "Tink",
        "Pop",
        "Ping",
        "Funk",
        "Glass",
        "Hero",
        "Morse",
        "Purr",
        "Sosumi",
        "Submarine",
        "Basso",
        "Blow",
        "Bottle",
        "Frog",
    ]

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
                .onTapGesture {
                    blurSearchFocusIfNeeded()
                }

            VStack(alignment: .leading, spacing: 12) {
                headerSection

                HSplitView {
                    sidebarSection
                        .frame(minWidth: 300, idealWidth: 360, maxWidth: 460)

                    detailSection
                        .frame(minWidth: 420)
                }
            }
            .padding(16)
            .frame(minWidth: 900, minHeight: 560)
        }
        .preferredColorScheme(.dark)
        .onReceive(permissionRefreshTimer) { _ in
            accessibilityTrusted = AccessibilityPermission.isTrusted(prompt: false)
            inputMonitoringGranted = InputMonitoringPermission.isGranted()
            secureInputEnabled = IsSecureEventInputEnabled()
        }
        .onAppear {
            syncGroupNameDrafts()
            ensureSelectionValid()
            ensureSelectionVisibleInSidebar()
        }
        .onChange(of: store.snippets) { _ in
            syncGroupNameDrafts()
            ensureSelectionValid()
            ensureSelectionVisibleInSidebar()
        }
        .onChange(of: searchText) { _ in
            ensureSelectionVisibleInSidebar()
        }
        .alert("Permissions", isPresented: Binding(
            get: { alertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    alertMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .sheet(isPresented: $showSettings) {
            settingsSheet
        }
    }

    private var headerSection: some View {
        HStack {
            Text("Snippets")
                .font(.title.bold())

            Spacer()

            Button {
                blurSearchFocusIfNeeded()
                createSnippet()
            } label: {
                Label("New Snippet", systemImage: "plus")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .foregroundStyle(.white)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.blue)
                    )
            }
            .buttonStyle(.plain)

            Button {
                blurSearchFocusIfNeeded()
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
        }
    }

    private var sidebarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search snippets", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .search)

                if hasActiveSearch {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(sidebarGroupSections) { section in
                        VStack(alignment: .leading, spacing: 2) {
                            groupHeader(section.name, isExpanded: isGroupExpanded(section.name)) {
                                blurSearchFocusIfNeeded()
                                toggleGroup(section.name)
                            }

                            if isGroupExpanded(section.name) {
                                ForEach(section.indices, id: \.self) { index in
                                    sidebarSnippetRow(index: index)
                                }
                            }
                        }
                    }

                    if sidebarGroupSections.isEmpty {
                        Text(hasActiveSearch ? "No snippets match your search." : "No snippets available.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }

                    Divider()
                        .padding(.top, 8)

                    Text("Total snippets: \(store.snippets.count)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 1)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var detailSection: some View {
        if let index = selectedSnippetIndex, index < store.snippets.count {
            VStack(alignment: .leading, spacing: 12) {
                Text("Abbreviation")
                    .font(.headline)

                TextField("abbreviation", text: $store.snippets[index].abbreviation)
                    .textFieldStyle(.roundedBorder)
                    .font(.title2.weight(.semibold))
                    .focused($focusedField, equals: .abbreviation)
                    .onSubmit {
                        focusedField = .phrase
                    }

                Text("Text")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Use {{name}} for slots. You'll be prompted when this snippet expands.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("Insert {{}}") {
                        insertAnonymousSlot()
                    }
                    .buttonStyle(.borderedProminent)
                }
                TextEditor(text: $store.snippets[index].phrase)
                    .font(.title3.weight(.semibold))
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focused($focusedField, equals: .phrase)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )

                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        blurSearchFocusIfNeeded()
                        deleteSelectedSnippet()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 12)
        } else {
            VStack(spacing: 12) {
                Text("No snippet selected")
                    .font(.title3.bold())
                Text("Select a snippet from the sidebar or create a new one.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func groupHeader(_ name: String, isExpanded: Bool, onToggle: @escaping () -> Void) -> some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.20))
        )
    }

    @ViewBuilder
    private func sidebarSnippetRow(index: Int) -> some View {
        if index < store.snippets.count {
            let snippet = store.snippets[index]
            let isSelected = selectedSnippetID == snippet.id

            Button {
                blurSearchFocusIfNeeded()
                selectedSnippetID = snippet.id
            } label: {
                HStack(spacing: 6) {
                    Text(snippetPreviewText(snippet.phrase))
                        .font(.callout)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(snippet.abbreviation)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.2))
                        )
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(isSelected ? Color.accentColor.opacity(0.35) : Color.clear)
            .cornerRadius(6)
        }
    }

    private var settingsSheet: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Text("Settings")
                        .font(.title2.bold())
                    Spacer()
                    Button("Done") {
                        showSettings = false
                    }
                }
                .padding(16)

                Divider()

                HSplitView {
                    settingsMenuSidebar
                        .frame(minWidth: 180, idealWidth: 220, maxWidth: 250)

                    settingsDetailPane
                        .frame(minWidth: 520)
                }
            }
            .frame(minWidth: 860, minHeight: 560)
        }
        .preferredColorScheme(.dark)
    }

    private var settingsMenuSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(SettingsPanel.allCases) { panel in
                Button {
                    selectedSettingsPanel = panel
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: panel.systemImage)
                            .frame(width: 16)
                        Text(panel.rawValue)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(selectedSettingsPanel == panel ? Color.accentColor.opacity(0.25) : Color.clear)
                    .cornerRadius(7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.black)
    }

    private var settingsDetailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch selectedSettingsPanel {
                case .behavior:
                    settingsBehaviorPanel
                case .data:
                    settingsDataPanel
                case .groups:
                    settingsGroupsPanel
                case .permissions:
                    settingsPermissionsPanel
                case .diagnostics:
                    settingsDiagnosticsPanel
                }
            }
            .padding(16)
        }
    }

    private var settingsBehaviorPanel: some View {
        settingsCard(title: "Behavior", subtitle: "Core expansion options.") {
            Toggle("Enable expansions", isOn: $store.isEnabled)
            Toggle("Use paste mode (better app compatibility)", isOn: $store.usePasteMode)

            Picker("Expansion trigger", selection: $store.expansionTriggerMode) {
                Text("Delimiter only").tag(ExpansionTriggerMode.delimiterOnly)
                Text("Instant").tag(ExpansionTriggerMode.instant)
            }
            .pickerStyle(.segmented)

            Toggle("Play sound on expansion", isOn: $store.playSoundOnExpand)
            if store.playSoundOnExpand {
                Picker("Expansion sound", selection: $store.expansionSoundName) {
                    ForEach(expansionSoundOptionsWithCurrentSelection, id: \.self) { soundName in
                        Text(soundName).tag(soundName)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 280, alignment: .leading)
            }
        }
    }

    private var settingsDataPanel: some View {
        settingsCard(title: "Data", subtitle: "Import or export your snippets.") {
            HStack(spacing: 10) {
                Button("Import JSON") {
                    importFromJSON()
                }
                Button("Export JSON") {
                    exportToJSON()
                }
            }
        }
    }

    private var settingsGroupsPanel: some View {
        settingsCard(title: "Groups", subtitle: "Rename and reorder how groups appear in the sidebar.") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(groupSections, id: \.name) { section in
                    HStack(spacing: 8) {
                        TextField("Group name", text: Binding(
                            get: { groupNameDraft(for: section.name) },
                            set: { groupNameDrafts[section.name] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            commitGroupRename(from: section.name)
                        }

                        Button("Rename") {
                            commitGroupRename(from: section.name)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canRenameGroup(section.name))

                        Spacer()
                        Button {
                            store.moveGroup(named: section.name, direction: -1)
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canMoveGroup(section.name, direction: -1))

                        Button {
                            store.moveGroup(named: section.name, direction: 1)
                        } label: {
                            Image(systemName: "arrow.down")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canMoveGroup(section.name, direction: 1))
                    }
                }
            }
        }
    }

    private var settingsPermissionsPanel: some View {
        settingsCard(title: "Permissions", subtitle: "Grant permissions required for system-wide expansion.") {
            Text(accessibilityTrusted ? "Accessibility permission is enabled." : "Accessibility permission is missing.")
                .foregroundStyle(accessibilityTrusted ? .green : .red)
            Text(inputMonitoringGranted ? "Input Monitoring permission is enabled." : "Input Monitoring permission is not confirmed yet (can still work on some macOS setups).")
                .foregroundStyle(inputMonitoringGranted ? .green : .red)

            HStack(spacing: 10) {
                Button("Request Accessibility Permission") {
                    _ = AccessibilityPermission.isTrusted(prompt: true)
                    accessibilityTrusted = AccessibilityPermission.isTrusted(prompt: false)
                }
                Button("Request Input Monitoring Permission") {
                    _ = InputMonitoringPermission.request()
                    inputMonitoringGranted = InputMonitoringPermission.isGranted()
                    if !inputMonitoringGranted {
                        alertMessage = "macOS did not auto-grant Input Monitoring. In Input Monitoring, click + and add ~/Applications/Expander.app, then fully quit and reopen Expander."
                    }
                }
                Button("Open Privacy Settings") {
                    openInputMonitoringSettings()
                }
            }
        }
    }

    private var settingsDiagnosticsPanel: some View {
        settingsCard(title: "Diagnostics", subtitle: "Current runtime status.") {
            Text("Front app: \(engine.lastFrontmostApp)")
                .font(.callout)
            Text("Trigger mode: \(store.expansionTriggerMode == .delimiterOnly ? "Delimiter only" : "Instant")")
                .font(.callout)
            Text("Key events seen: \(engine.keyEventsSeen)")
                .font(.callout)
            Text("Expansions attempted: \(engine.expansionsAttempted)")
                .font(.callout)
            Text("Last match: \(engine.lastMatchedAbbreviation.isEmpty ? "none" : engine.lastMatchedAbbreviation)")
                .font(.callout)
            Text("Last decision: \(engine.lastDecision)")
                .font(.callout)
            Text("Secure Input active: \(secureInputEnabled ? "Yes" : "No")")
                .font(.callout)
                .foregroundStyle(secureInputEnabled ? .red : .secondary)

            Button("Copy diagnostics") {
                copyDiagnosticsToClipboard()
            }
            .buttonStyle(.bordered)

            if engine.recentDiagnostics.isEmpty {
                Text("No diagnostic events yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(engine.recentDiagnostics.suffix(25).reversed())) { event in
                            Text(formattedDiagnosticEvent(event))
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 220)
            }
        }
    }

    private func settingsCard<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.bold())
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
        )
    }

    private var groupSections: [GroupSection] {
        var order: [String] = []
        var grouped: [String: [Int]] = [:]

        for (index, snippet) in store.snippets.enumerated() {
            let group = Snippet.normalizedGroupName(snippet.group)
            if grouped[group] == nil {
                order.append(group)
            }
            grouped[group, default: []].append(index)
        }

        return order.map { GroupSection(name: $0, indices: grouped[$0] ?? []) }
    }

    private var sidebarGroupSections: [GroupSection] {
        var order: [String] = []
        var grouped: [String: [Int]] = [:]

        for (index, snippet) in store.snippets.enumerated() where snippetMatchesSearch(snippet) {
            let group = Snippet.normalizedGroupName(snippet.group)
            if grouped[group] == nil {
                order.append(group)
            }
            grouped[group, default: []].append(index)
        }

        return order.map { GroupSection(name: $0, indices: grouped[$0] ?? []) }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasActiveSearch: Bool {
        !normalizedSearchText.isEmpty
    }

    private var selectedSnippetIndex: Int? {
        guard let selectedSnippetID else {
            return nil
        }
        return store.snippets.firstIndex(where: { $0.id == selectedSnippetID })
    }

    private func isGroupExpanded(_ group: String) -> Bool {
        hasActiveSearch || !collapsedGroups.contains(group)
    }

    private func toggleGroup(_ group: String) {
        if collapsedGroups.contains(group) {
            collapsedGroups.remove(group)
        } else {
            collapsedGroups.insert(group)
        }
    }

    private func createSnippet() {
        let defaultGroup = selectedSnippetIndex.map { store.snippets[$0].group } ?? groupSections.first?.name ?? Snippet.defaultGroup
        selectedSnippetID = store.createSnippet(inGroup: defaultGroup)
        ensureSelectionVisibleInSidebar()
        focusedField = .abbreviation
    }

    private func deleteSelectedSnippet() {
        guard let index = selectedSnippetIndex, index < store.snippets.count else {
            return
        }

        let removedID = store.snippets[index].id
        let group = store.snippets[index].group
        store.removeSnippet(id: removedID)

        if let nextInSameGroup = store.snippets.first(where: { $0.group.caseInsensitiveCompare(group) == .orderedSame }) {
            selectedSnippetID = nextInSameGroup.id
        } else {
            ensureSelectionValid()
        }

        ensureSelectionVisibleInSidebar()
    }

    private func insertAnonymousSlot() {
        appendSlotToken("{{}}", cursorOffsetFromEnd: 2)
    }

    private func appendSlotToken(_ token: String, cursorOffsetFromEnd: Int = 0) {
        guard let index = selectedSnippetIndex, index < store.snippets.count else {
            return
        }

        let phrase = store.snippets[index].phrase
        let currentLength = (phrase as NSString).length
        let needsLeadingSpace = !(phrase.isEmpty || phrase.last?.isWhitespace == true)
        let slotText = needsLeadingSpace ? " \(token)" : token
        let insertedLength = (slotText as NSString).length

        store.snippets[index].phrase += slotText

        let cursorLocation = max(0, currentLength + insertedLength - cursorOffsetFromEnd)
        focusPhraseEditor(atUTF16Location: cursorLocation)
    }

    private func focusPhraseEditor(atUTF16Location location: Int) {
        focusedField = .phrase

        DispatchQueue.main.async {
            guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else {
                return
            }

            let maxLocation = (textView.string as NSString).length
            let safeLocation = min(max(0, location), maxLocation)
            let targetRange = NSRange(location: safeLocation, length: 0)
            textView.setSelectedRange(targetRange)
            textView.scrollRangeToVisible(targetRange)
        }
    }
    private func ensureSelectionValid() {
        guard !store.snippets.isEmpty else {
            selectedSnippetID = nil
            return
        }

        if let selectedSnippetID,
           store.snippets.contains(where: { $0.id == selectedSnippetID }) {
            return
        }

        selectedSnippetID = store.snippets.first?.id
    }

    private func ensureSelectionVisibleInSidebar() {
        let visibleIndices = sidebarGroupSections.flatMap(\.indices)

        guard !visibleIndices.isEmpty else {
            if hasActiveSearch {
                selectedSnippetID = nil
            }
            return
        }

        if let selectedSnippetID,
           visibleIndices.contains(where: { index in
               index < store.snippets.count && store.snippets[index].id == selectedSnippetID
           }) {
            return
        }

        if let firstVisibleIndex = visibleIndices.first, firstVisibleIndex < store.snippets.count {
            selectedSnippetID = store.snippets[firstVisibleIndex].id
        }
    }

    private func snippetMatchesSearch(_ snippet: Snippet) -> Bool {
        guard hasActiveSearch else {
            return true
        }

        let normalizedQuery = normalizedSearchText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let searchableFields = [snippet.abbreviation, snippet.phrase, snippet.group]

        return searchableFields.contains { field in
            field
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .contains(normalizedQuery)
        }
    }

    private func snippetPreviewText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "(empty)"
        }

        if let firstLine = trimmed.split(separator: "\n", omittingEmptySubsequences: false).first {
            return String(firstLine)
        }
        return trimmed
    }

    private func canMoveGroup(_ group: String, direction: Int) -> Bool {
        guard direction == -1 || direction == 1 else {
            return false
        }
        let names = groupSections.map(\.name)
        guard let index = names.firstIndex(of: group) else {
            return false
        }
        let destination = index + direction
        return destination >= 0 && destination < names.count
    }

    private func groupNameDraft(for group: String) -> String {
        groupNameDrafts[group] ?? group
    }

    private func canRenameGroup(_ group: String) -> Bool {
        let proposed = groupNameDraft(for: group).trimmingCharacters(in: .whitespacesAndNewlines)
        return !proposed.isEmpty && proposed != group
    }

    private func commitGroupRename(from group: String) {
        let proposedName = groupNameDraft(for: group).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !proposedName.isEmpty else {
            groupNameDrafts[group] = group
            return
        }

        guard proposedName != group else {
            return
        }

        store.renameGroup(named: group, to: proposedName)
        renameCollapsedGroupIfNeeded(from: group, to: proposedName)
    }

    private func renameCollapsedGroupIfNeeded(from oldGroup: String, to newGroup: String) {
        let hadCollapsedGroup = collapsedGroups.contains { existingGroup in
            existingGroup.caseInsensitiveCompare(oldGroup) == .orderedSame
        }

        guard hadCollapsedGroup else {
            return
        }

        collapsedGroups = Set(collapsedGroups.filter { existingGroup in
            existingGroup.caseInsensitiveCompare(oldGroup) != .orderedSame
        })
        collapsedGroups.insert(Snippet.normalizedGroupName(newGroup))
    }

    private func syncGroupNameDrafts() {
        let currentGroups = Set(groupSections.map(\.name))
        groupNameDrafts = groupNameDrafts.filter { currentGroups.contains($0.key) }

        for group in currentGroups where groupNameDrafts[group] == nil {
            groupNameDrafts[group] = group
        }
    }

    private var expansionSoundOptionsWithCurrentSelection: [String] {
        if expansionSoundOptions.contains(store.expansionSoundName) {
            return expansionSoundOptions
        }
        return [store.expansionSoundName] + expansionSoundOptions
    }
    private func copyDiagnosticsToClipboard() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let lines = engine.recentDiagnostics.reversed().map { event in
            let timestamp = formatter.string(from: event.timestamp)
            let abbreviation = event.matchedAbbreviation ?? "-"
            return "[\(timestamp)] app=\(event.appBundleID) mode=\(event.triggerMode.rawValue) typed=\(event.typedCharacter) match=\(abbreviation) action=\(event.action) result=\(event.result) candidate=\(event.candidateText)"
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func formattedDiagnosticEvent(_ event: TextExpansionEngine.DiagnosticEvent) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = timeFormatter.string(from: event.timestamp)
        let abbreviation = event.matchedAbbreviation ?? "-"
        return "\(timestamp) [\(event.triggerMode.rawValue)] typed='\(event.typedCharacter)' match='\(abbreviation)' action='\(event.action)' result='\(event.result)'"
    }

    private func exportToJSON() {
        let panel = NSSavePanel()
        panel.title = "Export Snippets"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "expander-snippets.json"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try store.exportSnippets(to: url)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func importFromJSON() {
        let panel = NSOpenPanel()
        panel.title = "Import Snippets"
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try store.importSnippets(from: url)
            ensureSelectionValid()
            ensureSelectionVisibleInSidebar()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func openInputMonitoringSettings() {
        let candidateURLs = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security",
        ]

        for candidate in candidateURLs {
            guard let url = URL(string: candidate) else {
                continue
            }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func blurSearchFocusIfNeeded() {
        if focusedField == .search {
            focusedField = nil
        }
    }
}
