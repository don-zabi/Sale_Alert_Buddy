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

            if (!window.__saleAlertPreviewCollectPriceCandidates) {
                return "";
            }

            var candidates = window.__saleAlertPreviewCollectPriceCandidates(digits);
            if (!candidates || !candidates.length) {
                return "";
            }

            return JSON.stringify(candidates.slice(0, 12));
        })();
        """
    }

    static func standaloneVisiblePriceProbeScript(priceDigits: String?) -> String {
        let digits = escapeForJavaScript(priceDigits ?? "")
        return """
        (function() {
            var digits = "\(digits)";
            window.__saleAlertPreviewPriceDigits = digits;
            if (window.__saleAlertPreviewSanitize) {
                window.__saleAlertPreviewSanitize();
            }

            if (!window.__saleAlertPreviewCollectPriceCandidates) {
                return "";
            }

            var candidates = window.__saleAlertPreviewCollectPriceCandidates(digits);
            if (!candidates || !candidates.length) {
                return "";
            }

            return JSON.stringify(candidates.slice(0, 12));
        })();
        """
    }

    static func postLoadScript(priceDigits: String?, preferredAnchorPath: String? = nil) -> String {
        let digits = escapeForJavaScript(priceDigits ?? "")
        let anchorPath = escapeForJavaScript(preferredAnchorPath ?? "")
        return """
        (function() {
            var digits = "\(digits)";
            var preferredAnchorPath = "\(anchorPath)";
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

            var best = null;
            if (preferredAnchorPath && window.__saleAlertPreviewResolveElementByPath) {
                var exact = window.__saleAlertPreviewResolveElementByPath(preferredAnchorPath);
                if (exact) {
                    best = window.__saleAlertPreviewPickPriceCandidate(digits, exact);
                }
            }
            if (!best) {
                best = window.__saleAlertPreviewPickPriceCandidate(digits);
            }
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

    static func pointSelectionScript(pointX: CGFloat, pointY: CGFloat) -> String {
        return """
        (function() {
            if (window.__saleAlertPreviewSanitize) {
                window.__saleAlertPreviewSanitize();
            }

            if (!window.__saleAlertPreviewPickPriceCandidateNearPoint) {
                return "";
            }

            var candidate = window.__saleAlertPreviewPickPriceCandidateNearPoint(\(pointX), \(pointY));
            if (!candidate) {
                return "";
            }

            return JSON.stringify(candidate);
        })();
        """
    }

    private static func escapeForJavaScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    static func parseVisiblePriceCandidates(from payload: String?) -> [PriceCandidate] {
        RenderedVisiblePriceCandidateParser.parseCandidates(from: payload)
    }

    static func parseVisiblePriceResult(from payload: String?) -> PriceResult? {
        RenderedVisiblePriceCandidateParser.parseBestResult(from: payload)
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

        function splitClassNames(el) {
            return String(el.className || '')
                .split(/\s+/)
                .filter(Boolean)
                .slice(0, 12);
        }

        function ancestorTokens(el) {
            var tokens = [];
            var node = el;
            for (var depth = 0; depth < 7 && node; depth++) {
                var values = [
                    node.tagName || '',
                    node.id || '',
                    String(node.className || ''),
                    node.getAttribute ? (node.getAttribute('aria-label') || '') : '',
                    node.getAttribute ? (node.getAttribute('data-testid') || '') : '',
                    node.getAttribute ? (node.getAttribute('role') || '') : ''
                ];

                for (var i = 0; i < values.length; i++) {
                    var normalizedValue = normalized(values[i]);
                    if (!normalizedValue) {
                        continue;
                    }

                    var parts = normalizedValue.split(/[^a-z0-9\u3040-\u30ff\u3400-\u9fff-]+/).filter(Boolean);
                    if (!parts.length) {
                        parts = [normalizedValue];
                    }

                    for (var j = 0; j < parts.length; j++) {
                        if (tokens.indexOf(parts[j]) === -1) {
                            tokens.push(parts[j]);
                        }
                    }
                    if (tokens.indexOf(normalizedValue) === -1) {
                        tokens.push(normalizedValue);
                    }
                }
                node = node.parentElement;
            }
            return tokens.slice(0, 32);
        }

        function buildDomPath(el) {
            var parts = [];
            var node = el;
            while (node && node.nodeType === 1) {
                var tag = (node.tagName || '').toLowerCase();
                if (!tag) {
                    break;
                }
                var index = 1;
                var sibling = node;
                while ((sibling = sibling.previousElementSibling)) {
                    if ((sibling.tagName || '').toLowerCase() === tag) {
                        index += 1;
                    }
                }
                parts.push(tag + ':nth-of-type(' + index + ')');
                if (tag === 'html') {
                    break;
                }
                node = node.parentElement;
            }
            return parts.reverse().join(' > ');
        }

        function distanceBetweenRects(a, b) {
            if (!a || !b) {
                return null;
            }
            var ax = a.left + (a.width / 2);
            var ay = a.top + (a.height / 2);
            var bx = b.left + (b.width / 2);
            var by = b.top + (b.height / 2);
            var dx = ax - bx;
            var dy = ay - by;
            return Math.sqrt(dx * dx + dy * dy);
        }

        function collectReferenceNodes(selector, pattern, limit) {
            var nodes = Array.prototype.slice.call(document.querySelectorAll(selector || ''));
            return nodes.filter(function(node) {
                var text = normalized([
                    node.innerText || node.textContent || '',
                    node.id || '',
                    String(node.className || ''),
                    node.getAttribute ? (node.getAttribute('aria-label') || '') : ''
                ].join(' '));
                if (!text) {
                    return false;
                }
                return !pattern || pattern.test(text);
            }).slice(0, limit || 8);
        }

        function serializeCandidate(candidate) {
            return {
                text: candidate.text || '',
                digits: candidate.digits || '',
                score: candidate.score || 0,
                contextBefore: candidate.contextBefore || '',
                contextAfter: candidate.contextAfter || '',
                domPath: candidate.domPath || '',
                tagName: candidate.tagName || '',
                id: candidate.id || '',
                classNames: candidate.classNames || [],
                ancestorTokens: candidate.ancestorTokens || [],
                top: candidate.top || 0,
                left: candidate.left || 0,
                width: candidate.width || 0,
                height: candidate.height || 0,
                fontSize: candidate.fontSize || 0,
                fontWeight: candidate.fontWeight || 0,
                display: candidate.display || '',
                visibility: candidate.visibility || '',
                opacity: candidate.opacity == null ? 1 : candidate.opacity,
                distanceToTitle: candidate.distanceToTitle == null ? null : candidate.distanceToTitle,
                distanceToBuyButton: candidate.distanceToBuyButton == null ? null : candidate.distanceToBuyButton,
                distanceToCartArea: candidate.distanceToCartArea == null ? null : candidate.distanceToCartArea,
                isVisible: !!candidate.isVisible,
                isAboveTheFold: !!candidate.isAboveTheFold,
                sameAmountNodeCount: candidate.sameAmountNodeCount || 1
            };
        }

        function clearCandidateHighlight(attributeName) {
            var selector = '[' + attributeName + '="1"]';
            var previous = document.querySelector(selector);
            if (!previous) {
                return;
            }
            previous.removeAttribute(attributeName);
            previous.style.removeProperty('background-color');
            previous.style.removeProperty('outline');
            previous.style.removeProperty('border-radius');
            previous.style.removeProperty('box-shadow');
        }

        function highlightCandidateElement(el, attributeName) {
            if (!el) {
                return;
            }
            clearCandidateHighlight(attributeName);
            el.setAttribute(attributeName, '1');
            el.style.setProperty('background-color', '#FFE082', 'important');
            el.style.setProperty('outline', '3px solid #FB8C00', 'important');
            el.style.setProperty('border-radius', '4px', 'important');
            el.style.setProperty('box-shadow', '0 0 0 4px rgba(251, 140, 0, 0.16)', 'important');
            el.scrollIntoView({ block: 'center', inline: 'nearest' });
        }

        function buildCandidate(el, targetDigits, titleNodes, buyNodes) {
            if (!el || !el.tagName) {
                return null;
            }

            var style = window.getComputedStyle(el);
            if (style.display === 'none' || style.visibility === 'hidden') {
                return null;
            }

            var rect = el.getBoundingClientRect();
            if (!rect || rect.width < 1 || rect.height < 1) {
                return null;
            }

            var text = shortText(el.innerText || el.textContent, 160);
            if (!text) {
                return null;
            }

            var nodeDigits = digitsOnly(text);
            var hasPreferredMatch = targetDigits ? nodeDigits.indexOf(targetDigits) !== -1 : false;
            if (targetDigits && !hasPreferredMatch) {
                return null;
            }

            var priceLike = looksLikePriceText(text);
            if (!targetDigits && !priceLike) {
                return null;
            }

            var contextBefore = shortText(el.previousElementSibling ? (el.previousElementSibling.innerText || el.previousElementSibling.textContent) : '', 80);
            var contextAfter = shortText(el.nextElementSibling ? (el.nextElementSibling.innerText || el.nextElementSibling.textContent) : '', 80);
            var context = normalized([
                elementText(el),
                contextBefore,
                contextAfter,
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
            if (rect.top >= 0 && rect.top <= window.innerHeight * 0.72) {
                score += 44;
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

            var distanceToTitle = null;
            for (var i = 0; i < titleNodes.length; i++) {
                var titleRect = titleNodes[i].getBoundingClientRect();
                var titleDistance = distanceBetweenRects(rect, titleRect);
                if (titleDistance != null && (distanceToTitle == null || titleDistance < distanceToTitle)) {
                    distanceToTitle = titleDistance;
                }
            }

            var distanceToBuyButton = null;
            for (var j = 0; j < buyNodes.length; j++) {
                var buyRect = buyNodes[j].getBoundingClientRect();
                var buyDistance = distanceBetweenRects(rect, buyRect);
                if (buyDistance != null && (distanceToBuyButton == null || buyDistance < distanceToBuyButton)) {
                    distanceToBuyButton = buyDistance;
                }
            }

            if (distanceToTitle != null && distanceToTitle <= 240) {
                score += 120;
            } else if (distanceToTitle != null && distanceToTitle <= 420) {
                score += 56;
            }

            if (distanceToBuyButton != null && distanceToBuyButton <= 240) {
                score += 140;
            } else if (distanceToBuyButton != null && distanceToBuyButton <= 420) {
                score += 64;
            }

            return {
                element: el,
                text: text,
                digits: nodeDigits,
                score: score,
                contextBefore: contextBefore,
                contextAfter: contextAfter,
                domPath: buildDomPath(el),
                tagName: (el.tagName || '').toLowerCase(),
                id: el.id || '',
                classNames: splitClassNames(el),
                ancestorTokens: ancestorTokens(el),
                top: rect.top,
                left: rect.left,
                width: rect.width,
                height: rect.height,
                fontSize: isNaN(fontSize) ? 0 : fontSize,
                fontWeight: isNaN(fontWeight) ? 0 : fontWeight,
                display: style.display || '',
                visibility: style.visibility || '',
                opacity: parseFloat(style.opacity || '1'),
                distanceToTitle: distanceToTitle,
                distanceToBuyButton: distanceToBuyButton,
                distanceToCartArea: distanceToBuyButton,
                isVisible: true,
                isAboveTheFold: rect.top >= 0 && rect.top <= window.innerHeight * 0.8,
                sameAmountNodeCount: 1
            };
        }

        function collectCandidateObjects(preferredDigits, preferredElement) {
            var targetDigits = digitsOnly(preferredDigits || trackedPriceDigits());
            var titleNodes = collectReferenceNodes(
                'h1, [itemprop="name"], [class*="title"], [id*="title"], [class*="product-name"], [class*="productName"]',
                null,
                6
            );
            var buyNodes = collectReferenceNodes(
                'button, input[type="submit"], input[type="button"], a[role="button"], [class*="cart"], [id*="cart"], [class*="buy"], [id*="buy"], [class*="purchase"], [id*="purchase"]',
                purchasePattern,
                10
            );
            var nodes = document.querySelectorAll(priceCandidateSelector);
            var candidates = [];
            var counts = {};

            for (var i = 0; i < nodes.length; i++) {
                var candidate = buildCandidate(nodes[i], targetDigits, titleNodes, buyNodes);
                if (!candidate) {
                    continue;
                }
                candidates.push(candidate);
                counts[candidate.digits] = (counts[candidate.digits] || 0) + 1;
            }

            for (var j = 0; j < candidates.length; j++) {
                candidates[j].sameAmountNodeCount = counts[candidates[j].digits] || 1;
                if (candidates[j].sameAmountNodeCount > 4) {
                    candidates[j].score -= Math.min((candidates[j].sameAmountNodeCount - 4) * 18, 120);
                }
                if (preferredElement && candidates[j].element === preferredElement) {
                    candidates[j].score += 460;
                }
            }

            candidates.sort(function(a, b) { return b.score - a.score; });
            return candidates.slice(0, 12);
        }

        function distanceFromPointToRect(x, y, rect) {
            if (!rect) {
                return Number.MAX_SAFE_INTEGER;
            }
            var dx = 0;
            if (x < rect.left) {
                dx = rect.left - x;
            } else if (x > rect.right) {
                dx = x - rect.right;
            }

            var dy = 0;
            if (y < rect.top) {
                dy = rect.top - y;
            } else if (y > rect.bottom) {
                dy = y - rect.bottom;
            }

            if (dx === 0 && dy === 0) {
                return 0;
            }

            return Math.sqrt(dx * dx + dy * dy);
        }

        function pickCandidateNearPoint(x, y) {
            var titleNodes = collectReferenceNodes(
                'h1, [itemprop="name"], [class*="title"], [id*="title"], [class*="product-name"], [class*="productName"]',
                null,
                6
            );
            var buyNodes = collectReferenceNodes(
                'button, input[type="submit"], input[type="button"], a[role="button"], [class*="cart"], [id*="cart"], [class*="buy"], [id*="buy"], [class*="purchase"], [id*="purchase"]',
                purchasePattern,
                10
            );
            var pointedElement = document.elementFromPoint(x, y);
            var nodes = document.querySelectorAll(priceCandidateSelector);
            var candidates = [];
            var counts = {};

            for (var i = 0; i < nodes.length; i++) {
                var candidate = buildCandidate(nodes[i], '', titleNodes, buyNodes);
                if (!candidate) {
                    continue;
                }

                var rect = candidate.element.getBoundingClientRect();
                var distance = distanceFromPointToRect(x, y, rect);
                if (distance <= 0) {
                    candidate.score += 560;
                } else {
                    candidate.score += Math.max(0, 260 - distance);
                }

                if (pointedElement) {
                    if (candidate.element === pointedElement) {
                        candidate.score += 320;
                    } else if (candidate.element.contains(pointedElement) || pointedElement.contains(candidate.element)) {
                        candidate.score += 220;
                    }
                }

                candidates.push(candidate);
                counts[candidate.digits] = (counts[candidate.digits] || 0) + 1;
            }

            for (var j = 0; j < candidates.length; j++) {
                candidates[j].sameAmountNodeCount = counts[candidates[j].digits] || 1;
                if (candidates[j].sameAmountNodeCount > 4) {
                    candidates[j].score -= Math.min((candidates[j].sameAmountNodeCount - 4) * 18, 120);
                }
            }

            candidates.sort(function(a, b) { return b.score - a.score; });
            return candidates.length ? candidates[0] : null;
        }

        window.__saleAlertPreviewCollectPriceCandidates = function(preferredDigits) {
            return collectCandidateObjects(preferredDigits, null).map(serializeCandidate);
        };

        window.__saleAlertPreviewPickPriceCandidate = function(preferredDigits, preferredElement) {
            var candidates = collectCandidateObjects(preferredDigits, preferredElement);
            return candidates.length ? candidates[0] : null;
        };

        window.__saleAlertPreviewPickPriceCandidateNearPoint = function(x, y) {
            var best = pickCandidateNearPoint(x, y);
            if (!best || !best.element) {
                clearCandidateHighlight('data-sale-alert-preview-picked');
                return null;
            }

            highlightCandidateElement(best.element, 'data-sale-alert-preview-picked');
            return serializeCandidate(best);
        };

        window.__saleAlertPreviewResolveElementByPath = function(path) {
            if (!path) {
                return null;
            }
            try {
                return document.querySelector(path);
            } catch (error) {
                return null;
            }
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
