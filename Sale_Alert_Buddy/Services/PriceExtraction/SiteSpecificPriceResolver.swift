import Foundation

protocol SiteSpecificPriceResolving {
    nonisolated func resolve(
        for url: URL,
        html: String,
        allowURLFallback: Bool
    ) async -> (result: PriceResult, method: ExtractMethod)?
}

struct SiteSpecificPriceResolver: SiteSpecificPriceResolving, Sendable {

    private let udemyResolver: UdemyCoursePriceResolver
    private let sheinResolver: SheinProductPriceResolver
    private let temuResolver: TemuSharePriceResolver

    nonisolated init(session: URLSession = HTMLFetcher.makeDefaultSession()) {
        udemyResolver = UdemyCoursePriceResolver(session: session)
        sheinResolver = SheinProductPriceResolver(session: session)
        temuResolver = TemuSharePriceResolver()
    }

    nonisolated func resolve(
        for url: URL,
        html: String,
        allowURLFallback: Bool
    ) async -> (result: PriceResult, method: ExtractMethod)? {
        if let result = await udemyResolver.resolve(for: url, html: html) {
            return (result, result.extractMethod)
        }
        if let result = await sheinResolver.resolve(for: url, html: html) {
            return (result, result.extractMethod)
        }
        if let result = temuResolver.resolve(
            for: url,
            html: html,
            allowURLFallback: allowURLFallback
        ) {
            return (result, result.extractMethod)
        }
        return nil
    }
}

private struct UdemyCoursePriceResolver: Sendable {

    private let session: URLSession

    nonisolated init(session: URLSession) {
        self.session = session
    }

    nonisolated func resolve(for url: URL, html: String) async -> PriceResult? {
        guard isUdemyURL(url),
              let courseID = extractCourseID(from: html),
              let endpointURL = makeEndpointURL(for: courseID) else {
            return nil
        }

        var request = URLRequest(url: endpointURL)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(HTMLFetcher.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.setValue(url.absoluteString, forHTTPHeaderField: "Referer")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            return extractPurchasePrice(from: raw)
        } catch {
            return nil
        }
    }

