import Foundation
import WebKit

enum WebPreviewSanitizer {

    static let mobileSafariUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
        "Version/17.0 Mobile/15E148 Safari/604.1"

    static func configure(_ configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: bootstrapScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
    }

    static func readinessScript(priceDigits: String) -> String {
        let digits = escapeForJavaScript(priceDigits)
        return """
        (function() {
            var digits = "\(digits)";
            window.__saleAlertPreviewPriceDigits = digits;
            if (window.__saleAlertPreviewSanitize) {
                window.__saleAlertPreviewSanitize();
            }

            var body = document.body;
            if (!body) {
                return false;
            }

            if (window.__saleAlertPreviewPickPriceCandidate) {
                var best = window.__saleAlertPreviewPickPriceCandidate(digits);
                if (best) {
                    return true;
                }
            }

            var text = (body.innerText || '').trim();
            return text.length > 120 || document.images.length > 0;
        })();
        """
    }

    static func visiblePriceProbeScript(priceDigits: String?) -> String {
        let digits = escapeForJavaScript(priceDigits ?? "")
        return """
        (function() {
            var digits = "\(digits)";
            window.__saleAlertPreviewPriceDigits = digits;
            if (window.__saleAlertPreviewSanitize) {
                window.__saleAlertPreviewSanitize();
            }

            if (!window.__saleAlertPreviewPickPriceCandidate) {
                return "";
            }

            var best = window.__saleAlertPreviewPickPriceCandidate(digits);
            if (!best) {
                return "";
            }

            return JSON.stringify({
                text: best.text || '',
                digits: best.digits || '',
                score: best.score || 0,
                context: best.context || '',
                top: best.top || 0,
                height: best.height || 0,
                isFixedAncestor: !!best.isFixedAncestor,
                id: best.id || '',
                className: best.className || '',
                parentClassName: best.parentClassName || ''
            });
        })();
        """
    }

