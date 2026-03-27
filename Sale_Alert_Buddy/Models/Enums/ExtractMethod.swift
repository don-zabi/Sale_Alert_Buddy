import Foundation

enum ExtractMethod: Int16 {
    case failed = 0
    case schemaOrg = 1
    case metaTag = 2
    case dataAttribute = 3
    case htmlPattern = 4

    var displayName: String {
        switch self {
        case .failed: return "—"
        case .schemaOrg: return "JSON-LD"
        case .metaTag: return "Meta Tag"
        case .dataAttribute: return "Data Attribute"
        case .htmlPattern: return "HTML Pattern"
        }
    }
}
