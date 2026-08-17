import Foundation

// MARK: - Exchange Rate Provider

/// Fetches historical exchange rates from the Frankfurter API (ECB reference rates).
/// Rates are cached per session to avoid redundant network calls.
public enum ExchangeRateProvider {
  /// Fetches the exchange rate for a currency pair on a given date.
  /// - Parameters:
  ///   - from: Source currency code (e.g. "USD").
  ///   - to: Target currency code (e.g. "GBP").
  ///   - date: The date to look up.
  /// - Returns: The exchange rate (1 unit of `from` = rate units of `to`).
  public static func fetchRate(from: String, to: String, date: Date) throws -> Decimal {
    let dateStr = self.formatDate(date)
    let key = CacheKey(from: from, to: to, date: dateStr)

    if let cached = self.cache[key] {
      return cached
    }

    let rate = try self.fetchFromAPI(from: from, to: to, date: dateStr)
    self.cache[key] = rate
    return rate
  }

  /// Batch-fetches rates for multiple date/currency combinations, minimizing API calls.
  /// - Parameter requests: Array of (from, to, date) tuples.
  /// - Returns: Dictionary keyed by (from, to, dateString) with the fetched rates.
  public static func fetchRates(requests: [(from: String, to: String, date: Date)]) throws -> [CacheKey: Decimal] {
    var results: [CacheKey: Decimal] = [:]

    for request in requests {
      let dateStr = self.formatDate(request.date)
      let key = CacheKey(from: request.from, to: request.to, date: dateStr)

      if let cached = self.cache[key] {
        results[key] = cached
        continue
      }

      let rate = try self.fetchFromAPI(from: request.from, to: request.to, date: dateStr)
      self.cache[key] = rate
      results[key] = rate
    }

    return results
  }

  /// Clears the rate cache (useful for testing).
  public static func clearCache() {
    self.cache.removeAll()
  }

  // MARK: - Cache

  public struct CacheKey: Hashable {
    public let from: String
    public let to: String
    public let date: String
  }

  nonisolated(unsafe) private static var cache: [CacheKey: Decimal] = [:]

  // MARK: - API

  /// Minimum delay between consecutive API requests to avoid rate limiting.
  private static let requestDelay: TimeInterval = 0.5
  /// Maximum number of retry attempts per request.
  private static let maxRetries = 3
  /// Base delay for exponential backoff on failure (seconds).
  private static let baseBackoff: TimeInterval = 2.0

  nonisolated(unsafe) private static var lastRequestTime: Date = .distantPast

  private static func fetchFromAPI(from: String, to: String, date: String) throws -> Decimal {
    // Polite delay between requests
    let elapsed = Date().timeIntervalSince(self.lastRequestTime)
    if elapsed < self.requestDelay {
      Thread.sleep(forTimeInterval: self.requestDelay - elapsed)
    }

    var lastError: Error?

    for attempt in 0 ..< self.maxRetries {
      if attempt > 0 {
        let backoff = self.baseBackoff * pow(2.0, Double(attempt - 1))
        Thread.sleep(forTimeInterval: backoff)
      }

      self.lastRequestTime = Date()

      do {
        return try self.performRequest(from: from, to: to, date: date)
      } catch {
        lastError = error
        // Only retry on network/timeout errors, not on invalid responses
        if case ExchangeRateError.invalidRate = error { throw error }
      }
    }

    throw lastError ?? ExchangeRateError.noData(from: from, to: "GBP", date: date)
  }

  private static func performRequest(from: String, to: String, date: String) throws -> Decimal {
    let urlString = "https://api.frankfurter.dev/v2/rate/\(from)/\(to)?date=\(date)"
    guard let url = URL(string: urlString) else {
      throw ExchangeRateError.invalidURL(urlString)
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 30

    var responseData: Data?
    var responseError: Error?

    let semaphore = DispatchSemaphore(value: 0)
    let task = URLSession.shared.dataTask(with: request) { data, _, error in
      responseData = data
      responseError = error
      semaphore.signal()
    }
    task.resume()
    semaphore.wait()

    if let error = responseError {
      throw ExchangeRateError.networkError(from: from, to: to, date: date, underlying: error)
    }

    guard let data = responseData else {
      throw ExchangeRateError.noData(from: from, to: to, date: date)
    }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let rate = json["rate"] as? Double
    else {
      throw ExchangeRateError.invalidResponse(
        from: from, to: to, date: date,
        body: String(data: data, encoding: .utf8) ?? "<binary>")
    }

    guard let decimal = Decimal.parse(String(rate)), decimal > 0 else {
      throw ExchangeRateError.invalidRate(from: from, to: to, date: date, value: String(rate))
    }

    return decimal
  }

  // MARK: - Date Formatting

  private static func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.calendar = UTC.calendar
    formatter.timeZone = UTC.timeZone
    return formatter.string(from: date)
  }
}

// MARK: - Errors

public enum ExchangeRateError: Error, LocalizedError {
  case invalidURL(String)
  case networkError(from: String, to: String, date: String, underlying: Error)
  case noData(from: String, to: String, date: String)
  case invalidResponse(from: String, to: String, date: String, body: String)
  case invalidRate(from: String, to: String, date: String, value: String)

  public var errorDescription: String? {
    switch self {
    case .invalidURL(let url):
      "Invalid exchange rate URL: \(url)"
    case .networkError(let from, let to, let date, let error):
      "Failed to fetch \(from)/\(to) rate for \(date): \(error.localizedDescription)"
    case .noData(let from, let to, let date):
      "No data received for \(from)/\(to) rate on \(date)"
    case .invalidResponse(let from, let to, let date, let body):
      "Invalid response for \(from)/\(to) rate on \(date): \(body)"
    case .invalidRate(let from, let to, let date, let value):
      "Invalid rate value for \(from)/\(to) on \(date): \(value)"
    }
  }
}
