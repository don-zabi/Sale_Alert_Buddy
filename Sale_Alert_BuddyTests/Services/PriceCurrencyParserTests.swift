import Testing
import Foundation
@testable import Sale_Alert_Buddy

struct PriceCurrencyParserTests {

    // MARK: - JPY Formats

    @Test func jpyWithYenSuffix() {
        let result = PriceCurrencyParser.parse("1,980円")
        #expect(result != nil)
        #expect(result!.price == Decimal(1980))
        #expect(result!.currency == "JPY")
    }

    @Test func jpyWithYenSymbolPrefix() {
        let result = PriceCurrencyParser.parse("¥1,980")
        #expect(result != nil)
        #expect(result!.price == Decimal(1980))
        #expect(result!.currency == "JPY")
    }

    @Test func jpyWithFullWidthYenSymbol() {
        let result = PriceCurrencyParser.parse("￥1,980")
        #expect(result != nil)
        #expect(result!.price == Decimal(1980))
        #expect(result!.currency == "JPY")
    }

    @Test func jpyNoComma() {
        let result = PriceCurrencyParser.parse("1980円")
        #expect(result != nil)
        #expect(result!.price == Decimal(1980))
        #expect(result!.currency == "JPY")
    }

    @Test func jpyYenSymbolNoComma() {
        let result = PriceCurrencyParser.parse("¥1980")
        #expect(result != nil)
        #expect(result!.price == Decimal(1980))
        #expect(result!.currency == "JPY")
    }

    @Test func jpyLargeAmountWithCommas() {
        let result = PriceCurrencyParser.parse("¥1,234,567")
        #expect(result != nil)
        #expect(result!.price == Decimal(1234567))
        #expect(result!.currency == "JPY")
    }

    @Test func jpyEmbeddedInJapaneseText() {
        let result = PriceCurrencyParser.parse(" 特価: ¥1,980（税込）")
        #expect(result != nil)
        #expect(result!.price == Decimal(1980))
        #expect(result!.currency == "JPY")
    }

    @Test func jpyEmbeddedInText() {
        let result = PriceCurrencyParser.parse("Sale price: ¥2,500 only today")
        #expect(result != nil)
        #expect(result!.price == Decimal(2500))
        #expect(result!.currency == "JPY")
    }

    // MARK: - USD Formats

    @Test func usdDollarSign() {
        let result = PriceCurrencyParser.parse("$19.99")
        #expect(result != nil)
        #expect(result!.price == Decimal(string: "19.99")!)
        #expect(result!.currency == "USD")
    }

    @Test func usdCodePrefix() {
        let result = PriceCurrencyParser.parse("USD 19.99")
        #expect(result != nil)
        #expect(result!.price == Decimal(string: "19.99")!)
        #expect(result!.currency == "USD")
    }

    @Test func usdCodeSuffix() {
        let result = PriceCurrencyParser.parse("19.99 USD")
        #expect(result != nil)
        #expect(result!.price == Decimal(string: "19.99")!)
        #expect(result!.currency == "USD")
    }

    @Test func usdWithThousandsSeparator() {
        let result = PriceCurrencyParser.parse("$1,299.99")
        #expect(result != nil)
        #expect(result!.price == Decimal(string: "1299.99")!)
        #expect(result!.currency == "USD")
    }

    @Test func usdWholeNumber() {
        let result = PriceCurrencyParser.parse("$100")
        #expect(result != nil)
        #expect(result!.price == Decimal(100))
        #expect(result!.currency == "USD")
    }

    // MARK: - EUR Formats

    @Test func eurEuroSign() {
        let result = PriceCurrencyParser.parse("€29.99")
        #expect(result != nil)
        #expect(result!.price == Decimal(string: "29.99")!)
        #expect(result!.currency == "EUR")
    }

    @Test func eurCodePrefix() {
        let result = PriceCurrencyParser.parse("EUR 29.99")
        #expect(result != nil)
        #expect(result!.price == Decimal(string: "29.99")!)
        #expect(result!.currency == "EUR")
    }

    @Test func eurEuropeanDecimalFormat() {
        // European format: comma as decimal separator
        let result = PriceCurrencyParser.parse("29,99 EUR")
        #expect(result != nil)
        #expect(result!.price == Decimal(string: "29.99")!)
        #expect(result!.currency == "EUR")
    }

    @Test func eurPeriodDecimalFormat() {
        let result = PriceCurrencyParser.parse("29.99 EUR")
        #expect(result != nil)
        #expect(result!.price == Decimal(string: "29.99")!)
        #expect(result!.currency == "EUR")
    }

    @Test func eurEuroSignEuropeanFormat() {
        let result = PriceCurrencyParser.parse("€29,99")
        #expect(result != nil)
        #expect(result!.price == Decimal(string: "29.99")!)
        #expect(result!.currency == "EUR")
    }

    // MARK: - GBP Formats

    @Test func gbpPoundSign() {
        let result = PriceCurrencyParser.parse("£19.99")
        #expect(result != nil)
        #expect(result!.price == Decimal(string: "19.99")!)
        #expect(result!.currency == "GBP")
    }

    @Test func gbpCodePrefix() {
        let result = PriceCurrencyParser.parse("GBP 19.99")
        #expect(result != nil)
        #expect(result!.price == Decimal(string: "19.99")!)
        #expect(result!.currency == "GBP")
    }

    // MARK: - Nil / No Currency

    @Test func plainNumberWithoutCurrencyReturnsNil() {
        let result = PriceCurrencyParser.parse("1980")
        #expect(result == nil)
    }

    @Test func plainDecimalWithoutCurrencyReturnsNil() {
        let result = PriceCurrencyParser.parse("1,980.00")
        #expect(result == nil)
    }

    @Test func emptyStringReturnsNil() {
        let result = PriceCurrencyParser.parse("")
        #expect(result == nil)
    }

    @Test func textOnlyReturnsNil() {
        let result = PriceCurrencyParser.parse("Price not available")
        #expect(result == nil)
    }

    @Test func dashReturnsNil() {
        let result = PriceCurrencyParser.parse("—")
        #expect(result == nil)
    }

    // MARK: - Zero Handling (PriceValidator rejects, parser accepts)

    @Test func zeroPriceIsReturnedByParser() {
        // Parser should return (0, currency); PriceValidator is responsible for rejection
        let result = PriceCurrencyParser.parse("$0")
        #expect(result != nil)
        #expect(result!.price == Decimal(0))
        #expect(result!.currency == "USD")
    }

    @Test func zeroJpyIsReturnedByParser() {
        let result = PriceCurrencyParser.parse("¥0")
        #expect(result != nil)
        #expect(result!.price == Decimal(0))
        #expect(result!.currency == "JPY")
    }
}
