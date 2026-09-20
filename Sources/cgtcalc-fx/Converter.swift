import Foundation

// MARK: - Date helper

enum FXDate {
  /// Converts a cgtcalc DD/MM/YYYY row date to the ISO YYYY-MM-DD used by the
  /// cache and rate sources.
  static func iso(fromRowDate ddmmyyyy: String) -> String? {
    let parts = ddmmyyyy.split(separator: "/")
    guard parts.count == 3, parts[0].count == 2, parts[1].count == 2, parts[2].count == 4 else {
      return nil
    }
    return "\(parts[2])-\(parts[1])-\(parts[0])"
  }
}

// MARK: - Converter

enum ConverterError: Error, LocalizedError {
  case missingRates([(date: String, currency: String)])
  case badDate(line: Int, raw: String)

  var errorDescription: String? {
    switch self {
    case .missingRates(let pairs):
      let list = pairs.map { "  \($0.currency) \($0.date)" }.joined(separator: "\n")
      return "Missing exchange rates for the following (currency, date) pairs. "
        + "Re-run with --fetch to obtain them, or add them to the cache:\n\(list)"
    case .badDate(let line, let raw):
      return "Line \(line): could not parse date from row: '\(raw)'"
    }
  }
}

struct Converter {
  /// Number of decimal places emitted for converted GBP amounts.
  static let outputScale = 6

  /// Converts parsed source lines to GBP output text using `cache`. In explicit
  /// mode `fetch` is nil; in fetch mode `fetch` supplies (and the caller caches)
  /// any missing rates. Returns the output text and the possibly-updated cache.
  static func convert(
    lines: [SourceLine],
    cache: RateCache,
    fetch: ((_ currency: String, _ isoDate: String) throws -> CachedRate)?) throws
    -> (output: String, cache: RateCache)
  {
    var cache = cache

    // 1. Collect the distinct (isoDate, currency) pairs actually needed (dedupe).
    var needed = Set<RateCache.Key>()
    for (index, line) in lines.enumerated() {
      guard case .row(let tokens, let indices) = line, !indices.isEmpty else { continue }
      guard let iso = FXDate.iso(fromRowDate: tokens[1]) else {
        throw ConverterError.badDate(line: index + 1, raw: tokens.joined(separator: " "))
      }
      for i in indices {
        let mt = try SourceParser.parseMonetaryToken(tokens[i], line: index + 1)
        if mt.isGBP { continue }
        needed.insert(RateCache.Key(date: iso, currency: mt.currency))
      }
    }

    // 2. Resolve missing rates.
    var missing: [(date: String, currency: String)] = []
    for key in needed where cache.rate(date: key.date, currency: key.currency) == nil {
      if let fetch {
        let fetched = try fetch(key.currency, key.date)
        try cache.add(fetched)
      } else {
        missing.append((date: key.date, currency: key.currency))
      }
    }
    if !missing.isEmpty {
      // Deterministic ordering for the error message.
      missing.sort { $0.date != $1.date ? $0.date < $1.date : $0.currency < $1.currency }
      throw ConverterError.missingRates(missing)
    }

    // 3. Emit converted output.
    var out: [String] = []
    for (index, line) in lines.enumerated() {
      switch line {
      case .passthrough(let raw):
        out.append(raw)
      case .row(var tokens, let indices):
        if !indices.isEmpty {
          let iso = FXDate.iso(fromRowDate: tokens[1])!
          for i in indices {
            let mt = try SourceParser.parseMonetaryToken(tokens[i], line: index + 1)
            if mt.isGBP {
              tokens[i] = mt.originalNumberText // pass through bare/GBP as-is
            } else {
              let rate = cache.rate(date: iso, currency: mt.currency)! // resolved above
              let gbp = mt.amount * rate
              tokens[i] = Self.format(gbp)
            }
          }
        }
        out.append(tokens.joined(separator: " "))
      }
    }
    return (out.joined(separator: "\n") + "\n", cache)
  }

  private static func format(_ value: Decimal) -> String {
    var v = value
    var rounded = Decimal()
    NSDecimalRound(&rounded, &v, Self.outputScale, .plain)
    return NSDecimalNumber(decimal: rounded).stringValue
  }
}
