import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import CoreGraphics
import Foundation
import IOKit.hidsystem

enum AccessibilityPermission {
    private static let promptOptionKey = "AXTrustedCheckOptionPrompt"

    static func isTrusted(prompt: Bool) -> Bool {
        if prompt {
            let options = [promptOptionKey: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }
}

enum InputMonitoringPermission {
    private static func hidAccessGranted(_ type: IOHIDRequestType) -> Bool {
        if #available(macOS 10.15, *) {
            return IOHIDCheckAccess(type) == kIOHIDAccessTypeGranted
        }
        return true
    }

    static func isGranted() -> Bool {
        if #available(macOS 10.15, *) {
            let listenGranted = hidAccessGranted(kIOHIDRequestTypeListenEvent)
            let postGranted = hidAccessGranted(kIOHIDRequestTypePostEvent)
            return listenGranted && postGranted && CGPreflightListenEventAccess()
        }
        return true
    }

    @discardableResult
    static func request() -> Bool {
        if #available(macOS 10.15, *) {
            let listenGranted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            let postGranted = IOHIDRequestAccess(kIOHIDRequestTypePostEvent)
            let cgGranted = CGRequestListenEventAccess()
            return listenGranted && postGranted && cgGranted
        }
        return true
    }
}

enum ExpansionLogic {
    static func shouldAttemptExpansion(mode: ExpansionTriggerMode, typedCharacter: Character) -> Bool {
        switch mode {
        case .delimiterOnly:
            return isDelimiter(typedCharacter)
        case .instant:
            return true
        }
    }

    static func bestAbbreviationMatch(in prefix: String, snippetMap: [String: String]) -> (abbreviation: String, phrase: String)? {
        var bestMatch: (abbreviation: String, phrase: String)?

        for (abbreviation, phrase) in snippetMap {
            guard prefix.hasSuffix(abbreviation) else {
                continue
            }

            guard hasValidBoundaryBeforeMatch(prefix: prefix, abbreviation: abbreviation) else {
                continue
            }

            if let current = bestMatch {
                if abbreviation.count > current.abbreviation.count {
                    bestMatch = (abbreviation, phrase)
                }
            } else {
                bestMatch = (abbreviation, phrase)
            }
        }

        return bestMatch
    }

    static func isDelimiter(_ character: Character) -> Bool {
        for scalar in String(character).unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                return false
            }
        }
        return true
    }

    private static func hasValidBoundaryBeforeMatch(prefix: String, abbreviation: String) -> Bool {
        guard shouldRequireBoundary(for: abbreviation) else {
            return true
        }

        guard prefix.count >= abbreviation.count else {
            return false
        }

        let matchStart = prefix.index(prefix.endIndex, offsetBy: -abbreviation.count)
        guard matchStart > prefix.startIndex else {
            return true
        }

        let previousIndex = prefix.index(before: matchStart)
        let previousCharacter = prefix[previousIndex]
        let scalars = String(previousCharacter).unicodeScalars
        return scalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static func shouldRequireBoundary(for abbreviation: String) -> Bool {
        guard let firstScalar = abbreviation.unicodeScalars.first else {
            return false
        }
        return CharacterSet.alphanumerics.contains(firstScalar) || firstScalar == "_"
    }
}

enum SlotTemplateLogic {
    struct SlotField: Equatable {
        let key: String
        let label: String
    }

    private struct SlotToken {
        let range: NSRange
        let key: String
        let label: String
    }

    private static let slotExpression: NSRegularExpression = {
        guard let expression = try? NSRegularExpression(pattern: #"\{\{\s*([^{}]*?)\s*\}\}"#) else {
            fatalError("Invalid slot regex")
        }
        return expression
    }()

    static func slotFields(in template: String) -> [SlotField] {
        var fields: [SlotField] = []
        var seenKeys = Set<String>()

        for token in tokens(in: template) {
            if seenKeys.insert(token.key).inserted {
                fields.append(SlotField(key: token.key, label: token.label))
            }
        }

        return fields
    }

    static func applySlotValues(_ values: [String: String], to template: String) -> String {
        let tokenList = tokens(in: template)
        guard !tokenList.isEmpty else {
            return template
        }

        var output = template
        for token in tokenList.reversed() {
            guard let range = Range(token.range, in: output), let replacement = values[token.key] else {
                continue
            }
            output.replaceSubrange(range, with: replacement)
        }
        return output
    }

