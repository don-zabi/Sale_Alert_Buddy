import Foundation
import SwiftSoup

enum PriceCandidateSourceType: String, Sendable, CaseIterable {
    case jsonld
    case meta
    case dataAttribute
    case embeddedJson
    case contextual
    case htmlPattern
    case renderedVisible
    case siteAPI

    var extractMethod: ExtractMethod {
        switch self {
        case .jsonld:
            return .schemaOrg
        case .meta:
            return .metaTag
        case .dataAttribute:
            return .dataAttribute
        case .embeddedJson:
            return .embeddedJSON
        case .contextual:
            return .htmlContext
        case .htmlPattern:
            return .htmlPattern
        case .renderedVisible:
            return .renderedVisible
        case .siteAPI:
            return .siteAPI
        }
    }

    var debugName: String { rawValue }
}

enum PriceCandidateOrigin: String, Sendable {
    case rawHTML
    case renderedHTML
    case renderedDOM
    case siteAPI

    var debugName: String { rawValue }

    var isRendered: Bool {
        switch self {
        case .renderedHTML, .renderedDOM:
            return true
        case .rawHTML, .siteAPI:
            return false
        }
    }
}

enum PriceSectionType: String, Sendable, CaseIterable {
    case mainProduct
    case buybox
    case campaign
    case shipping
    case review
    case recommendation
    case related
    case ranking
    case breadcrumb
    case gallery
    case unknown
}

enum PriceConfidenceLevel: String, Sendable {
    case high
    case medium
    case low
}

struct PriceBoundingRect: Sendable, Equatable {
    let top: Double
    let left: Double
    let width: Double
    let height: Double
}

struct PriceAnchor: Sendable, Equatable {
    let domPath: String
    let rawText: String
    let normalizedText: String
    let tagName: String
    let elementId: String
    let classNames: [String]
    let ancestorTokens: [String]
    let sectionType: PriceSectionType
    let isVisible: Bool
    let boundingRect: PriceBoundingRect?
    let anchorQualityScore: Double
}

struct PriceCandidate: Sendable {
    let amount: Decimal
    let currency: String
    let sourceType: PriceCandidateSourceType
    let origin: PriceCandidateOrigin
    let rawText: String
    let normalizedText: String
    let contextBefore: String
    let contextAfter: String
    let domPath: String
    let tagName: String
    let elementId: String
    let classNames: [String]
    let ancestorTokens: [String]
    let isVisible: Bool
    let boundingRect: PriceBoundingRect?
    let top: Double?
    let left: Double?
    let width: Double?
    let height: Double?
    let distanceToTitle: Double?
    let distanceToBuyButton: Double?
    let distanceToCartArea: Double?
    let isAboveTheFold: Bool
    let negativeContextFlags: [String]
    let positiveContextFlags: [String]
    let sectionType: PriceSectionType
    let confidence: Double
    let debugReasons: [String]
    let fontSize: Double?
    let fontWeight: Double?
    let displayStyle: String?
    let visibilityStyle: String?
    let opacity: Double?
    let sameAmountNodeCount: Int
    let anchorQualityScore: Double

