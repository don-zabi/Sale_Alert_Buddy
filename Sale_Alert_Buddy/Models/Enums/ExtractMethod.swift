import Foundation

enum ExtractMethod: Int16 {
    case failed = 0
    case schemaOrg = 1
    case metaTag = 2
    case dataAttribute = 3
    case htmlPattern = 4
    case embeddedJSON = 5
    case siteAPI = 6

    var displayName: String {
        switch self {
        case .failed: return "—"
        case .schemaOrg: return "JSON-LD"
        case .metaTag: return "Meta Tag"
        case .dataAttribute: return "Data Attribute"
        case .htmlPattern: return "HTML Pattern"
        case .embeddedJSON: return "Embedded JSON"
        case .siteAPI: return "Site API"
        }
    }
}
