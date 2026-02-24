import Foundation

enum ExpansionTriggerMode: String, CaseIterable, Codable {
    case delimiterOnly
    case instant
}

@MainActor
final class SnippetStore: ObservableObject {
    enum ImportExportError: LocalizedError {
        case invalidPayload

        var errorDescription: String? {
            switch self {
            case .invalidPayload:
                return "The selected file is not a valid snippet export."
            }
        }
    }

    @Published var snippets: [Snippet] {
        didSet {
            persistSnippets()
        }
    }

    @Published var isEnabled: Bool {
        didSet {
            userDefaults.set(isEnabled, forKey: isEnabledKey)
        }
    }

    @Published var usePasteMode: Bool {
        didSet {
            userDefaults.set(usePasteMode, forKey: usePasteModeKey)
        }
    }

    @Published var playSoundOnExpand: Bool {
        didSet {
            userDefaults.set(playSoundOnExpand, forKey: playSoundOnExpandKey)
        }
    }

    @Published var expansionSoundName: String {
        didSet {
            userDefaults.set(expansionSoundName, forKey: expansionSoundNameKey)
        }
    }

    @Published var expansionTriggerMode: ExpansionTriggerMode {
        didSet {
            userDefaults.set(expansionTriggerMode.rawValue, forKey: expansionTriggerModeKey)
        }
    }

    private let userDefaults: UserDefaults
    private let snippetsKey = "text_expander.snippets.v1"
    private let isEnabledKey = "text_expander.enabled.v1"
    private let usePasteModeKey = "text_expander.use_paste_mode.v1"
    private let playSoundOnExpandKey = "text_expander.play_sound_on_expand.v1"
    private let expansionSoundNameKey = "text_expander.expansion_sound_name.v1"
    private let expansionTriggerModeKey = "text_expander.expansion_trigger_mode.v1"

