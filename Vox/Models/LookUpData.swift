import Foundation

// MARK: - Tab enum

enum LookUpTab: String, CaseIterable, Identifiable {
    case translation = "Translation"
    case dictionary  = "Dictionary"
    case context     = "Context"
    case images      = "Images"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .translation: "text.bubble"
        case .dictionary:  "character.book.closed"
        case .context:     "text.magnifyingglass"
        case .images:      "photo"
        }
    }
}

// MARK: - App-facing types

struct LookUpData: Equatable {
    var dictionary: DictionaryData?
    var context: ContextData?
    var imageSearchQuery: String?
}

struct DictionaryData: Equatable {
    var partOfSpeech: String
    var pronunciation: String?
    var entries: [DictionaryEntry]
}

struct DictionaryEntry: Equatable, Identifiable {
    let id = UUID()
    var meaning: String
    var example: String?
    var exampleTranslation: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.meaning == rhs.meaning && lhs.example == rhs.example
            && lhs.exampleTranslation == rhs.exampleTranslation
    }
}

struct ContextData: Equatable {
    var synonyms: [SynonymEntry]
    var register: String?
    var collocations: [String]
    var falseFriends: [FalseFriendEntry]
    var notes: [String]
}

struct SynonymEntry: Equatable, Identifiable {
    let id = UUID()
    var word: String
    var note: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.word == rhs.word && lhs.note == rhs.note
    }
}

struct FalseFriendEntry: Equatable, Identifiable {
    let id = UUID()
    var word: String
    var meaning: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.word == rhs.word && lhs.meaning == rhs.meaning
    }
}

// MARK: - Image data

struct ImageItem: Equatable, Identifiable {
    let id = UUID()
    var imageURL: URL           // thumbnail for display
    var fullImageURL: URL?      // full resolution for copying
    var title: String
    var sourceURL: URL?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.imageURL == rhs.imageURL && lhs.title == rhs.title
    }
}

// MARK: - Codable intermediate for JSON parsing

struct LookUpResponse: Codable {
    struct Dictionary: Codable {
        let partOfSpeech: String
        let pronunciation: String?
        let entries: [Entry]

        struct Entry: Codable {
            let meaning: String
            let example: String?
            let exampleTranslation: String?
        }
    }

    struct Context: Codable {
        let synonyms: [Synonym]?
        let register: String?
        let collocations: [String]?
        let falseFriends: [FalseFriend]?
        let notes: [String]?

        struct Synonym: Codable {
            let word: String
            let note: String
        }

        struct FalseFriend: Codable {
            let word: String
            let meaning: String
        }
    }

    let dictionary: Dictionary?
    let context: Context?
    let imageSearchQuery: String?

    // Resilient decoding — if one section is malformed, others still parse
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dictionary = try? container.decode(Dictionary.self, forKey: .dictionary)
        context = try? container.decode(Context.self, forKey: .context)
        imageSearchQuery = try? container.decode(String.self, forKey: .imageSearchQuery)
    }

    func toLookUpData() -> LookUpData {
        LookUpData(
            dictionary: dictionary.map {
                DictionaryData(
                    partOfSpeech: $0.partOfSpeech,
                    pronunciation: $0.pronunciation,
                    entries: $0.entries.map {
                        DictionaryEntry(meaning: $0.meaning,
                                        example: $0.example,
                                        exampleTranslation: $0.exampleTranslation)
                    })
            },
            context: context.map {
                ContextData(
                    synonyms: ($0.synonyms ?? []).map { SynonymEntry(word: $0.word, note: $0.note) },
                    register: $0.register,
                    collocations: $0.collocations ?? [],
                    falseFriends: ($0.falseFriends ?? []).map {
                        FalseFriendEntry(word: $0.word, meaning: $0.meaning)
                    },
                    notes: $0.notes ?? [])
            },
            imageSearchQuery: imageSearchQuery
        )
    }
}
