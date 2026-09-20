import Foundation

// MARK: - Rate cache

/// A single cached exchange rate. Target currency is always GBP.
/// `rate` is GBP per unit of `currency` (GBP = amount * rate).
struct CachedRate: Equatable {
  let date: String       // YYYY-MM-DD (the transaction/entitlement date requested)
  let currency: String   // ISO 4217, uppercased
  let rate: Decimal
  let source: String     // RateSource identifier that produced it (e.g. "ECB")
  let fetchedOn: String   // YYYY-MM-DD the rate was retrieved
}

enum RateCacheError: Error, LocalizedError {
  case immutableRowChanged(date: String, currency: String, existing: Decimal, incoming: Decimal)
  case malformedLine(Int, String)

  var errorDescription: String? {
    switch self {
    case .immutableRowChanged(let date, let currency, let existing, let incoming):
      "Refusing to overwrite cached rate for \(currency) on \(date): existing \(existing) != incoming \(incoming). The cache is append-only; existing rates are immutable."
    case .malformedLine(let n, let text):
      "Malformed rate cache line \(n): '\(text)'"
    }
  }
}

/// An append-only, git-friendly CSV cache of exchange rates.
/// Columns: date,currency,rate,source,fetched_on. GBP is never stored (rate 1.0).
struct RateCache {
  private(set) var entries: [Key: CachedRate]

  /// Cache identity is `(date, currency)` only — `source` is deliberately NOT part
  /// of the key. Consequences (see "Switching rate source" in cgtcalc-fx-spec.md):
  /// the first source to populate a `(date, currency)` wins permanently; changing
  /// the rate source never re-fetches or alters existing rows, so filed figures are
  /// stable, but it does mean the cache can hold mixed-provenance rows. To adopt a
  /// new source retroactively, delete the cache and re-fetch from scratch (git
  /// preserves the old one); expect only a small restatement delta between
  /// reputable reference-rate sources.
  struct Key: Hashable {
    let date: String
    let currency: String
  }

  init(entries: [Key: CachedRate] = [:]) {
    self.entries = entries
  }

  /// GBP short-circuits to 1.0 with no cache entry.
  func rate(date: String, currency: String) -> Decimal? {
    if currency == "GBP" { return 1 }
    return self.entries[Key(date: date, currency: currency)]?.rate
  }

  /// The distinct `source` identifiers among the currently-stored rows. Used to
  /// warn when a `--fetch` run's selected source differs from the provenance of
  /// rows it is relying on (mixed-provenance detection). GBP is never stored, so
  /// it never contributes a source.
  func distinctSources() -> Set<String> {
    Set(self.entries.values.map(\.source))
  }

  /// Adds a rate, enforcing append-only immutability: if the key already exists
  /// with a different rate, it throws rather than overwriting.
  mutating func add(_ r: CachedRate) throws {
    if currencyIsGBP(r.currency) { return } // never store GBP
    let key = Key(date: r.date, currency: r.currency)
    if let existing = self.entries[key] {
      if existing.rate != r.rate {
        throw RateCacheError.immutableRowChanged(
          date: r.date, currency: r.currency, existing: existing.rate, incoming: r.rate)
      }
      return // identical: no-op
    }
    self.entries[key] = r
  }

  // MARK: Load

  static func load(from url: URL) throws -> RateCache {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return RateCache()
    }
    let text = try String(contentsOf: url, encoding: .utf8)
    var entries: [Key: CachedRate] = [:]
    for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("date,") { continue }
      let cols = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
      guard cols.count == 5, let rate = Decimal(string: cols[2]) else {
        throw RateCacheError.malformedLine(index + 1, raw)
      }
      let entry = CachedRate(
        date: cols[0], currency: cols[1].uppercased(), rate: rate,
        source: cols[3], fetchedOn: cols[4])
      entries[Key(date: entry.date, currency: entry.currency)] = entry
    }
    return RateCache(entries: entries)
  }

  // MARK: Save

  /// Serialises the cache sorted by (date, currency) for stable, minimal diffs.
  func serialised() -> String {
    var out = "# Exchange rate cache for cgtcalc-fx currency preprocessing\n"
    out += "# rate = multiply the foreign amount by this to get GBP (target currency is always GBP)\n"
    out += "# Append-only: existing rows are immutable. Sorted by date,currency.\n"
    out += "date,currency,rate,source,fetched_on\n"
    let sorted = self.entries.values.sorted {
      $0.date != $1.date ? $0.date < $1.date : $0.currency < $1.currency
    }
    for e in sorted {
      out += "\(e.date),\(e.currency),\(e.rate),\(e.source),\(e.fetchedOn)\n"
    }
    return out
  }

  func save(to url: URL) throws {
    try self.serialised().write(to: url, atomically: true, encoding: .utf8)
  }
}

private func currencyIsGBP(_ c: String) -> Bool { c.uppercased() == "GBP" }
