import Foundation

// MARK: - Monetary token

/// A single whitespace-separated token on a source row that carries a monetary
/// amount, optionally prefixed with a three-letter ISO currency code (e.g.
/// `USD1437.86`). A bare number, or an explicit `GBP` prefix, is treated as GBP.
struct MonetaryToken {
  /// Currency code, uppercased. `GBP` for bare numbers or an explicit GBP prefix.
  let currency: String
  /// The numeric part of the token, as written (no thousands separators expected).
  let amount: Decimal
  /// The original numeric text, so GBP pass-through can be byte-preserving.
  let originalNumberText: String

  var isGBP: Bool { self.currency == "GBP" }
}

// MARK: - Source line

/// A parsed source line. Either a passthrough line (comment, blank, or a row with
/// no convertible fields) or a transaction/event row with identified monetary
/// fields at known token positions.
enum SourceLine {
  /// Emitted verbatim (comments, blank lines).
  case passthrough(String)
  /// A row whose tokens are known; `monetaryFieldIndices` lists which token
  /// positions are monetary and therefore subject to conversion.
  case row(tokens: [String], monetaryFieldIndices: [Int])
}

// MARK: - Source parser

enum SourceParseError: Error, LocalizedError {
  case malformedCurrencyToken(line: Int, token: String)
  case invalidNumber(line: Int, token: String)
  case unknownRowType(line: Int, type: String)

  var errorDescription: String? {
    switch self {
    case .malformedCurrencyToken(let line, let token):
      "Line \(line): malformed currency-prefixed token '\(token)'"
    case .invalidNumber(let line, let token):
      "Line \(line): invalid numeric value '\(token)'"
    case .unknownRowType(let line, let type):
      "Line \(line): unknown row type '\(type)'"
    }
  }
}

enum SourceParser {
  /// Token positions (0-based) that carry monetary amounts, by row type.
  /// Index 0 is the row keyword, index 1 the date, index 2 the asset.
  /// - BUY/SELL:    <TYPE> <DATE> <ASSET> <AMOUNT> <PRICE> <EXPENSES>  -> price(4), expenses(5)
  /// - CAPRETURN/CAPDIST/DIVIDEND: <TYPE> <DATE> <ASSET> <AMOUNT> <VALUE> -> value(4)
  /// - SPOUSEIN/SPOUSEOUT/SPLIT/UNSPLIT/RESTRUCT: no convertible monetary fields.
  private static func monetaryIndices(forType type: String) -> [Int]? {
    switch type {
    case "BUY", "SELL":
      [4, 5]
    case "CAPRETURN", "CAPDIST", "DIVIDEND":
      [4]
    case "SPOUSEIN", "SPOUSEOUT", "SPLIT", "UNSPLIT", "RESTRUCT":
      []
    default:
      nil
    }
  }

  /// Parses a whole source file into lines, preserving comments and blanks.
  static func parse(_ contents: String) throws -> [SourceLine] {
    var result: [SourceLine] = []
    let rawLines = contents.components(separatedBy: .newlines)
    for (index, raw) in rawLines.enumerated() {
      let lineNumber = index + 1
      let trimmed = raw.trimmingCharacters(in: .whitespaces)

      // Preserve comments and blank lines verbatim. Also preserve a trailing
      // empty final line only if it existed; here we simply pass blanks through.
      if trimmed.isEmpty || trimmed.hasPrefix("#") {
        result.append(.passthrough(raw))
        continue
      }

      let tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
      let type = tokens[0]
      guard let indices = self.monetaryIndices(forType: type) else {
        throw SourceParseError.unknownRowType(line: lineNumber, type: type)
      }
      // Only treat indices that actually exist on this row as monetary.
      let presentIndices = indices.filter { $0 < tokens.count }
      result.append(.row(tokens: tokens, monetaryFieldIndices: presentIndices))
    }
    return result
  }

  /// Parses a single monetary token that may carry a leading currency code.
  /// `USD1437.86` -> (USD, 1437.86); `1437.86` or `GBP1437.86` -> (GBP, ...).
  static func parseMonetaryToken(_ token: String, line: Int) throws -> MonetaryToken {
    // Leading currency code: exactly three ASCII letters at the start.
    let prefix = token.prefix(while: { $0.isLetter })
    if prefix.isEmpty {
      // Bare number => GBP.
      guard let value = Decimal(string: token) else {
        throw SourceParseError.invalidNumber(line: line, token: token)
      }
      return MonetaryToken(currency: "GBP", amount: value, originalNumberText: token)
    }
    guard prefix.count == 3 else {
      throw SourceParseError.malformedCurrencyToken(line: line, token: token)
    }
    let numberText = String(token.dropFirst(3))
    guard let value = Decimal(string: numberText) else {
      throw SourceParseError.invalidNumber(line: line, token: token)
    }
    return MonetaryToken(
      currency: prefix.uppercased(),
      amount: value,
      originalNumberText: numberText)
  }
}
