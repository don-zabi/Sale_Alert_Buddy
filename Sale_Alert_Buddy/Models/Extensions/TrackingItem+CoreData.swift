import Foundation
import CoreData

@objc(TrackingItem)
public class TrackingItem: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date
    @NSManaged public var originalUrl: String
    @NSManaged public var currentUrl: String
    @NSManaged public var resolvedUrl: String?
    @NSManaged public var domain: String
    @NSManaged public var status: Int16
    @NSManaged public var pauseReason: Int16
    @NSManaged public var baselinePrice: NSDecimalNumber
    @NSManaged public var baselineCurrency: String
    @NSManaged public var latestPrice: NSDecimalNumber?
    @NSManaged public var latestCurrency: String?
    @NSManaged public var notificationThreshold: Double
    @NSManaged public var notificationConditionType: Int16
    @NSManaged public var notificationConditionValue: Double
    @NSManaged public var lastCheckedAt: Date?
    @NSManaged public var lastSuccessAt: Date?
    @NSManaged public var failCountConsecutive: Int16
    @NSManaged public var lastErrorType: Int16
    @NSManaged public var lastHttpStatus: Int16
    @NSManaged public var productTitle: String?
    @NSManaged public var productIdHints: String?
    @NSManaged public var imageUrl: String?
    @NSManaged public var category: String?
    @NSManaged public var memo: String?
    @NSManaged public var tags: String?
    @NSManaged public var lastNotifiedPrice: NSDecimalNumber?
    @NSManaged public var fetchLogs: NSSet?
}

// MARK: - Typed Accessors

extension TrackingItem {
    var itemStatus: ItemStatus {
        get { ItemStatus(rawValue: status) ?? .ok }
        set { status = newValue.rawValue }
    }

    var itemPauseReason: PauseReason? {
        get { PauseReason(rawValue: pauseReason) }
        set { pauseReason = newValue?.rawValue ?? 0 }
    }

    var itemLastErrorType: FetchErrorType {
        get { FetchErrorType(rawValue: lastErrorType) ?? .none }
        set { lastErrorType = newValue.rawValue }
    }

    var baselinePriceDecimal: Decimal {
        get { baselinePrice.decimalValue }
        set { baselinePrice = NSDecimalNumber(decimal: newValue) }
    }

    var latestPriceDecimal: Decimal? {
        get { latestPrice?.decimalValue }
        set { latestPrice = newValue.map { NSDecimalNumber(decimal: $0) } }
    }

    var lastNotifiedPriceDecimal: Decimal? {
        get { lastNotifiedPrice?.decimalValue }
        set { lastNotifiedPrice = newValue.map { NSDecimalNumber(decimal: $0) } }
    }

    var itemNotificationConditionType: NotificationConditionType {
        get { NotificationConditionType(rawValue: notificationConditionType) ?? .percentage }
        set { notificationConditionType = newValue.rawValue }
    }

    var itemNotificationConditionValue: Double {
        get {
            if notificationConditionValue > 0 {
                return notificationConditionValue
            }
            let legacyPercent = notificationThreshold * 100
            if legacyPercent > 0 {
                return legacyPercent
            }
            return itemNotificationConditionType.defaultValue
        }
        set {
            notificationConditionValue = max(newValue, 0)
        }
    }

