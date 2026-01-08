import Foundation

/// AI-generated response draft
struct Draft: Codable {
    var content: String
    let tone: Tone
    let generatedAt: Date

    var isEdited: Bool = false

    // MARK: - Tone

    enum Tone: String, Codable, CaseIterable {
        case professional
        case casual
        case friendly
        case brief

        var displayName: String {
            rawValue.capitalized
        }

        var description: String {
            switch self {
            case .professional: return "Formal business language"
            case .casual: return "Relaxed, conversational"
            case .friendly: return "Warm and personable"
            case .brief: return "Short and to the point"
            }
        }
    }
}
