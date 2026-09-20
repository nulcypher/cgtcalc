@testable import cgtcalc_fx
import XCTest

final class ConverterTests: XCTestCase {
  private func cacheWith(_ rates: [(String, String, Decimal)]) throws -> RateCache {
    var c = RateCache()
    for (date, ccy, rate) in rates {
      try c.add(CachedRate(date: date, currency: ccy, rate: rate, source: "ECB", fetchedOn: "2026-09-20"))
    }
    return c
  }

  func testConvertsForeignBuyRow() throws {
    let lines = try SourceParser.parse("BUY 15/01/2020 AMZN.NYSE 6 USD1437.86 USD7.78")
    let cache = try cacheWith([("2020-01-15", "USD", Decimal(string: "0.76892")!)])
    let (out, _) = try Converter.convert(lines: lines, cache: cache, fetch: nil)
    // 1437.86 * 0.76892 = 1105.6668...; 7.78 * 0.76892 = 5.9822...
    XCTAssertTrue(out.contains("BUY 15/01/2020 AMZN.NYSE 6 "))
    let price = Decimal(string: "1437.86")! * Decimal(string: "0.76892")!
    let exp = Decimal(string: "7.78")! * Decimal(string: "0.76892")!
    XCTAssertTrue(out.contains(price.description.prefix(6)) || out.contains("1105."))
    XCTAssertTrue(out.contains("5.98"))
    _ = exp
  }

  func testGBPTokensPassThroughUnchanged() throws {
    let lines = try SourceParser.parse("BUY 01/01/2020 LON:FOO 100 GBP1.50 20")
    let (out, _) = try Converter.convert(lines: lines, cache: RateCache(), fetch: nil)
    // Bare 20 and GBP1.50 both stay as their numeric text; no rate needed.
    XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines),
                   "BUY 01/01/2020 LON:FOO 100 1.50 20")
  }

  func testMixedCurrencyRow() throws {
    let lines = try SourceParser.parse("BUY 10/02/2021 AMZN.NYSE 4 USD3162.00 GBP9.95")
    let cache = try cacheWith([("2021-02-10", "USD", Decimal(string: "0.5")!)])
    let (out, _) = try Converter.convert(lines: lines, cache: cache, fetch: nil)
    // USD3162 * 0.5 = 1581; GBP9.95 stays 9.95
    XCTAssertTrue(out.contains("1581"))
    XCTAssertTrue(out.contains("9.95"))
  }

  func testCommentsAndSplitPreserved() throws {
    let src = "# hello\nSPLIT 06/06/2022 AMZN.NYSE 20\nSPOUSEOUT 13/03/2025 AMZN.NYSE 200"
    let lines = try SourceParser.parse(src)
    let (out, _) = try Converter.convert(lines: lines, cache: RateCache(), fetch: nil)
    XCTAssertTrue(out.contains("# hello"))
    XCTAssertTrue(out.contains("SPLIT 06/06/2022 AMZN.NYSE 20"))
    XCTAssertTrue(out.contains("SPOUSEOUT 13/03/2025 AMZN.NYSE 200"))
  }

  func testExplicitModeFailsOnMissingRate() throws {
    let lines = try SourceParser.parse("SELL 25/07/2023 UBSG.SIX 346 CHF18.86 CHF34.26")
    XCTAssertThrowsError(try Converter.convert(lines: lines, cache: RateCache(), fetch: nil)) { error in
      guard case ConverterError.missingRates(let pairs) = error else {
        return XCTFail("expected missingRates, got \(error)")
      }
      // One unique (date, currency) pair despite two CHF tokens on the row (deduped).
      XCTAssertEqual(pairs.count, 1)
      XCTAssertEqual(pairs[0].currency, "CHF")
      XCTAssertEqual(pairs[0].date, "2023-07-25")
    }
  }

  func testFetchModeFillsAndCachesMissingRates() throws {
    let lines = try SourceParser.parse("SELL 25/07/2023 UBSG.SIX 346 CHF18.86 CHF34.26")
    var fetchCalls = 0
    let (out, cache) = try Converter.convert(lines: lines, cache: RateCache()) { currency, isoDate in
      fetchCalls += 1
      XCTAssertEqual(currency, "CHF")
      XCTAssertEqual(isoDate, "2023-07-25")
      return CachedRate(date: isoDate, currency: currency, rate: Decimal(string: "0.9")!, source: "TEST", fetchedOn: "2026-09-20")
    }
    // Two CHF tokens, same (date,currency) -> fetched once (dedupe).
    XCTAssertEqual(fetchCalls, 1)
    // 18.86 * 0.9 = 16.974 ; 34.26 * 0.9 = 30.834
    XCTAssertTrue(out.contains("16.974"))
    XCTAssertTrue(out.contains("30.834"))
    // Rate is now cached with its provenance.
    XCTAssertEqual(cache.rate(date: "2023-07-25", currency: "CHF"), Decimal(string: "0.9"))
  }
}
