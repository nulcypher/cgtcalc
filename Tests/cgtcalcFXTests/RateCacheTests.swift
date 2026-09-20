@testable import cgtcalc_fx
import XCTest

final class RateCacheTests: XCTestCase {
  func testGBPShortCircuitsToOne() {
    let cache = RateCache()
    XCTAssertEqual(cache.rate(date: "2020-01-15", currency: "GBP"), 1)
  }

  func testAddAndLookup() throws {
    var cache = RateCache()
    try cache.add(CachedRate(date: "2020-01-15", currency: "USD", rate: Decimal(string: "0.76892")!, source: "ECB", fetchedOn: "2026-09-20"))
    XCTAssertEqual(cache.rate(date: "2020-01-15", currency: "USD"), Decimal(string: "0.76892"))
    XCTAssertNil(cache.rate(date: "2020-01-16", currency: "USD"))
  }

  func testAddIdenticalIsNoOp() throws {
    var cache = RateCache()
    let r = CachedRate(date: "2020-01-15", currency: "USD", rate: 0.7, source: "ECB", fetchedOn: "2026-09-20")
    try cache.add(r)
    XCTAssertNoThrow(try cache.add(r))
  }

  func testAddDifferentRateForExistingKeyThrows() throws {
    var cache = RateCache()
    try cache.add(CachedRate(date: "2020-01-15", currency: "USD", rate: 0.7, source: "ECB", fetchedOn: "2026-09-20"))
    XCTAssertThrowsError(try cache.add(
      CachedRate(date: "2020-01-15", currency: "USD", rate: 0.8, source: "ECB", fetchedOn: "2026-09-21"))) { error in
      guard case RateCacheError.immutableRowChanged = error else {
        return XCTFail("expected immutableRowChanged, got \(error)")
      }
    }
  }

  func testGBPNeverStored() throws {
    var cache = RateCache()
    try cache.add(CachedRate(date: "2020-01-15", currency: "GBP", rate: 1, source: "ECB", fetchedOn: "2026-09-20"))
    XCTAssertTrue(cache.entries.isEmpty)
  }

  func testDistinctSourcesForMismatchWarning() throws {
    var cache = RateCache()
    try cache.add(CachedRate(date: "2020-01-15", currency: "USD", rate: 0.77, source: "ECB", fetchedOn: "2026-09-20"))
    try cache.add(CachedRate(date: "2021-01-15", currency: "USD", rate: 0.73, source: "ECB", fetchedOn: "2026-09-20"))
    try cache.add(CachedRate(date: "2022-01-15", currency: "USD", rate: 0.74, source: "BROKER", fetchedOn: "2026-09-20"))
    XCTAssertEqual(cache.distinctSources(), ["ECB", "BROKER"])
    // A run selecting ECB would flag BROKER as the differing source.
    XCTAssertEqual(cache.distinctSources().subtracting(["ECB"]), ["BROKER"])
  }

  func testSerialisationSortedAndRoundTrips() throws {
    var cache = RateCache()
    try cache.add(CachedRate(date: "2021-05-01", currency: "USD", rate: 0.72, source: "ECB", fetchedOn: "2026-09-20"))
    try cache.add(CachedRate(date: "2020-01-15", currency: "USD", rate: 0.77, source: "ECB", fetchedOn: "2026-09-20"))
    try cache.add(CachedRate(date: "2020-01-15", currency: "CHF", rate: 0.60, source: "ECB", fetchedOn: "2026-09-20"))
    let text = cache.serialised()
    // Sorted by date then currency: CHF/2020, USD/2020, USD/2021.
    let dataLines = text.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.hasPrefix("date,") }
    XCTAssertEqual(dataLines[0], "2020-01-15,CHF,0.6,ECB,2026-09-20")
    XCTAssertEqual(dataLines[1], "2020-01-15,USD,0.77,ECB,2026-09-20")
    XCTAssertEqual(dataLines[2], "2021-05-01,USD,0.72,ECB,2026-09-20")

    // Round-trip through a temp file.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("fxcache_\(UUID()).csv")
    defer { try? FileManager.default.removeItem(at: url) }
    try cache.save(to: url)
    let reloaded = try RateCache.load(from: url)
    XCTAssertEqual(reloaded.rate(date: "2020-01-15", currency: "CHF"), Decimal(string: "0.6"))
    XCTAssertEqual(reloaded.rate(date: "2021-05-01", currency: "USD"), Decimal(string: "0.72"))
  }
}