    private static func tokens(in template: String) -> [SlotToken] {
        let matches = slotExpression.matches(in: template, range: NSRange(template.startIndex..., in: template))
        var anonymousIndex = 0

        return matches.compactMap { match in
            let rawLabel: String
            if let labelRange = Range(match.range(at: 1), in: template) {
                rawLabel = String(template[labelRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                rawLabel = ""
            }

            if rawLabel.isEmpty {
                anonymousIndex += 1
                return SlotToken(
                    range: match.range,
                    key: "__slot_\(anonymousIndex)",
                    label: "Slot \(anonymousIndex)"
                )
            }

            return SlotToken(range: match.range, key: rawLabel, label: rawLabel)
        }
    }
}


@MainActor
private final class SlotPromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class SlotPromptPanelController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private let template: String
    private let slotFields: [SlotTemplateLogic.SlotField]
    private let panel: SlotPromptPanel
    private let previewField: NSTextField
    private var inputFieldsByKey: [String: NSTextField] = [:]
    private var orderedInputFields: [NSTextField] = []
    private weak var firstInputField: NSTextField?
    private weak var insertButton: NSButton?
    private weak var cancelButton: NSButton?
    private var submittedValues: [String: String]?

    init(template: String, slotFields: [SlotTemplateLogic.SlotField], abbreviation: String) {
        self.template = template
        self.slotFields = slotFields
        self.previewField = NSTextField(wrappingLabelWithString: "")
        self.panel = SlotPromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.autorecalculatesKeyViewLoop = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .transient]
        panel.title = "Fill Snippet Slots"
        panel.delegate = self
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "Fill Snippet Slots")
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .semibold)

        let subtitleLabel = NSTextField(labelWithString: "Complete the values for \"\(abbreviation)\".")
        subtitleLabel.font = NSFont.systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor

        let previewTitle = NSTextField(labelWithString: "Snippet preview")
        previewTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)

        previewField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        previewField.lineBreakMode = .byWordWrapping
        previewField.maximumNumberOfLines = 5

        let previewContainer = NSView()
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.wantsLayer = true
        previewContainer.layer?.cornerRadius = 6
        previewContainer.layer?.borderWidth = 1
        previewContainer.layer?.borderColor = NSColor.separatorColor.cgColor

        previewField.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(previewField)
        NSLayoutConstraint.activate([
            previewField.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 10),
            previewField.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -10),
            previewField.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 8),
            previewField.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -8),
        ])

        let topSeparator = NSBox()
        topSeparator.boxType = .separator

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.addArrangedSubview(topSeparator)
        stack.addArrangedSubview(previewTitle)
        stack.addArrangedSubview(previewContainer)

        for slot in slotFields {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false

            let label = NSTextField(labelWithString: "\(slot.label):")
            label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

            let input = NSTextField(string: "")
            input.placeholderString = "Type value"
            input.delegate = self
            input.font = NSFont.systemFont(ofSize: 13)
            input.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
            input.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            if firstInputField == nil {
                firstInputField = input
            }
            inputFieldsByKey[slot.key] = input
            orderedInputFields.append(input)

            row.addArrangedSubview(label)
            row.addArrangedSubview(input)
            stack.addArrangedSubview(row)
        }

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        self.cancelButton = cancelButton
        cancelButton.keyEquivalent = "\u{1b}"

        let insertButton = NSButton(title: "Insert", target: self, action: #selector(insertPressed))
        self.insertButton = insertButton
        insertButton.keyEquivalent = "\r"
        insertButton.bezelStyle = .rounded

        buttonRow.addArrangedSubview(spacer)
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(insertButton)

        panel.defaultButtonCell = insertButton.cell as? NSButtonCell

        configureKeyViewLoop(insertButton: insertButton, cancelButton: cancelButton)

        let bottomSeparator = NSBox()
        bottomSeparator.boxType = .separator

        stack.addArrangedSubview(bottomSeparator)
        stack.addArrangedSubview(buttonRow)

        contentView.addSubview(stack)
        panel.contentView = contentView

        NSLayoutConstraint.activate([
            contentView.widthAnchor.constraint(equalToConstant: 680),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            previewContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 620),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        if let firstInputField {
            panel.initialFirstResponder = firstInputField
        }

        refreshPreview()
    }

    func runModal() -> [String: String]? {
        NSApp.activate(ignoringOtherApps: true)
        hideNonPanelWindows()

        panel.center()
        panel.orderFrontRegardless()
        panel.makeMain()
        panel.makeKeyAndOrderFront(nil)
        focusFirstInputField()

        DispatchQueue.main.async { [weak self] in
            self?.focusFirstInputField()
            self?.hideNonPanelWindows()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.focusFirstInputField()
            self?.hideNonPanelWindows()
        }

        _ = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return submittedValues
    }

    func windowDidBecomeKey(_ notification: Notification) {
        focusFirstInputField()
        hideNonPanelWindows()
    }

    func controlTextDidChange(_ notification: Notification) {
        refreshPreview()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
            commandSelector == #selector(NSResponder.insertLineBreak(_:)) {
            insertPressed()
            return true
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelPressed()
            return true
        }

        return false
    }

    func windowWillClose(_ notification: Notification) {
        if NSApp.modalWindow === panel {
            submittedValues = nil
            NSApp.stopModal()
        }
    }

    @objc
    private func insertPressed() {
        submittedValues = collectedValuesByKey()
        NSApp.stopModal()
        panel.orderOut(nil)
    }

    @objc
    private func cancelPressed() {
        submittedValues = nil
        NSApp.stopModal()
        panel.orderOut(nil)
    }

    private func configureKeyViewLoop(insertButton: NSButton, cancelButton: NSButton) {
        guard !orderedInputFields.isEmpty else {
            return
        }

        for index in orderedInputFields.indices {
            let nextView: NSView
            if index + 1 < orderedInputFields.count {
                nextView = orderedInputFields[index + 1]
            } else {
                nextView = insertButton
            }
            orderedInputFields[index].nextKeyView = nextView
        }

        insertButton.nextKeyView = cancelButton
        cancelButton.nextKeyView = orderedInputFields[0]
    }

    private func focusFirstInputField() {
        guard let firstInputField else {
            return
        }

        let focused = panel.makeFirstResponder(firstInputField)
        if focused {
            firstInputField.selectText(nil)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, let input = self.firstInputField else {
                    return
                }
                _ = self.panel.makeFirstResponder(input)
                input.selectText(nil)
            }
        }
    }

    private func hideNonPanelWindows() {
        for window in NSApp.windows where window != panel {
            if window.isVisible {
                window.orderOut(nil)
            }
        }
    }

    private func collectedValuesByKey() -> [String: String] {
        var values: [String: String] = [:]
        for slot in slotFields {
            values[slot.key] = inputFieldsByKey[slot.key]?.stringValue ?? ""
        }
        return values
    }

    private func refreshPreview() {
        var previewValues: [String: String] = [:]
        for slot in slotFields {
            let value = inputFieldsByKey[slot.key]?.stringValue ?? ""
            previewValues[slot.key] = value.isEmpty ? "____" : value
        }
        previewField.stringValue = SlotTemplateLogic.applySlotValues(previewValues, to: template)
    }
}
@MainActor
final class TextExpansionEngine: ObservableObject {
    struct DiagnosticEvent: Identifiable {
        let id = UUID()
        let timestamp: Date
        let appBundleID: String
        let appDescription: String
        let triggerMode: ExpansionTriggerMode
        let typedCharacter: String
        let candidateText: String
        let matchedAbbreviation: String?
        let action: String
        let result: String
    }