    static let defaultExpansionSoundName = "Tink"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.snippets = Self.loadSnippets(from: userDefaults, key: snippetsKey) ?? [
            Snippet(abbreviation: "sig", phrase: "Best regards,\nPablo", group: "General"),
            Snippet(abbreviation: "addr", phrase: "123 Main Street, Springfield", group: "General"),
        ]
        self.isEnabled = userDefaults.object(forKey: isEnabledKey) as? Bool ?? true
        self.usePasteMode = userDefaults.object(forKey: usePasteModeKey) as? Bool ?? true
        self.playSoundOnExpand = userDefaults.object(forKey: playSoundOnExpandKey) as? Bool ?? true
        self.expansionSoundName = userDefaults.string(forKey: expansionSoundNameKey) ?? Self.defaultExpansionSoundName
        self.expansionTriggerMode = ExpansionTriggerMode(rawValue: userDefaults.string(forKey: expansionTriggerModeKey) ?? "") ?? .delimiterOnly
    }

    func addSnippet(abbreviation: String, phrase: String, group: String = Snippet.defaultGroup) {
        let cleanedAbbreviation = abbreviation.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedGroup = Snippet.normalizedGroupName(group)

        guard !cleanedAbbreviation.isEmpty, !cleanedPhrase.isEmpty else {
            return
        }

        if let existingIndex = snippets.firstIndex(where: { $0.abbreviation.caseInsensitiveCompare(cleanedAbbreviation) == .orderedSame }) {
            snippets[existingIndex].phrase = cleanedPhrase
            snippets[existingIndex].group = cleanedGroup
        } else {
            let snippet = Snippet(abbreviation: cleanedAbbreviation, phrase: cleanedPhrase, group: cleanedGroup)
            if let firstIndexInTargetGroup = snippets.firstIndex(where: { $0.group.caseInsensitiveCompare(cleanedGroup) == .orderedSame }) {
                snippets.insert(snippet, at: firstIndexInTargetGroup)
            } else {
                snippets.append(snippet)
            }
        }
    }

    func removeSnippet(id: UUID) {
        snippets.removeAll { $0.id == id }
    }

    @discardableResult
    func createSnippet(inGroup group: String = Snippet.defaultGroup) -> UUID {
        let targetGroup = Snippet.normalizedGroupName(group)
        let snippet = Snippet(
            abbreviation: "",
            phrase: "",
            group: targetGroup
        )
        if let firstIndexInTargetGroup = snippets.firstIndex(where: { $0.group.caseInsensitiveCompare(targetGroup) == .orderedSame }) {
            snippets.insert(snippet, at: firstIndexInTargetGroup)
        } else {
            snippets.append(snippet)
        }
        return snippet.id
    }

    func moveGroup(named group: String, direction: Int) {
        guard direction == -1 || direction == 1 else {
            return
        }

        var order = Self.currentGroupOrder(from: snippets)
        guard let index = order.firstIndex(where: { $0.caseInsensitiveCompare(group) == .orderedSame }) else {
            return
        }

        let destination = index + direction
        guard destination >= 0, destination < order.count else {
            return
        }

        order.swapAt(index, destination)
        applyGroupOrder(order)
    }

    func renameGroup(named group: String, to newName: String) {
        let sourceGroup = Snippet.normalizedGroupName(group)
        let requestedTargetGroup = Snippet.normalizedGroupName(newName)
        let targetGroup = snippets.first(where: {
            $0.group.caseInsensitiveCompare(requestedTargetGroup) == .orderedSame &&
            $0.group.caseInsensitiveCompare(sourceGroup) != .orderedSame
        })?.group ?? requestedTargetGroup

        var updatedSnippets = snippets
        var didChange = false

        for index in updatedSnippets.indices where updatedSnippets[index].group.caseInsensitiveCompare(sourceGroup) == .orderedSame {
            if updatedSnippets[index].group != targetGroup {
                updatedSnippets[index].group = targetGroup
                didChange = true
            }
        }

        if didChange {
            snippets = updatedSnippets
        }
    }

    func exportSnippets(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snippets)
        try data.write(to: url, options: .atomic)
    }

    func importSnippets(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let imported = try decoder.decode([Snippet].self, from: data)
        let normalized = Self.normalize(imported)
        guard !normalized.isEmpty else {
            throw ImportExportError.invalidPayload
        }
        snippets = normalized
    }

    private func persistSnippets() {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(snippets) else {
            return
        }
        userDefaults.set(data, forKey: snippetsKey)
    }

    private static func normalize(_ input: [Snippet]) -> [Snippet] {
        var ordered: [Snippet] = []
        var indexByKey: [String: Int] = [:]

        for snippet in input {
            let cleanedAbbreviation = snippet.abbreviation.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedPhrase = snippet.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedGroup = Snippet.normalizedGroupName(snippet.group)
            guard !cleanedAbbreviation.isEmpty, !cleanedPhrase.isEmpty else {
                continue
            }

            let normalizedSnippet = Snippet(
                id: snippet.id,
                abbreviation: cleanedAbbreviation,
                phrase: cleanedPhrase,
                group: cleanedGroup
            )
            let key = cleanedAbbreviation.lowercased()

            if let index = indexByKey[key] {
                ordered[index] = normalizedSnippet
            } else {
                indexByKey[key] = ordered.count
                ordered.append(normalizedSnippet)
            }
        }

        return ordered
    }

    private static func loadSnippets(from userDefaults: UserDefaults, key: String) -> [Snippet]? {
        guard let data = userDefaults.data(forKey: key) else {
            return nil
        }

        let decoder = JSONDecoder()
        guard let decoded = try? decoder.decode([Snippet].self, from: data) else {
            return nil
        }

        return normalize(decoded)
    }

    private static func currentGroupOrder(from snippets: [Snippet]) -> [String] {
        var order: [String] = []
        var seen = Set<String>()

        for snippet in snippets {
            let group = Snippet.normalizedGroupName(snippet.group)
            let key = group.lowercased()
            if seen.insert(key).inserted {
                order.append(group)
            }
        }

        return order
    }

    private func applyGroupOrder(_ order: [String]) {
        let normalizedOrder = order.map { Snippet.normalizedGroupName($0) }
        var grouped: [String: [Snippet]] = [:]
        for snippet in snippets {
            let group = Snippet.normalizedGroupName(snippet.group)
            grouped[group, default: []].append(snippet)
        }

        var reordered: [Snippet] = []
        var addedGroups = Set<String>()

        for group in normalizedOrder {
            if let items = grouped[group] {
                reordered.append(contentsOf: items)
                addedGroups.insert(group.lowercased())
            }
        }

        for snippet in snippets {
            let group = Snippet.normalizedGroupName(snippet.group)
            let key = group.lowercased()
            if !addedGroups.contains(key) {
                if let items = grouped[group] {
                    reordered.append(contentsOf: items)
                    addedGroups.insert(key)
                }
            }
        }

        guard reordered.count == snippets.count else {
            return
        }
        snippets = reordered
    }

}