    init(
        amount: Decimal,
        currency: String,
        sourceType: PriceCandidateSourceType,
        origin: PriceCandidateOrigin,
        rawText: String = "",
        normalizedText: String = "",
        contextBefore: String = "",
        contextAfter: String = "",
        domPath: String = "",
        tagName: String = "",
        elementId: String = "",
        classNames: [String] = [],
        ancestorTokens: [String] = [],
        isVisible: Bool = false,
        boundingRect: PriceBoundingRect? = nil,
        top: Double? = nil,
        left: Double? = nil,
        width: Double? = nil,
        height: Double? = nil,
        distanceToTitle: Double? = nil,
        distanceToBuyButton: Double? = nil,
        distanceToCartArea: Double? = nil,
        isAboveTheFold: Bool = false,
        negativeContextFlags: [String] = [],
        positiveContextFlags: [String] = [],
        sectionType: PriceSectionType = .unknown,
        confidence: Double,
        debugReasons: [String] = [],
        fontSize: Double? = nil,
        fontWeight: Double? = nil,
        displayStyle: String? = nil,
        visibilityStyle: String? = nil,
        opacity: Double? = nil,
        sameAmountNodeCount: Int = 1,
        anchorQualityScore: Double = 0
    ) {
        self.amount = amount
        self.currency = currency
        self.sourceType = sourceType
        self.origin = origin
        self.rawText = rawText
        self.normalizedText = normalizedText
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.domPath = domPath
        self.tagName = tagName
        self.elementId = elementId
        self.classNames = classNames
        self.ancestorTokens = ancestorTokens
        self.isVisible = isVisible
        self.boundingRect = boundingRect
        self.top = top
        self.left = left
        self.width = width
        self.height = height
        self.distanceToTitle = distanceToTitle
        self.distanceToBuyButton = distanceToBuyButton
        self.distanceToCartArea = distanceToCartArea
        self.isAboveTheFold = isAboveTheFold
        self.negativeContextFlags = negativeContextFlags
        self.positiveContextFlags = positiveContextFlags
        self.sectionType = sectionType
        self.confidence = confidence
        self.debugReasons = debugReasons
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.displayStyle = displayStyle
        self.visibilityStyle = visibilityStyle
        self.opacity = opacity
        self.sameAmountNodeCount = sameAmountNodeCount
        self.anchorQualityScore = anchorQualityScore
    }

    var extractMethod: ExtractMethod { sourceType.extractMethod }

    var amountKey: String {
        let numeric = NSDecimalNumber(decimal: amount).stringValue
        return "\(currency.uppercased())|\(numeric)"
    }

    var anchorKey: String {
        if !domPath.isEmpty {
            return domPath
        }
        return "\(tagName)|\(elementId)|\(classNames.joined(separator: "."))|\(rawText)"
    }

    var hasPrimarySignal: Bool {
        sectionType == .mainProduct ||
        sectionType == .buybox ||
        isNearTitle ||
        isNearBuyButton
    }

    var hasSevereNegativeSignal: Bool {
        !Set(negativeContextFlags).isDisjoint(with: PriceHeuristics.severeNegativeFlags)
    }

    var hasAuthoritativeSource: Bool {
        switch sourceType {
        case .jsonld, .meta, .dataAttribute, .embeddedJson, .siteAPI:
            return true
        case .contextual, .htmlPattern, .renderedVisible:
            return false
        }
    }

    var isNearTitle: Bool {
        guard let distanceToTitle else { return false }
        if boundingRect != nil {
            return distanceToTitle <= 280
        }
        return distanceToTitle <= 4
    }

    var isNearBuyButton: Bool {
        guard let distanceToBuyButton else { return false }
        if boundingRect != nil {
            return distanceToBuyButton <= 280
        }
        return distanceToBuyButton <= 4
    }

    var anchor: PriceAnchor? {
        guard !domPath.isEmpty || !rawText.isEmpty else { return nil }
        return PriceAnchor(
            domPath: domPath,
            rawText: rawText,
            normalizedText: normalizedText,
            tagName: tagName,
            elementId: elementId,
            classNames: classNames,
            ancestorTokens: ancestorTokens,
            sectionType: sectionType,
            isVisible: isVisible,
            boundingRect: boundingRect,
            anchorQualityScore: anchorQualityScore
        )
    }
}

struct ScoredPriceCandidate: Sendable {
    let candidate: PriceCandidate
    let score: Double
    let anchorScore: Double
    let adoptionReasons: [String]
    let rejectionReasons: [String]
}

struct PriceSourceAnalysis: Sendable {
    let origin: PriceCandidateOrigin
    let candidates: [PriceCandidate]
    let rankedCandidates: [ScoredPriceCandidate]
    let bestCandidate: ScoredPriceCandidate?
    let isProtectionPage: Bool
    let hasMeaningfulContent: Bool

    var topCandidates: [ScoredPriceCandidate] {
        Array(rankedCandidates.prefix(5))
    }
}

struct PriceResolutionReport: Sendable {
    let result: PriceResult
    let finalCandidate: ScoredPriceCandidate
    let rawAnalysis: PriceSourceAnalysis?
    let renderedAnalysis: PriceSourceAnalysis?
    let combinedCandidates: [ScoredPriceCandidate]
    let comparisonReasons: [String]
    let confidenceReasons: [String]
}