    private let backspaceKeyCode: CGKeyCode = 51
    private let vKeyCode: CGKeyCode = 9
    private let maxBufferLength = 120
    private let injectionDelay: TimeInterval = 0.02
    private let maxDiagnosticEvents = 200

    @Published private(set) var keyEventsSeen: Int = 0
    @Published private(set) var expansionsAttempted: Int = 0
    @Published private(set) var lastMatchedAbbreviation: String = ""
    @Published private(set) var lastFrontmostApp: String = "Unknown"
    @Published private(set) var lastDecision: String = "Idle"
    @Published private(set) var recentDiagnostics: [DiagnosticEvent] = []

    private var monitor: Any?
    private var snippetMap: [String: String] = [:]
    private var typedBuffer = ""
    private var isEnabled = true
    private var usePasteMode = true
    private var playSoundOnExpand = true
    private var expansionSoundName = SnippetStore.defaultExpansionSoundName
    private var expansionTriggerMode: ExpansionTriggerMode = .delimiterOnly
    private var isInjecting = false
    private var lastFrontmostBundleID = "no-bundle-id"
    private var cancellables = Set<AnyCancellable>()

    init(store: SnippetStore) {
        updateSnippetMap(with: store.snippets)
        isEnabled = store.isEnabled
        usePasteMode = store.usePasteMode
        playSoundOnExpand = store.playSoundOnExpand
        expansionSoundName = store.expansionSoundName
        expansionTriggerMode = store.expansionTriggerMode

        store.$snippets
            .sink { [weak self] snippets in
                self?.updateSnippetMap(with: snippets)
            }
            .store(in: &cancellables)

        store.$isEnabled
            .sink { [weak self] enabled in
                self?.isEnabled = enabled
                if !enabled {
                    self?.typedBuffer.removeAll()
                }

            }
            .store(in: &cancellables)

        store.$usePasteMode
            .sink { [weak self] usePasteMode in
                self?.usePasteMode = usePasteMode
            }
            .store(in: &cancellables)

        store.$playSoundOnExpand
            .sink { [weak self] enabled in
                self?.playSoundOnExpand = enabled
            }
            .store(in: &cancellables)

        store.$expansionSoundName
            .sink { [weak self] soundName in
                self?.expansionSoundName = soundName
            }
            .store(in: &cancellables)

        store.$expansionTriggerMode
            .sink { [weak self] triggerMode in
                self?.expansionTriggerMode = triggerMode
            }
            .store(in: &cancellables)

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event: event)
        }
    }

    private func updateSnippetMap(with snippets: [Snippet]) {
        var map: [String: String] = [:]
        for snippet in snippets {
            let abbreviation = snippet.abbreviation.trimmingCharacters(in: .whitespacesAndNewlines)
            let phrase = snippet.phrase.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !abbreviation.isEmpty, !phrase.isEmpty else {
                continue
            }

            map[abbreviation] = phrase
        }
        snippetMap = map
    }

    private func handle(event: NSEvent) {
        guard isEnabled, !isInjecting else {
            return
        }

        keyEventsSeen += 1
        let appInfo = Self.frontmostAppInfo()
        lastFrontmostApp = appInfo.description
        lastFrontmostBundleID = appInfo.bundleID

        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false {
            appendDiagnostic(
                typedCharacter: event.characters,
                action: "key-captured",
                result: "ignored-modifier"
            )
            return
        }

        if event.keyCode == backspaceKeyCode {
            if !typedBuffer.isEmpty {
                typedBuffer.removeLast()
            }
            appendDiagnostic(
                typedCharacter: "\\u{8}",
                candidateText: typedBuffer,
                action: "key-captured",
                result: "backspace"
            )
            return
        }

        guard let characters = event.characters, !characters.isEmpty else {
            return
        }

        for character in characters {
            if isSystemCharacter(character) {
                typedBuffer.removeAll()
                appendDiagnostic(
                    typedCharacter: String(character),
                    action: "key-captured",
                    result: "system-character-reset-buffer"
                )
                continue
            }

            typedBuffer.append(character)
            trimBuffer()

            appendDiagnostic(
                typedCharacter: String(character),
                candidateText: typedBuffer,
                action: "key-captured",
                result: "buffer-updated"
            )

            guard ExpansionLogic.shouldAttemptExpansion(mode: expansionTriggerMode, typedCharacter: character) else {
                appendDiagnostic(
                    typedCharacter: String(character),
                    candidateText: typedBuffer,
                    action: "candidate-evaluated",
                    result: "waiting-for-delimiter"
                )
                continue
            }

            let trigger: Character? = ExpansionLogic.isDelimiter(character) ? character : nil
            tryExpand(trigger: trigger, typedCharacter: character)
        }
    }

    private func trimBuffer() {
        guard typedBuffer.count > maxBufferLength else {
            return
        }
        typedBuffer = String(typedBuffer.suffix(maxBufferLength))
    }

    private func tryExpand(trigger: Character?, typedCharacter: Character) {
        guard typedBuffer.count >= 2 else {
            appendDiagnostic(
                typedCharacter: String(typedCharacter),
                candidateText: typedBuffer,
                action: "candidate-evaluated",
                result: "buffer-too-short"
            )
            return
        }

        let candidateText: String
        if trigger == nil {
            candidateText = typedBuffer
        } else {
            candidateText = String(typedBuffer.dropLast())
        }

        appendDiagnostic(
            typedCharacter: String(typedCharacter),
            candidateText: candidateText,
            action: "candidate-evaluated",
            result: "searching-match"
        )

        guard let match = ExpansionLogic.bestAbbreviationMatch(in: candidateText, snippetMap: snippetMap) else {
            if trigger != nil {
                lastDecision = "No abbreviation matched before delimiter"
            }
            appendDiagnostic(
                typedCharacter: String(typedCharacter),
                candidateText: candidateText,
                action: "match-result",
                result: "no-match"
            )
            return
        }

        expansionsAttempted += 1
        lastMatchedAbbreviation = match.abbreviation

        guard AccessibilityPermission.isTrusted(prompt: false) else {
            lastDecision = "Blocked: Accessibility is not trusted"
            appendDiagnostic(
                typedCharacter: String(typedCharacter),
                candidateText: candidateText,
                matchedAbbreviation: match.abbreviation,
                action: "match-result",
                result: "blocked-accessibility"
            )
            return
        }

        let targetApp = NSWorkspace.shared.frontmostApplication
        isInjecting = true

        guard let resolvedPhrase = resolvePhraseWithSlotsIfNeeded(
            match.phrase,
            abbreviation: match.abbreviation,
            candidateText: candidateText,
            typedCharacter: typedCharacter,
            targetApp: targetApp
        ) else {
            isInjecting = false
            return
        }

        let replacement = resolvedPhrase + (trigger.map(String.init) ?? "")
        let deletedCount = match.abbreviation.count + (trigger == nil ? 0 : 1)

        lastDecision = "Queued replacement for '\(match.abbreviation)' in \(lastFrontmostApp)"
        appendDiagnostic(
            typedCharacter: String(typedCharacter),
            candidateText: candidateText,
            matchedAbbreviation: match.abbreviation,
            action: "replacement-queued",
            result: "delete=\(deletedCount), mode=\(usePasteMode ? "paste" : "unicode")"
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + injectionDelay) { [weak self] in
            self?.performReplacement(deleting: deletedCount, replacement: replacement, abbreviation: match.abbreviation)
        }
    }

    private func performReplacement(deleting charactersToDelete: Int, replacement: String, abbreviation: String) {
        for _ in 0..<charactersToDelete {
            postKeyEvent(keyCode: backspaceKeyCode)
        }

        appendDiagnostic(
            candidateText: replacement,
            matchedAbbreviation: abbreviation,
            action: "replacement-delete",
            result: "posted-\(charactersToDelete)-backspace-events"
        )

        if usePasteMode {
            lastDecision = "Posted replacement for '\(abbreviation)' in \(lastFrontmostApp) (paste mode)"
            pasteTextWithClipboardRestore(replacement, abbreviation: abbreviation)
        } else {
            postText(replacement)
            appendDiagnostic(
                candidateText: replacement,
                matchedAbbreviation: abbreviation,
                action: "replacement-insert",
                result: "posted-unicode-events"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.isInjecting = false
                self?.appendDiagnostic(
                    candidateText: replacement,
                    matchedAbbreviation: abbreviation,
                    action: "replacement-complete",
                    result: "unicode-finished"
                )
            }
            lastDecision = "Posted replacement for '\(abbreviation)' in \(lastFrontmostApp)"
        }

        playExpansionSound()
        typedBuffer.removeAll()
    }

    private func resolvePhraseWithSlotsIfNeeded(
        _ phrase: String,
        abbreviation: String,
        candidateText: String,
        typedCharacter: Character,
        targetApp: NSRunningApplication?
    ) -> String? {
        let slotFields = SlotTemplateLogic.slotFields(in: phrase)
        guard !slotFields.isEmpty else {
            return phrase
        }

        defer {
            if let targetApp,
               targetApp.bundleIdentifier != Bundle.main.bundleIdentifier {
                targetApp.activate(options: [.activateIgnoringOtherApps])
            }
        }

        guard let valuesByKey = promptForSlotValues(slotFields, phrase: phrase, abbreviation: abbreviation) else {
            lastDecision = "Cancelled slot prompt for '\(abbreviation)'"
            appendDiagnostic(
                typedCharacter: String(typedCharacter),
                candidateText: candidateText,
                matchedAbbreviation: abbreviation,
                action: "slot-prompt",
                result: "cancelled"
            )
            return nil
        }

        appendDiagnostic(
            typedCharacter: String(typedCharacter),
            candidateText: candidateText,
            matchedAbbreviation: abbreviation,
            action: "slot-prompt",
            result: "filled-\(slotFields.count)-slots"
        )
        return SlotTemplateLogic.applySlotValues(valuesByKey, to: phrase)
    }

    private func promptForSlotValues(
        _ slotFields: [SlotTemplateLogic.SlotField],
        phrase: String,
        abbreviation: String
    ) -> [String: String]? {
        let panelController = SlotPromptPanelController(
            template: phrase,
            slotFields: slotFields,
            abbreviation: abbreviation
        )
        return panelController.runModal()
    }

    private func postKeyEvent(keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func postText(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)

        for codeUnit in text.utf16 {
            var value = codeUnit
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            keyDown?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
            keyDown?.post(tap: .cghidEventTap)

            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            keyUp?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
            keyUp?.post(tap: .cghidEventTap)
        }
    }

    private func pasteTextWithClipboardRestore(_ text: String, abbreviation: String) {
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboardItems(from: pasteboard)
        let wroteText = writePasteboardString(text, to: pasteboard)

        guard wroteText else {
            postText(text)
            appendDiagnostic(
                candidateText: text,
                matchedAbbreviation: abbreviation,
                action: "replacement-insert",
                result: "pasteboard-write-failed-fallback-unicode"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.isInjecting = false
                self?.appendDiagnostic(
                    candidateText: text,
                    matchedAbbreviation: abbreviation,
                    action: "replacement-complete",
                    result: "fallback-unicode-finished"
                )
            }
            return
        }

        appendDiagnostic(
            candidateText: text,
            matchedAbbreviation: abbreviation,
            action: "replacement-insert",
            result: "pasteboard-written"
        )

        let changeCountAfterWrite = pasteboard.changeCount
        postCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            if pasteboard.changeCount == changeCountAfterWrite {
                self?.restorePasteboard(snapshot, to: pasteboard)
            }
            self?.isInjecting = false
            self?.appendDiagnostic(
                candidateText: text,
                matchedAbbreviation: abbreviation,
                action: "replacement-complete",
                result: "paste-finished"
            )
        }
    }

    private func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }

    private func snapshotPasteboardItems(from pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pasteboard.pasteboardItems else {
            return []
        }

        return items.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private func restorePasteboard(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else {
            return
        }
        pasteboard.writeObjects(items)
    }

    private func writePasteboardString(_ string: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(string, forType: .string)
    }

    private static func frontmostAppInfo() -> (name: String, bundleID: String, description: String) {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return ("Unknown", "no-bundle-id", "Unknown")
        }
        let name = app.localizedName ?? "Unknown"
        let bundleID = app.bundleIdentifier ?? "no-bundle-id"
        return (name, bundleID, "\(name) (\(bundleID))")
    }

    private func appendDiagnostic(
        typedCharacter: String? = nil,
        candidateText: String = "",
        matchedAbbreviation: String? = nil,
        action: String,
        result: String
    ) {
        let event = DiagnosticEvent(
            timestamp: Date(),
            appBundleID: lastFrontmostBundleID,
            appDescription: lastFrontmostApp,
            triggerMode: expansionTriggerMode,
            typedCharacter: typedCharacter ?? "",
            candidateText: candidateText,
            matchedAbbreviation: matchedAbbreviation,
            action: action,
            result: result
        )

        recentDiagnostics.append(event)
        if recentDiagnostics.count > maxDiagnosticEvents {
            recentDiagnostics.removeFirst(recentDiagnostics.count - maxDiagnosticEvents)
        }
    }

    private func isSystemCharacter(_ character: Character) -> Bool {
        for scalar in String(character).unicodeScalars {
            if (0xF700...0xF8FF).contains(scalar.value) {
                return true
            }
        }
        return false
    }

    private func playExpansionSound() {
        guard playSoundOnExpand else {
            return
        }

        if let sound = NSSound(named: NSSound.Name(expansionSoundName)) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }
}