    private nonisolated func isUdemyURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "www.udemy.com" || host == "udemy.com"
    }

    private nonisolated func makeEndpointURL(for courseID: String) -> URL? {
        URL(string: "https://www.udemy.com/api-2.0/course-landing-components/\(courseID)/me/?components=buy_button,purchase,purchase_tabs_context,price_text")
    }

    private nonisolated func extractCourseID(from html: String) -> String? {
        let patterns = [
            #"courseId=(\d+)"#,
            #"course/(?:\d+x\d+|\d+_H)/(\d+)(?:[_/.]|$)"#,
            #""course_id"\s*:\s*(\d+)"#,
            #"related_object_id%3D(\d+)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            guard let match = regex.firstMatch(in: html, range: range),
                  let idRange = Range(match.range(at: 1), in: html) else {
                continue
            }

            let courseID = String(html[idRange])
            if !courseID.isEmpty {
                return courseID
            }
        }

        return nil
    }

    private nonisolated func extractPurchasePrice(from raw: [String: Any]) -> PriceResult? {
        let candidatePaths: [[String]] = [
            ["purchase", "data", "pricing_result", "price"],
            ["price_text", "data", "pricing_result", "price"],
            ["buy_button", "button", "payment_data", "purchasePrice"]
        ]

        for path in candidatePaths {
            guard let priceDict = dictionary(at: path, in: raw),
                  let price = decimal(from: priceDict["amount"] ?? priceDict["price"]),
                  let currency = (priceDict["currency"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !currency.isEmpty else {
                continue
            }

            return PriceResult(
                price: price,
                currency: currency.uppercased(),
                extractMethod: .siteAPI,
                confidence: 0.99
            )
        }

        return nil
    }

    private nonisolated func dictionary(at path: [String], in root: [String: Any]) -> [String: Any]? {
        var current: Any = root

        for key in path {
            guard let dict = current as? [String: Any],
                  let next = dict[key] else {
                return nil
            }
            current = next
        }

        return current as? [String: Any]
    }

    private nonisolated func decimal(from value: Any?) -> Decimal? {
        switch value {
        case let decimal as Decimal:
            return decimal
        case let number as NSNumber:
            return Decimal(string: number.stringValue)
        case let string as String:
            if let parsed = PriceCurrencyParser.parse(string) {
                return parsed.price
            }
            return Decimal(string: string.replacingOccurrences(of: ",", with: ""))
        default:
            return nil
        }
    }
}

private struct TemuSharePriceResolver: Sendable {

    nonisolated init() {}

    nonisolated func resolve(
        for url: URL,
        html: String,
        allowURLFallback: Bool
    ) -> PriceResult? {
        guard allowURLFallback,
              isTemuURL(url),
              ProtectionPageDetector.isProtectionPage(html, url: url),
              let price = extractSharedPrice(from: url) else {
            return nil
        }

        return PriceResult(
            price: price,
            currency: "JPY",
            extractMethod: .siteAPI,
            confidence: 0.97
        )
    }

    private nonisolated func isTemuURL(_ url: URL) -> Bool {
        url.host?.lowercased().contains("temu.com") == true
    }

    private nonisolated func extractSharedPrice(from url: URL) -> Decimal? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let encoded = components.queryItems?.first(where: { $0.name == "_oak_rec_ext_1" })?.value,
              let decoded = decodeBase64(encoded) else {
            return nil
        }

        if let parsed = PriceCurrencyParser.parse(decoded), parsed.currency == "JPY" {
            return parsed.price
        }

        let normalized = decoded
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Decimal(string: normalized)
    }

    private nonisolated func decodeBase64(_ value: String) -> String? {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: normalized),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }

        return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct SheinProductPriceResolver: Sendable {

    private let session: URLSession

    nonisolated init(session: URLSession) {
        self.session = session
    }

    nonisolated func resolve(for url: URL, html: String) async -> PriceResult? {
        guard isSheinURL(url),
              let goodsID = extractGoodsID(from: url) else {
            return nil
        }

        let csrfToken = extractCSRFToken(from: html)

        if let realtimeURL = makeRealtimeURL(for: url, goodsID: goodsID),
           let result = await fetchPrice(from: realtimeURL, referer: url, csrfToken: csrfToken) {
            return result
        }

        if let staticURL = makeStaticURL(for: url, goodsID: goodsID),
           let result = await fetchPrice(from: staticURL, referer: url, csrfToken: csrfToken) {
            return result
        }

        return nil
    }

    private nonisolated func isSheinURL(_ url: URL) -> Bool {
        url.host?.lowercased().contains("shein.com") == true
    }

    private nonisolated func extractGoodsID(from url: URL) -> String? {
        let path = url.path
        guard let regex = try? NSRegularExpression(pattern: #"-p-(\d+)\.html$"#),
              let match = regex.firstMatch(
                in: path,
                range: NSRange(path.startIndex..., in: path)
              ),
              let range = Range(match.range(at: 1), in: path) else {
            return nil
        }

        return String(path[range])
    }

    private nonisolated func extractCSRFToken(from html: String) -> String? {
        let patterns = [
            #""csrf_token"\s*:\s*"([^"]+)""#,
            #"csrf_token\s*=\s*"([^"]+)""#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: html,
                    range: NSRange(html.startIndex..., in: html)
                  ),
                  let range = Range(match.range(at: 1), in: html) else {
                continue
            }

            let token = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                return token
            }
        }

        return nil
    }

    private nonisolated func makeRealtimeURL(for url: URL, goodsID: String) -> URL? {
        let flags = sheinDetailFlags(from: url)
        let mallCode = queryValue(named: "mallCode", in: url) ?? ""
        let hideEstimatePriceInfo = sheinCampaignFlag(from: url)

        return makeURL(
            path: "/bff-api/product/get_goods_detail_realtime_data",
            from: url,
            queryItems: [
                URLQueryItem(name: "priorityMallType", value: flags.priorityMallType),
                URLQueryItem(name: "goods_id", value: goodsID),
                URLQueryItem(name: "mallCode", value: mallCode),
                URLQueryItem(name: "isUserSelectedMallCode", value: "0"),
                URLQueryItem(name: "sourceFrom", value: "goods_detail"),
                URLQueryItem(name: "isQueryIsPaidMember", value: "1"),
                URLQueryItem(name: "isQueryCanTrail", value: "0"),
                URLQueryItem(name: "isHideEstimatePriceInfo", value: hideEstimatePriceInfo),
                URLQueryItem(name: "specialSceneType", value: hideEstimatePriceInfo),
                URLQueryItem(name: "billno", value: ""),
                URLQueryItem(name: "isAppointMall", value: ""),
                URLQueryItem(name: "sceneFlag", value: "")
            ]
        )
    }

    private nonisolated func makeStaticURL(for url: URL, goodsID: String) -> URL? {
        let flags = sheinDetailFlags(from: url)
        let mallCode = queryValue(named: "mallCode", in: url) ?? ""
        let hideEstimatePriceInfo = sheinCampaignFlag(from: url)

        return makeURL(
            path: "/bff-api/product/get_goods_detail_static_data_v2",
            from: url,
            queryItems: [
                URLQueryItem(name: "priorityMallType", value: flags.priorityMallType),
                URLQueryItem(name: "goods_id", value: goodsID),
                URLQueryItem(name: "mall_code", value: mallCode),
                URLQueryItem(name: "isAppointMall", value: ""),
                URLQueryItem(name: "isHideEstimatePriceInfo", value: hideEstimatePriceInfo),
                URLQueryItem(name: "specialSceneType", value: hideEstimatePriceInfo),
                URLQueryItem(name: "sceneFlag", value: ""),
                URLQueryItem(name: "showSkcSquareImg", value: flags.showSkcSquareImg)
            ]
        )
    }

    private nonisolated func makeURL(
        path: String,
        from url: URL,
        queryItems: [URLQueryItem]
    ) -> URL? {
        var components = URLComponents()
        components.scheme = url.scheme ?? "https"
        components.host = url.host
        components.path = path
        components.queryItems = queryItems
        return components.url
    }

    private nonisolated func queryValue(named name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    private nonisolated func sheinCampaignFlag(from url: URL) -> String {
        let names = ["landing_page_id", "url_from", "ad_type"]
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return queryItems.contains(where: { names.contains($0.name) }) ? "1" : "0"
    }

    private nonisolated func sheinDetailFlags(from url: URL) -> (
        priorityMallType: String,
        showSkcSquareImg: String
    ) {
        guard let rawValue = queryValue(named: "detailBusinessFrom", in: url),
              let decoded = rawValue.removingPercentEncoding else {
            return ("", "0")
        }

        var priorityMallType = ""
        var showSkcSquareImg = "0"

        for token in decoded.split(separator: "|") {
            let parts = token.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            let value = parts.count > 1 ? String(parts[1]) : "1"

            switch key {
            case "0-2":
                priorityMallType = value
            case "0-3":
                showSkcSquareImg = value
            default:
                continue
            }
        }

        return (priorityMallType, showSkcSquareImg)
    }

    private nonisolated func fetchPrice(
        from endpointURL: URL,
        referer: URL,
        csrfToken: String?
    ) async -> PriceResult? {
        var request = URLRequest(url: endpointURL)
        request.timeoutInterval = 15
        request.httpMethod = "GET"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(HTMLFetcher.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(
            "\(referer.scheme ?? "https")://\(referer.host ?? "m.shein.com")",
            forHTTPHeaderField: "Origin"
        )

        if let csrfToken, !csrfToken.isEmpty {
            request.setValue(csrfToken, forHTTPHeaderField: "X-CSRF-Token")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let root = try? JSONSerialization.jsonObject(with: data) else {
                return nil
            }

            return extractPreferredPrice(from: root)
        } catch {
            return nil
        }
    }

    private nonisolated func extractPreferredPrice(from node: Any) -> PriceResult? {
        if let dict = node as? [String: Any] {
            let preferredKeys: [(String, Double)] = [
                ("salePrice", 0.99),
                ("sale_price", 0.99),
                ("currentPrice", 0.98),
                ("current_price", 0.98),
                ("priceInfo", 0.97),
                ("price_info", 0.97),
                ("specialPrice", 0.97),
                ("special_price", 0.97)
            ]

            for (key, confidence) in preferredKeys {
                if let value = dict[key],
                   let result = buildPriceResult(from: value, confidence: confidence) {
                    return result
                }
            }

            let ignoredSubtrees: Set<String> = [
                "retailPrice",
                "retail_price",
                "discountPrice",
                "discount_price",
                "estimatedPriceInfo",
                "estimated_price_info",
                "unitPrice",
                "unit_price",
                "suggestedSalePrice",
                "suggested_sale_price",
                "suggestedSalePriceInfo",
                "suggested_sale_price_info"
            ]

            for (key, value) in dict where !ignoredSubtrees.contains(key) {
                if let result = extractPreferredPrice(from: value) {
                    return result
                }
            }

            return nil
        }

        if let array = node as? [Any] {
            for value in array {
                if let result = extractPreferredPrice(from: value) {
                    return result
                }
            }
        }

        return nil
    }

    private nonisolated func buildPriceResult(from value: Any, confidence: Double) -> PriceResult? {
        guard let price = decimal(from: value) else { return nil }

        return PriceResult(
            price: price,
            currency: "JPY",
            extractMethod: .siteAPI,
            confidence: confidence
        )
    }

    private nonisolated func decimal(from value: Any) -> Decimal? {
        switch value {
        case let decimal as Decimal:
            return decimal
        case let number as NSNumber:
            return Decimal(string: number.stringValue)
        case let string as String:
            if let parsed = PriceCurrencyParser.parse(string), parsed.currency == "JPY" {
                return parsed.price
            }
            return Decimal(string: string.replacingOccurrences(of: ",", with: ""))
        case let dict as [String: Any]:
            if let amount = dict["amount"] {
                return decimal(from: amount)
            }
            if let amountWithSymbol = dict["amountWithSymbol"] {
                return decimal(from: amountWithSymbol)
            }
            if let value = dict["value"] {
                return decimal(from: value)
            }
            if let price = dict["price"] {
                return decimal(from: price)
            }
            return nil
        default:
            return nil
        }
    }
}
