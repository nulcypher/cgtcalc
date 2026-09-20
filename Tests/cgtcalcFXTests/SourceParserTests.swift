@testable import cgtcalc_fx
import XCTest

final class SourceParserTests: XCTestCase {
  func testParsesBareNumberAsGBP() throws {
    let mt = try SourceParser.parseMonetaryToken("1437.86", line: 1)
    XCTAssertEqual(mt.currency, "GBP")
    XCTAssertTrue(mt.isGBP)
    XCTAssertEqual(mt.amount, Decimal(string: "1437.86"))
  }

  func testParsesExplicitGBPPrefix() throws {
    let mt = try SourceParser.parseMonetaryToken("GBP20", line: 1)
    XCTAssertEqual(mt.currency, "GBP")
    XCTAssertTrue(mt.isGBP)
    XCTAssertEqual(mt.amount, 20)
  }

  func testParsesForeignPrefix() throws {
    let mt = try SourceParser.parseMonetaryToken("USD1437.86", line: 1)
    XCTAssertEqual(mt.currency, "USD")
    XCTAssertFalse(mt.isGBP)
    XCTAssertEqual(mt.amount, Decimal(string: "1437.86"))
  }

  func testRejectsMalformedPrefix() {
    XCTAssertThrowsError(try SourceParser.parseMonetaryToken("US1437.86", line: 1))
  }

  func testBuyRowHasPriceAndExpensesAsMonetary() throws {
    let lines = try SourceParser.parse("BUY 15/01/2020 AMZN.NYSE 6 USD1437.86 USD7.78")
    guard case .row(_, let indices) = lines[0] else { return XCTFail("expected row") }
    XCTAssertEqual(indices, [4, 5])
  }

  func testCapDistRowHasValueAsMonetary() throws {
    let lines = try SourceParser.parse("CAPDIST 07/05/2012 UBSG.SIX 872 CHF87.20")
    guard case .row(_, let indices) = lines[0] else { return XCTFail("expected row") }
    XCTAssertEqual(indices, [4])
  }

  func testCommentsAndBlanksPassthrough() throws {
    let lines = try SourceParser.parse("# a comment\n\nSPLIT 06/06/2022 AMZN.NYSE 20")
    guard case .passthrough(let c) = lines[0] else { return XCTFail() }
    XCTAssertEqual(c, "# a comment")
    guard case .passthrough = lines[1] else { return XCTFail("blank should passthrough") }
    guard case .row(_, let indices) = lines[2] else { return XCTFail() }
    XCTAssertEqual(indices, [], "SPLIT has no monetary fields")
  }
}
