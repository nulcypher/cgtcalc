import Foundation

// MARK: - RateSource protocol

/// A pluggable source of GBP exchange rates. The built-in default is Frankfurter
/// (ECB reference rates). Conform to add other sources (broker rates, HMRC rates,
/// a manual CSV importer, etc.) without touching the conversion logic.
protocol RateSource {
  /// Stable identifier recorded in the cache `source` column (e.g. "ECB").
  var identifier: String { get }

  /// Fetch the GBP-per-unit rate for `currency` on `date` (YYYY-MM-DD). Sources
  /// map non-trading days to the nearest prior trading day; the requested date is
  /// what gets cached so re-runs are stable.
  func rate(for currency: String, on date: String) throws -> Decimal
}

enum RateSourceError: Error, LocalizedError {
  case invalidURL(String)
  case throttledOrUnavailable(currency: String, date: String)
  case noRate(currency: String, date: String)
  case network(currency: String, date: String, underlying: String)

  var errorDescription: String? {
    switch self {
    case .invalidURL(let u): "Invalid rate URL: \(u)"
    case .throttledOrUnavailable(let c, let d):
      "Rate source throttled or unavailable fetching \(c) on \(d) after retries"
    case .noRate(let c, let d): "No rate available for \(c) on \(d)"
    case .network(let c, let d, let u): "Network error fetching \(c) on \(d): \(u)"
    }
  }
}

// MARK: - Frankfurter (ECB) source

/// Fetches ECB reference rates from the Frankfurter API. Paces requests and
/// retries transient failures with exponential backoff; treats non-JSON bodies
/// (e.g. a Cloudflare 522 page) as failures rather than rates.
final class FrankfurterRateSource: RateSource {
  let identifier = "ECB"

  private let requestSpacing: TimeInterval
  private let maxRetries: Int
  private let baseBackoff: TimeInterval
  nonisolated(unsafe) private var lastRequest: Date = .distantPast

  init(requestSpacing: TimeInterval = 0.2, maxRetries: Int = 3, baseBackoff: TimeInterval = 2.0) {
    self.requestSpacing = requestSpacing
    self.maxRetries = maxRetries
    self.baseBackoff = baseBackoff
  }

  func rate(for currency: String, on date: String) throws -> Decimal {
    var lastError: Error?
    for attempt in 0 ..< self.maxRetries {
      if attempt > 0 {
        Thread.sleep(forTimeInterval: self.baseBackoff * pow(2.0, Double(attempt - 1)))
      }
      // Pace requests.
      let elapsed = Date().timeIntervalSince(self.lastRequest)
      if elapsed < self.requestSpacing {
        Thread.sleep(forTimeInterval: self.requestSpacing - elapsed)
      }
      self.lastRequest = Date()
      do {
        return try self.performRequest(currency: currency, date: date)
      } catch RateSourceError.noRate(let c, let d) {
        throw RateSourceError.noRate(currency: c, date: d) // definitive: don't retry
      } catch {
        lastError = error // transient: retry
      }
    }
    _ = lastError
    throw RateSourceError.throttledOrUnavailable(currency: currency, date: date)
  }

  private func performRequest(currency: String, date: String) throws -> Decimal {
    let urlString = "https://api.frankfurter.dev/v2/rate/\(currency)/GBP?date=\(date)"
    guard let url = URL(string: urlString) else {
      throw RateSourceError.invalidURL(urlString)
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 30

    var data: Data?
    var response: URLResponse?
    var netError: Error?
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { d, r, e in
      data = d; response = r; netError = e; sem.signal()
    }.resume()
    sem.wait()

    if let netError {
      throw RateSourceError.network(currency: currency, date: date, underlying: netError.localizedDescription)
    }
    guard let data else {
      throw RateSourceError.network(currency: currency, date: date, underlying: "no data")
    }
    // Throttle / error pages are HTML, not JSON — treat as transient failure.
    if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
      throw RateSourceError.throttledOrUnavailable(currency: currency, date: date)
    }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw RateSourceError.throttledOrUnavailable(currency: currency, date: date)
    }
    guard let rateDouble = json["rate"] as? Double,
          let value = Decimal(string: String(rateDouble)), value > 0
    else {
      throw RateSourceError.noRate(currency: currency, date: date)
    }
    return value
  }
}