    static func standaloneVisiblePriceProbeScript(priceDigits: String?) -> String {
        let digits = escapeForJavaScript(priceDigits ?? "")
        return #"""
        (function() {
            var preferredDigits = "\#(digits)";
            var purchasePattern = /(buy now|add to cart|checkout|shop now|purchase|order now|cart|basket|bag|購入|今すぐ購入|カートに入れる|カートへ|注文|予約|レジに進む|購入手続き|ご購入|申し込|お支払い)/i;
            var utilityPattern = /(cookie|consent|chat|support|help|coupon|promo|campaign|drawer|banner|modal|popup|dialog|floating|sticky)/i;
            var positivePattern = /(price|sale|current|selling|special|offer|amount|cost|販売価格|価格|税込|特価|セール価格|現金特価|値引|割引|現在価格)/i;
            var negativePattern = /(point|reward|list|original|usual|regular|reference|compare|shipping|tax excluded|ポイント|還元|希望小売価格|通常価格|参考価格|メーカー希望小売価格|送料|税抜|付与予定)/i;
            var sectionNegativePattern = /(recommend|recommended|related|ranking|review|history|recent|pickup|banner|campaign|coupon|suggest|similar|favorite|おすすめ|関連|ランキング|レビュー|閲覧履歴|履歴|特集|キャンペーン|クーポン|お気に入り)/i;
            var overlayPattern = /(floating|sticky|header|footer|toolbar|drawer|sheet|dock|summary|quick|cart|checkout|bottom|topbanner)/i;
            var priceCandidateSelector = [
                'span', 'div', 'p', 'strong', 'b', 'em', 'label', 'td', 'li', 'dd', 'dt',
                '[class*="price"]', '[id*="price"]', '[data-price]', '[data-sale-price]',
                '[class*="sale"]', '[id*="sale"]', '[class*="amount"]', '[id*="amount"]',
                '[data-testid*="price"]'
            ].join(',');

            function normalized(value) {
                return String(value || '').toLowerCase().replace(/\s+/g, ' ').trim();
            }

            function shortText(value, limit) {
                return String(value || '').replace(/\s+/g, ' ').trim().slice(0, limit || 120);
            }

            function digitsOnly(value) {
                return String(value || '').replace(/\D/g, '');
            }

            function looksLikePriceText(value) {
                return /([¥￥]\s*[\d,]+|[\d,]+円|\$\s*[\d,]+(?:[.,]\d+)?|€\s*[\d,]+(?:[.,]\d+)?|£\s*[\d,]+(?:[.,]\d+)?|\b(?:USD|EUR|GBP)\s*[\d,]+(?:[.,]\d+)?|[\d,]+(?:[.,]\d+)?\s*(?:USD|EUR|GBP)\b)/i.test(String(value || ''));
            }

            function elementText(el) {
                return normalized([
                    el.innerText,
                    el.textContent,
                    el.getAttribute('aria-label'),
                    el.getAttribute('title'),
                    el.getAttribute('href'),
                    el.getAttribute('value'),
                    el.id,
                    String(el.className || ''),
                    el.getAttribute('data-testid'),
                    el.getAttribute('name')
                ].join(' '));
            }

            function isInteractiveControl(el) {
                if (!el || !el.tagName) {
                    return false;
                }

                var tag = el.tagName.toLowerCase();
                var role = (el.getAttribute('role') || '').toLowerCase();
                return tag === 'button' ||
                    tag === 'input' ||
                    tag === 'select' ||
                    tag === 'textarea' ||
                    tag === 'a' ||
                    role === 'button' ||
                    role === 'link';
            }

            function hasFixedAncestor(el) {
                var node = el;
                for (var depth = 0; depth < 5 && node; depth++) {
                    var style = window.getComputedStyle(node);
                    if (style.position === 'fixed' || style.position === 'sticky') {
                        return true;
                    }
                    node = node.parentElement;
                }
                return false;
            }

            function ancestorContext(el) {
                var parts = [];
                var node = el;
                for (var depth = 0; depth < 5 && node; depth++) {
                    parts.push(
                        node.tagName || '',
                        node.id || '',
                        String(node.className || ''),
                        node.getAttribute ? (node.getAttribute('role') || '') : '',
                        node.getAttribute ? (node.getAttribute('data-testid') || '') : ''
                    );
                    node = node.parentElement;
                }
                return parts.join(' ');
            }

            function nearbyText(el) {
                var parts = [];

                if (el.previousElementSibling) {
                    parts.push(shortText(el.previousElementSibling.innerText || el.previousElementSibling.textContent, 80));
                }
                if (el.nextElementSibling) {
                    parts.push(shortText(el.nextElementSibling.innerText || el.nextElementSibling.textContent, 80));
                }
                if (el.parentElement) {
                    parts.push(shortText(el.parentElement.innerText || el.parentElement.textContent, 120));
                    var label = el.parentElement.querySelector('th,dt,.label,[class*="label"],[class*="ttl"],[class*="title"]');
                    if (label) {
                        parts.push(shortText(label.innerText || label.textContent, 80));
                    }
                }

                return parts.join(' ');
            }

            var targetDigits = digitsOnly(preferredDigits);
            var nodes = document.querySelectorAll(priceCandidateSelector);
            var best = null;
            var bestScore = -1000000;

            for (var i = 0; i < nodes.length; i++) {
                var el = nodes[i];
                if (!el || !el.tagName) {
                    continue;
                }

                var style = window.getComputedStyle(el);
                if (style.display === 'none' || style.visibility === 'hidden') {
                    continue;
                }

                var rect = el.getBoundingClientRect();
                if (!rect || rect.width < 1 || rect.height < 1) {
                    continue;
                }

                var text = shortText(el.innerText || el.textContent, 160);
                if (!text) {
                    continue;
                }

                var nodeDigits = digitsOnly(text);
                var hasPreferredMatch = targetDigits ? nodeDigits.indexOf(targetDigits) !== -1 : false;
                if (targetDigits && !hasPreferredMatch) {
                    continue;
                }

                var priceLike = looksLikePriceText(text);
                if (!targetDigits && !priceLike) {
                    continue;
                }

                var context = normalized([
                    elementText(el),
                    nearbyText(el),
                    ancestorContext(el)
                ].join(' '));

                var score = 1000 - text.length;
                if (hasPreferredMatch) {
                    score += nodeDigits === targetDigits ? 320 : 180;
                } else if (priceLike) {
                    score += 120;
                }
                if (/[¥￥円$€£]/.test(text)) {
                    score += 120;
                }
                if (positivePattern.test(text) || positivePattern.test(context)) {
                    score += 180;
                }
                if (negativePattern.test(text) || negativePattern.test(context)) {
                    score -= 260;
                }
                if (sectionNegativePattern.test(context)) {
                    score -= 340;
                }
                if (overlayPattern.test(context)) {
                    score -= 240;
                }
                if (purchasePattern.test(text) || purchasePattern.test(context)) {
                    score -= 220;
                }
                if (utilityPattern.test(context)) {
                    score -= 90;
                }
                if (hasFixedAncestor(el)) {
                    score -= 280;
                }
                if (el.closest('header, footer, nav, aside, dialog, [aria-modal="true"]')) {
                    score -= 200;
                }
                if (el.closest('main, article, section')) {
                    score += 40;
                }
                if (el.children.length === 0) {
                    score += 50;
                }
                if (rect.top >= 0 && rect.top <= window.innerHeight * 0.65) {
                    score += 40;
                } else if (rect.top > window.innerHeight * 1.15) {
                    score -= 60;
                }
                if (rect.width >= window.innerWidth * 0.8 && rect.height < 34) {
                    score -= 60;
                }
                if (style.textDecorationLine && style.textDecorationLine.indexOf('line-through') !== -1) {
                    score -= 160;
                }
                if (text.indexOf('%') !== -1) {
                    score -= 40;
                }

                var fontSize = parseFloat(style.fontSize || '0');
                if (!isNaN(fontSize)) {
                    if (fontSize >= 24) {
                        score += 110;
                    } else if (fontSize >= 18) {
                        score += 60;
                    } else if (fontSize >= 14) {
                        score += 18;
                    }
                }

                var fontWeight = parseInt(style.fontWeight || '0', 10);
                if (!isNaN(fontWeight) && fontWeight >= 600) {
                    score += 24;
                }

                if (score > bestScore) {
                    bestScore = score;
                    best = {
                        text: text,
                        digits: nodeDigits,
                        score: score,
                        context: context,
                        top: rect.top,
                        height: rect.height,
                        isFixedAncestor: hasFixedAncestor(el),
                        id: el.id || '',
                        className: String(el.className || ''),
                        parentClassName: el.parentElement ? String(el.parentElement.className || '') : '',
                        isInteractive: isInteractiveControl(el)
                    };
                }
            }

            if (!best) {
                return "";
            }

            return JSON.stringify(best);
        })();
        """#
    }

    static func postLoadScript(priceDigits: String?) -> String {
        let digits = escapeForJavaScript(priceDigits ?? "")
        return """
        (function() {
            var digits = "\(digits)";
            window.__saleAlertPreviewPriceDigits = digits;
            if (window.__saleAlertPreviewSanitize) {
                window.__saleAlertPreviewSanitize();
            }

            var previousBest = document.querySelector('[data-sale-alert-preview-best="1"]');
            if (previousBest) {
                previousBest.removeAttribute('data-sale-alert-preview-best');
            }

            if (!window.__saleAlertPreviewPickPriceCandidate) {
                return false;
            }

            var best = window.__saleAlertPreviewPickPriceCandidate(digits);
            if (!best || !best.element) {
                window.__saleAlertPreviewDebug = null;
                window.scrollTo({ top: 0, behavior: 'auto' });
                return false;
            }

            best.element.setAttribute('data-sale-alert-preview-best', '1');
            best.element.style.setProperty('background-color', '#FFF176', 'important');
            best.element.style.setProperty('outline', '2px solid #FF9800', 'important');
            best.element.style.setProperty('border-radius', '4px', 'important');
            window.__saleAlertPreviewDebug = {
                text: best.text || '',
                digits: best.digits || '',
                className: best.className || '',
                id: best.id || '',
                score: best.score || 0,
                context: best.context || ''
            };
            best.element.scrollIntoView({ block: 'center', inline: 'nearest' });
            return true;
        })();
        """
    }

    private static func escapeForJavaScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    static func parseVisiblePriceResult(from payload: String?) -> PriceResult? {
        guard let payload,
              let data = payload.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = raw["text"] as? String,
              let parsed = PriceCurrencyParser.parse(text) else {
            return nil
        }

        let score = raw["score"] as? Double ?? 0
        let clampedScore = min(max(score, 0), 1500)
        let confidence = min(0.90, max(0.70, 0.70 + (clampedScore / 10_000)))
        return PriceResult(
            price: parsed.price,
            currency: parsed.currency,
            extractMethod: .renderedVisible,
            confidence: confidence
        )
    }

    private static let bootstrapScript = #"""
    (function() {
        if (window.__saleAlertPreviewBootstrapped) {
            return;
        }
        window.__saleAlertPreviewBootstrapped = true;
        window.__saleAlertPreviewPriceDigits = window.__saleAlertPreviewPriceDigits || '';

        var purchasePattern = /(buy now|add to cart|checkout|shop now|purchase|order now|cart|basket|bag|購入|今すぐ購入|カートに入れる|カートへ|注文|予約|レジに進む|購入手続き|ご購入|申し込|お支払い)/i;
        var utilityPattern = /(cookie|consent|chat|support|help|coupon|promo|campaign|drawer|banner|modal|popup|dialog|floating|sticky)/i;
        var positivePattern = /(price|sale|current|selling|special|offer|amount|cost|販売価格|価格|税込|特価|セール価格|現金特価|値引|割引|現在価格)/i;
        var negativePattern = /(point|reward|list|original|usual|regular|reference|compare|shipping|tax excluded|ポイント|還元|希望小売価格|通常価格|参考価格|メーカー希望小売価格|送料|税抜|付与予定)/i;
        var sectionNegativePattern = /(recommend|recommended|related|ranking|review|history|recent|pickup|banner|campaign|coupon|suggest|similar|favorite|おすすめ|関連|ランキング|レビュー|閲覧履歴|履歴|特集|キャンペーン|クーポン|お気に入り)/i;
        var overlayPattern = /(floating|sticky|header|footer|toolbar|drawer|sheet|dock|summary|quick|cart|checkout|bottom|topbanner)/i;
        var priceCandidateSelector = [
            'span', 'div', 'p', 'strong', 'b', 'em', 'label', 'td', 'li', 'dd', 'dt',
            '[class*="price"]', '[id*="price"]', '[data-price]', '[data-sale-price]',
            '[class*="sale"]', '[id*="sale"]', '[class*="amount"]', '[id*="amount"]',
            '[data-testid*="price"]'
        ].join(',');

        function normalized(value) {
            return String(value || '').toLowerCase().replace(/\s+/g, ' ').trim();
        }

        function shortText(value, limit) {
            return String(value || '').replace(/\s+/g, ' ').trim().slice(0, limit || 120);
        }

        function digitsOnly(value) {
            return String(value || '').replace(/\D/g, '');
        }

        function trackedPriceDigits() {
            return digitsOnly(window.__saleAlertPreviewPriceDigits || '');
        }

        function looksLikePriceText(value) {
            return /([¥￥]\s*[\d,]+|[\d,]+円|\$\s*[\d,]+(?:[.,]\d+)?|€\s*[\d,]+(?:[.,]\d+)?|£\s*[\d,]+(?:[.,]\d+)?|\b(?:USD|EUR|GBP)\s*[\d,]+(?:[.,]\d+)?|[\d,]+(?:[.,]\d+)?\s*(?:USD|EUR|GBP)\b)/i.test(String(value || ''));
        }

        function elementText(el) {
            return normalized([
                el.innerText,
                el.textContent,
                el.getAttribute('aria-label'),
                el.getAttribute('title'),
                el.getAttribute('href'),
                el.getAttribute('value'),
                el.id,
                String(el.className || ''),
                el.getAttribute('data-testid'),
                el.getAttribute('name')
            ].join(' '));
        }

        function containsTrackedPrice(el) {
            if (!el || !el.tagName) {
                return false;
            }

            var digits = trackedPriceDigits();
            if (!digits) {
                return false;
            }

            var text = digitsOnly([
                el.innerText,
                el.textContent,
                el.getAttribute('aria-label'),
                el.getAttribute('title')
            ].join(' '));
            return text.indexOf(digits) !== -1;
        }

        function isInteractiveControl(el) {
            if (!el || !el.tagName) {
                return false;
            }

            var tag = el.tagName.toLowerCase();
            var role = (el.getAttribute('role') || '').toLowerCase();
            return tag === 'button' ||
                tag === 'input' ||
                tag === 'select' ||
                tag === 'textarea' ||
                tag === 'a' ||
                role === 'button' ||
                role === 'link';
        }

        function hasFixedAncestor(el) {
            var node = el;
            for (var depth = 0; depth < 5 && node; depth++) {
                var style = window.getComputedStyle(node);
                if (style.position === 'fixed' || style.position === 'sticky') {
                    return true;
                }
                node = node.parentElement;
            }
            return false;
        }

        function ancestorContext(el) {
            var parts = [];
            var node = el;
            for (var depth = 0; depth < 5 && node; depth++) {
                parts.push(
                    node.tagName || '',
                    node.id || '',
                    String(node.className || ''),
                    node.getAttribute ? (node.getAttribute('role') || '') : '',
                    node.getAttribute ? (node.getAttribute('data-testid') || '') : ''
                );
                node = node.parentElement;
            }
            return parts.join(' ');
        }

        function nearbyText(el) {
            var parts = [];

            if (el.previousElementSibling) {
                parts.push(shortText(el.previousElementSibling.innerText || el.previousElementSibling.textContent, 80));
            }
            if (el.nextElementSibling) {
                parts.push(shortText(el.nextElementSibling.innerText || el.nextElementSibling.textContent, 80));
            }

            if (el.parentElement) {
                parts.push(shortText(el.parentElement.innerText || el.parentElement.textContent, 120));
                var label = el.parentElement.querySelector('th,dt,.label,[class*="label"],[class*="ttl"],[class*="title"]');
                if (label) {
                    parts.push(shortText(label.innerText || label.textContent, 80));
                }
            }

            return parts.join(' ');
        }

        function installStyle() {
            if (document.getElementById('__saleAlertPreviewStyle')) {
                return;
            }

            var style = document.createElement('style');
            style.id = '__saleAlertPreviewStyle';
            style.textContent = [
                'html, body { overscroll-behavior: contain !important; }',
                'a, button, input, select, textarea, [role="button"], [role="link"] { pointer-events: none !important; }',
                '[data-sale-alert-preview-hidden="1"] { display: none !important; visibility: hidden !important; }'
            ].join('\n');

            (document.head || document.documentElement).appendChild(style);
        }

        function markHidden(el, allowAncestorPromotion) {
            if (!el || el === document.body || el === document.documentElement) {
                return;
            }
            if (containsTrackedPrice(el)) {
                return;
            }

            var target = el;
            var node = el;

            if (allowAncestorPromotion) {
                for (var depth = 0; depth < 3 && node && node.parentElement; depth++) {
                    var parent = node.parentElement;
                    if (!parent || parent === document.body || parent === document.documentElement) {
                        break;
                    }
                    if (containsTrackedPrice(parent)) {
                        break;
                    }
                    var rect = parent.getBoundingClientRect();
                    var style = window.getComputedStyle(parent);

                    if ((style.position === 'fixed' || style.position === 'sticky') &&
                        rect.height < window.innerHeight * 0.45) {
                        target = parent;
                        break;
                    }

                    if (rect.width >= window.innerWidth * 0.85 &&
                        rect.height >= 36 &&
                        rect.height < window.innerHeight * 0.30 &&
                        parent !== document.body) {
                        target = parent;
                    }

                    node = parent;
                }
            }

            if (containsTrackedPrice(target)) {
                return;
            }
            target.setAttribute('data-sale-alert-preview-hidden', '1');
        }

        function hideReason(el) {
            if (!el || !el.tagName) {
                return '';
            }

            var tag = el.tagName.toLowerCase();
            var style = window.getComputedStyle(el);
            if (style.display === 'none' || style.visibility === 'hidden') {
                return '';
            }

            var rect = el.getBoundingClientRect();
            if (!rect || rect.width < 1 || rect.height < 1) {
                return '';
            }

            var text = elementText(el);
            var position = style.position;
            var looksLikePurchase = purchasePattern.test(text);
            var looksLikeUtility = utilityPattern.test(text);
            var isInteractive = isInteractiveControl(el);
            var isPositionedOverlay = position === 'fixed' || position === 'sticky';
            var isBottomBar = isPositionedOverlay && rect.top > window.innerHeight * 0.45;
            var isTopBanner = isPositionedOverlay && rect.bottom < window.innerHeight * 0.35;
            var isWideBanner = rect.width >= window.innerWidth * 0.85 &&
                rect.height >= 32 &&
                rect.height < window.innerHeight * 0.28;
            var isFloatingBar = isBottomBar || isTopBanner;
            var isDialog = el.getAttribute('aria-modal') === 'true' || tag === 'dialog';
            var isFrame = tag === 'iframe';
            var isUtilityOverlay = looksLikeUtility && (isPositionedOverlay || isWideBanner);
            var isPurchaseOverlay = looksLikePurchase && (isFloatingBar || (isInteractive && isWideBanner));
            var isPurchaseControl = looksLikePurchase && isInteractive;

            if (isDialog) return 'dialog';
            if (isFrame) return 'frame';
            if (isUtilityOverlay) return 'utility-overlay';
            if (isPurchaseOverlay) return 'purchase-overlay';
            if (isPurchaseControl) return 'purchase-control';
            return '';
        }

        function sanitize(root) {
            installStyle();

            var container = root && root.querySelectorAll ? root : document;
            var nodes = container.querySelectorAll(
                'button, a, input, select, textarea, [role="button"], [aria-modal="true"], dialog, iframe, ' +
                '[class*="buy"], [class*="cart"], [class*="checkout"], [class*="cookie"], [class*="chat"], ' +
                '[id*="buy"], [id*="cart"], [id*="checkout"], [id*="cookie"], [id*="chat"]'
            );

            for (var i = 0; i < nodes.length; i++) {
                var reason = hideReason(nodes[i]);
                if (reason) {
                    markHidden(nodes[i], reason !== 'purchase-control');
                }
            }
        }

        window.__saleAlertPreviewPickPriceCandidate = function(preferredDigits) {
            var targetDigits = digitsOnly(preferredDigits || trackedPriceDigits());
            var nodes = document.querySelectorAll(priceCandidateSelector);
            var best = null;
            var bestScore = -1000000;

            for (var i = 0; i < nodes.length; i++) {
                var el = nodes[i];
                if (!el || !el.tagName) {
                    continue;
                }

                var style = window.getComputedStyle(el);
                if (style.display === 'none' || style.visibility === 'hidden') {
                    continue;
                }

                var rect = el.getBoundingClientRect();
                if (!rect || rect.width < 1 || rect.height < 1) {
                    continue;
                }

                var text = shortText(el.innerText || el.textContent, 160);
                if (!text) {
                    continue;
                }

                var nodeDigits = digitsOnly(text);
                var hasPreferredMatch = targetDigits ? nodeDigits.indexOf(targetDigits) !== -1 : false;
                if (targetDigits && !hasPreferredMatch) {
                    continue;
                }

                var priceLike = looksLikePriceText(text);
                if (!targetDigits && !priceLike) {
                    continue;
                }

                var context = normalized([
                    elementText(el),
                    nearbyText(el),
                    ancestorContext(el)
                ].join(' '));

                var score = 1000 - text.length;
                if (hasPreferredMatch) {
                    score += nodeDigits === targetDigits ? 320 : 180;
                } else if (priceLike) {
                    score += 120;
                }

                if (/[¥￥円$€£]/.test(text)) {
                    score += 120;
                }
                if (positivePattern.test(text) || positivePattern.test(context)) {
                    score += 180;
                }
                if (negativePattern.test(text) || negativePattern.test(context)) {
                    score -= 260;
                }
                if (sectionNegativePattern.test(context)) {
                    score -= 340;
                }
                if (overlayPattern.test(context)) {
                    score -= 240;
                }
                if (purchasePattern.test(text) || purchasePattern.test(context)) {
                    score -= 220;
                }
                if (utilityPattern.test(context)) {
                    score -= 90;
                }
                if (hasFixedAncestor(el)) {
                    score -= 280;
                }
                if (el.closest('header, footer, nav, aside, dialog, [aria-modal="true"]')) {
                    score -= 200;
                }
                if (el.closest('main, article, section')) {
                    score += 40;
                }
                if (el.children.length === 0) {
                    score += 50;
                }
                if (rect.top >= 0 && rect.top <= window.innerHeight * 0.65) {
                    score += 40;
                } else if (rect.top > window.innerHeight * 1.15) {
                    score -= 60;
                }
                if (rect.width >= window.innerWidth * 0.8 && rect.height < 34) {
                    score -= 60;
                }
                if (style.textDecorationLine && style.textDecorationLine.indexOf('line-through') !== -1) {
                    score -= 160;
                }
                if (text.indexOf('%') !== -1) {
                    score -= 40;
                }

                var fontSize = parseFloat(style.fontSize || '0');
                if (!isNaN(fontSize)) {
                    if (fontSize >= 24) {
                        score += 110;
                    } else if (fontSize >= 18) {
                        score += 60;
                    } else if (fontSize >= 14) {
                        score += 18;
                    }
                }

                var fontWeight = parseInt(style.fontWeight || '0', 10);
                if (!isNaN(fontWeight) && fontWeight >= 600) {
                    score += 24;
                }

                if (score > bestScore) {
                    bestScore = score;
                    best = {
                        element: el,
                        text: text,
                        digits: nodeDigits,
                        score: score,
                        context: context,
                        top: rect.top,
                        height: rect.height,
                        isFixedAncestor: hasFixedAncestor(el),
                        id: el.id || '',
                        className: String(el.className || ''),
                        parentClassName: el.parentElement ? String(el.parentElement.className || '') : ''
                    };
                }
            }

            return best;
        };

        var pending = false;
        function scheduleSanitize() {
            if (pending) {
                return;
            }

            pending = true;
            requestAnimationFrame(function() {
                pending = false;
                sanitize(document);
            });
        }

        window.__saleAlertPreviewSanitize = function() {
            sanitize(document);
            return true;
        };

        installStyle();
        scheduleSanitize();

        if (document.documentElement) {
            new MutationObserver(function() {
                scheduleSanitize();
            }).observe(document.documentElement, { childList: true, subtree: true });
        }

        document.addEventListener('DOMContentLoaded', scheduleSanitize, { once: true });
        window.addEventListener('load', scheduleSanitize);
    })();
    """#
}
