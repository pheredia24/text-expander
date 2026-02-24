import Foundation

struct Snippet: Identifiable, Codable, Equatable {
    static let defaultGroup = "General"

    let id: UUID
    var abbreviation: String
    var phrase: String
    var group: String

    init(id: UUID = UUID(), abbreviation: String, phrase: String, group: String = Snippet.defaultGroup) {
        self.id = id
        self.abbreviation = abbreviation
        self.phrase = phrase
        self.group = Snippet.normalizedGroupName(group)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case abbreviation
        case phrase
        case group
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        abbreviation = try container.decode(String.self, forKey: .abbreviation)
        phrase = try container.decode(String.self, forKey: .phrase)
        let decodedGroup = try container.decodeIfPresent(String.self, forKey: .group) ?? Snippet.defaultGroup
        group = Snippet.normalizedGroupName(decodedGroup)
    }

    static func normalizedGroupName(_ value: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? defaultGroup : cleaned
    }
}