enum PriceHeuristics {
    static let positiveContextTokens = [
        "price", "current", "sale", "selling", "offer", "special", "final",
        "価格", "税込", "販売価格", "現在価格", "購入", "カート", "円", "¥", "￥"
    ]

    static let primaryPriceTokens = [
        "price", "sale", "current", "selling",
        "価格", "税込", "販売価格", "現在価格"
    ]

    static let positiveAncestorTokens = [
        "product", "pdp", "item", "detail", "price", "buy", "cart", "offer", "purchase"
    ]

    static let negativeContextTokens = [
        "point", "reward", "coupon", "deal", "campaign", "shipping", "postage", "gift",
        "wrapping", "review", "ranking", "history", "recommend", "recommended", "related",
        "other-store", "similar", "variant", "option", "reference", "list", "regular",
        "usual", "original", "compare", "ポイント", "還元", "クーポン", "割引", "off",
        "送料無料", "送料", "ラッピング", "参考価格", "通常価格", "メーカー希望小売",
        "レビュー", "おすすめ", "関連商品", "他ストア", "ランキング"
    ]

    static let sectionNegativeTokens = [
        "recommend", "recommended", "related", "similar", "review", "ranking", "history",
        "campaign", "coupon", "shipping", "delivery", "breadcrumb", "gallery",
        "おすすめ", "関連", "レビュー", "ランキング", "履歴", "キャンペーン", "クーポン", "送料"
    ]

    static let buyButtonTokens = [
        "buy", "cart", "purchase", "checkout", "basket", "bag", "購入", "カート", "注文", "レジ"
    ]

    static let sectionMapping: [(PriceSectionType, [String])] = [
        (.buybox, ["buybox", "buy", "cart", "purchase", "offer", "checkout", "basket", "bag"]),
        (.recommendation, ["recommend", "recommended", "suggest"]),
        (.related, ["related", "similar", "other-store"]),
        (.review, ["review", "rating"]),
        (.ranking, ["ranking"]),
        (.campaign, ["campaign", "coupon", "deal", "point", "reward"]),
        (.shipping, ["shipping", "postage", "delivery", "gift", "wrapping"]),
        (.breadcrumb, ["breadcrumb"]),
        (.gallery, ["gallery", "carousel", "slider", "thumbnail"]),
        (.mainProduct, ["product", "detail", "pdp", "item-info", "itemdetail", "productdetail"])
    ]

    static let severeNegativeFlags: Set<String> = [
        "point", "reward", "coupon", "shipping", "postage", "wrapping", "reference",
        "regular", "usual", "related", "recommend", "review", "ranking", "campaign"
    ]

    static let rawCandidateSelector = [
        "h1", "h2", "h3", "span", "div", "p", "strong", "b", "em", "label", "td", "li",
        "dd", "dt", "section", "article", "[class*='price']", "[id*='price']", "[data-price]",
        "[data-sale-price]", "[data-amount]", "[data-testid*='price']", "[class*='sale']",
        "[id*='sale']", "[class*='amount']", "[id*='amount']"
    ].joined(separator: ",")

    static let titleSelectors = [
        "h1",
        "[itemprop='name']",
        "[class*='title']",
        "[class*='Title']",
        "[id*='title']",
        "[class*='product-name']",
        "[class*='productName']"
    ].joined(separator: ",")

    static let buySelectors = [
        "button",
        "input[type='submit']",
        "input[type='button']",
        "a[role='button']",
        "[class*='cart']",
        "[id*='cart']",
        "[class*='buy']",
        "[id*='buy']",
        "[class*='purchase']",
        "[id*='purchase']"
    ].joined(separator: ",")
}