    var tagsArray: [String] {
        get {
            guard let json = tags,
                  let data = json.data(using: .utf8),
                  let array = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return array
        }
        set {
            tags = (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    var productIdHintsArray: [String] {
        get {
            guard let json = productIdHints,
                  let data = json.data(using: .utf8),
                  let array = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return array
        }
        set {
            productIdHints = (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    var displayTitle: String {
        productTitle ?? domain
    }

    /// Human-readable site/brand name derived from the effective domain.
    var siteDisplayName: String {
        let d = effectiveDomain
        let known: [String: String] = [
            // Amazon (including short-link domains stored on older items)
            "amazon.co.jp":                  "Amazon",
            "amazon.com":                    "Amazon",
            "amzn.asia":                     "Amazon",
            "amzn.to":                       "Amazon",
            "a.co":                          "Amazon",
            // Mercari
            "mercari.com":                   "Mercari",
            "jp.mercari.com":                "Mercari",
            // Rakuten
            "rakuten.co.jp":                 "楽天市場",
            "item.rakuten.co.jp":            "楽天市場",
            // Yahoo
            "shopping.yahoo.co.jp":          "Yahoo!ショッピング",
            "store.shopping.yahoo.co.jp":    "Yahoo!ショッピング",
            "auctions.yahoo.co.jp":          "Yahoo!オークション",
            "paypayfleamarket.yahoo.co.jp":  "PayPayフリマ",
            "yahoo.co.jp":                   "Yahoo! Japan",
            // Others
            "yodobashi.com":                 "ヨドバシカメラ",
            "kakaku.com":                    "価格.com",
            "zozo.jp":                       "ZOZOTOWN",
            "zozotown.com":                  "ZOZOTOWN",
            "uniqlo.com":                    "UNIQLO",
            "ebay.com":                      "eBay",
            "qoo10.jp":                      "Qoo10",
            "m.qoo10.jp":                    "Qoo10",
            "wowma.jp":                      "au PAY マーケット",
            "yamada-denkiweb.com":           "ヤマダウェブコム",
            "biccamera.com":                 "ビックカメラ",
            "bic-camera.com":                "ビックカメラ",
            "yslb.jp":                       "YSL Beauty",
            "maccosmetics.jp":               "M·A·C",
            "m.maccosmetics.jp":             "M·A·C",
            "udemy.com":                     "Udemy",
            "m.shein.com":                   "SHEIN",
            "shein.com":                     "SHEIN",
            "temu.com":                      "Temu",
        ]
        if let name = known[d] { return name }
        // Fallback: capitalise the first label (e.g. "rakuten" → "Rakuten")
        let first = d.split(separator: ".").first.map(String.init) ?? d
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    /// URL for the site's favicon via Google's favicon service.
    /// Uses the effective (resolved) domain so short-link items get the real site's favicon.
    var faviconURL: URL? {
        // For known short-link domains, force the lookup to the real site domain
        let shortLinkMap: [String: String] = [
            "amzn.asia": "amazon.co.jp",
            "amzn.to":   "amazon.com",
            "a.co":      "amazon.com",
        ]
        let d = effectiveDomain
        let lookupDomain = shortLinkMap[d] ?? d
        guard !lookupDomain.isEmpty else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(lookupDomain)&sz=32")
    }

    /// The most accurate domain available: resolved URL host → stored domain.
    private var effectiveDomain: String {
        let raw: String
        if let resolved = resolvedUrl,
           let host = URL(string: resolved)?.host,
           !host.isEmpty {
            raw = host
        } else {
            raw = domain
        }
        return raw.hasPrefix("www.") ? String(raw.dropFirst(4)) : raw
    }

    var itemCategory: String? {
        get {
            guard let category else { return nil }
            let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            category = trimmed.isEmpty ? nil : trimmed
        }
    }

    var dropAmount: Decimal? {
        guard let latest = latestPriceDecimal else { return nil }
        let drop = baselinePriceDecimal - latest
        return drop > 0 ? drop : nil
    }

    var dropPercentage: Double? {
        guard let latest = latestPriceDecimal, baselinePriceDecimal > 0 else { return nil }
        let drop = baselinePriceDecimal - latest
        guard drop > 0 else { return nil }
        return Double(truncating: (drop / baselinePriceDecimal * 100) as NSDecimalNumber)
    }

    /// Percentage by which the latest price exceeds the baseline (positive = price went up).
    var risePercentage: Double? {
        guard let latest = latestPriceDecimal, baselinePriceDecimal > 0 else { return nil }
        let rise = latest - baselinePriceDecimal
        guard rise > 0 else { return nil }
        return Double(truncating: (rise / baselinePriceDecimal * 100) as NSDecimalNumber)
    }
}

// MARK: - FetchLog Relationship

extension TrackingItem {
    var fetchLogsArray: [FetchLog] {
        let set = fetchLogs as? Set<FetchLog> ?? []
        return set.sorted { $0.timestamp > $1.timestamp }
    }

    func addFetchLogAndRotate(_ log: FetchLog, context: NSManagedObjectContext) {
        addToFetchLogs(log)
        let allLogs = fetchLogsArray
        if allLogs.count > 50 {
            let toDelete = allLogs.suffix(from: 50)
            toDelete.forEach { context.delete($0) }
        }
    }

    @objc(addFetchLogsObject:)
    @NSManaged public func addToFetchLogs(_ value: FetchLog)

    @objc(removeFetchLogsObject:)
    @NSManaged public func removeFromFetchLogs(_ value: FetchLog)

    @objc(addFetchLogs:)
    @NSManaged public func addToFetchLogs(_ values: NSSet)

    @objc(removeFetchLogs:)
    @NSManaged public func removeFromFetchLogs(_ values: NSSet)
}

// MARK: - FetchRequest

extension TrackingItem {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<TrackingItem> {
        NSFetchRequest<TrackingItem>(entityName: "TrackingItem")
    }

    static func activeItemsFetchRequest() -> NSFetchRequest<TrackingItem> {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "status != %d", ItemStatus.paused.rawValue)
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return request
    }

    static func allItemsFetchRequest() -> NSFetchRequest<TrackingItem> {
        let request = fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return request
    }
}

// MARK: - Convenience Init

extension TrackingItem {
    static func create(in context: NSManagedObjectContext) -> TrackingItem {
        let item = TrackingItem(context: context)
        item.id = UUID()
        item.createdAt = Date()
        item.updatedAt = Date()
        item.originalUrl = ""
        item.currentUrl = ""
        item.domain = ""
        item.status = ItemStatus.ok.rawValue
        item.pauseReason = 0
        item.baselinePrice = NSDecimalNumber.zero
        item.baselineCurrency = ""
        item.notificationThreshold = 0.01
        item.notificationConditionType = NotificationConditionType.percentage.rawValue
        item.notificationConditionValue = 1.0
        item.failCountConsecutive = 0
        item.lastErrorType = FetchErrorType.none.rawValue
        item.lastHttpStatus = 0
        return item
    }
}