enum PriceCandidateFactory {
    static func candidate(
        from result: PriceResult,
        origin: PriceCandidateOrigin
    ) -> PriceCandidate {
        PriceCandidate(
            amount: result.price,
            currency: result.currency,
            sourceType: result.sourceType ?? sourceType(for: result.extractMethod),
            origin: origin,
            rawText: result.anchor?.rawText ?? NSDecimalNumber(decimal: result.price).stringValue,
            normalizedText: result.anchor?.normalizedText ?? NSDecimalNumber(decimal: result.price).stringValue,
            contextBefore: "",
            contextAfter: "",
            domPath: result.anchor?.domPath ?? "",
            tagName: result.anchor?.tagName ?? "",
            elementId: result.anchor?.elementId ?? "",
            classNames: result.anchor?.classNames ?? [],
            ancestorTokens: result.anchor?.ancestorTokens ?? [],
            isVisible: result.anchor?.isVisible ?? origin.isRendered,
            boundingRect: result.anchor?.boundingRect,
            top: result.anchor?.boundingRect?.top,
            left: result.anchor?.boundingRect?.left,
            width: result.anchor?.boundingRect?.width,
            height: result.anchor?.boundingRect?.height,
            isAboveTheFold: (result.anchor?.boundingRect?.top ?? .greatestFiniteMagnitude) <= 844 * 0.8,
            sectionType: result.anchor?.sectionType ?? .unknown,
            confidence: result.confidence,
            debugReasons: ["bridged-price-result"],
            anchorQualityScore: result.anchor?.anchorQualityScore ?? 0
        )
    }

    static func siteAPICandidate(
        from result: PriceResult,
        origin: PriceCandidateOrigin
    ) -> PriceCandidate {
        let candidate = candidate(from: result, origin: origin)
        return PriceCandidate(
            amount: candidate.amount,
            currency: candidate.currency,
            sourceType: .siteAPI,
            origin: origin,
            rawText: candidate.rawText,
            normalizedText: candidate.normalizedText,
            contextBefore: candidate.contextBefore,
            contextAfter: candidate.contextAfter,
            domPath: candidate.domPath,
            tagName: candidate.tagName,
            elementId: candidate.elementId,
            classNames: candidate.classNames,
            ancestorTokens: candidate.ancestorTokens,
            isVisible: candidate.isVisible,
            boundingRect: candidate.boundingRect,
            top: candidate.top,
            left: candidate.left,
            width: candidate.width,
            height: candidate.height,
            distanceToTitle: candidate.distanceToTitle,
            distanceToBuyButton: candidate.distanceToBuyButton,
            distanceToCartArea: candidate.distanceToCartArea,
            isAboveTheFold: candidate.isAboveTheFold,
            negativeContextFlags: candidate.negativeContextFlags,
            positiveContextFlags: candidate.positiveContextFlags,
            sectionType: candidate.sectionType,
            confidence: candidate.confidence,
            debugReasons: ["site-api"],
            fontSize: candidate.fontSize,
            fontWeight: candidate.fontWeight,
            displayStyle: candidate.displayStyle,
            visibilityStyle: candidate.visibilityStyle,
            opacity: candidate.opacity,
            sameAmountNodeCount: candidate.sameAmountNodeCount,
            anchorQualityScore: candidate.anchorQualityScore
        )
    }

    static func sourceType(for method: ExtractMethod) -> PriceCandidateSourceType {
        switch method {
        case .schemaOrg:
            return .jsonld
        case .metaTag:
            return .meta
        case .dataAttribute:
            return .dataAttribute
        case .htmlPattern:
            return .htmlPattern
        case .embeddedJSON:
            return .embeddedJson
        case .siteAPI:
            return .siteAPI
        case .htmlContext:
            return .contextual
        case .renderedVisible:
            return .renderedVisible
        case .failed:
            return .htmlPattern
        }
    }
}

struct PriceDocumentReferenceSignals {
    let titleElements: [Element]
    let buyButtonElements: [Element]
}

enum PriceDocumentSignals {
    static func extract(from document: Document) -> PriceDocumentReferenceSignals {
        let titleElements = (try? document.select(PriceHeuristics.titleSelectors).array())?
            .filter { element in
                let text = ((try? element.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return !text.isEmpty && text.count >= 2
            } ?? []

        let buyElements = (try? document.select(PriceHeuristics.buySelectors).array())?
            .filter { element in
                let text = normalized([
                    (try? element.text()) ?? "",
                    (try? element.attr("value")) ?? "",
                    (try? element.attr("aria-label")) ?? "",
                    element.id(),
                    (try? element.className()) ?? ""
                ].joined(separator: " "))

                return PriceHeuristics.buyButtonTokens.contains { text.contains($0) }
            } ?? []

        return PriceDocumentReferenceSignals(
            titleElements: Array(titleElements.prefix(4)),
            buyButtonElements: Array(buyElements.prefix(8))
        )
    }

    static func normalized(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
