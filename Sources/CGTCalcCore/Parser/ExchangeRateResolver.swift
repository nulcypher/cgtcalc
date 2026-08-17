import Foundation

// MARK: - Exchange Rate Resolver

/// Resolves missing exchange rates in parsed input data by fetching from the Frankfurter API.
/// Transactions and asset events that have a currency but no rate will have rates fetched
/// and their prices/values converted to GBP.
public enum ExchangeRateResolver {
  /// Resolves any missing exchange rates in the parsed input data.
  /// - Parameter inputData: Parsed input rows, some of which may have currency without rate.
  /// - Returns: Input data with all rates resolved and amounts converted to GBP.
  public static func resolve(_ inputData: [InputData]) throws -> [InputData] {
    // Collect all needed rate lookups
    var needed: [(from: String, to: String, date: Date)] = []

    for item in inputData {
      switch item {
      case .transaction(let t):
        if t.originalCurrency != nil, t.exchangeRate == nil {
          needed.append((from: t.originalCurrency!, to: "GBP", date: t.date))
        }
      case .assetEvent(let e):
        if e.originalCurrency != nil, e.exchangeRate == nil {
          needed.append((from: e.originalCurrency!, to: "GBP", date: e.date))
        }
      }
    }

    guard !needed.isEmpty else { return inputData }

    // Deduplicate requests
    var seen = Set<ExchangeRateProvider.CacheKey>()
    var uniqueNeeded: [(from: String, to: String, date: Date)] = []
    for req in needed {
      let dateStr = self.formatDate(req.date)
      let key = ExchangeRateProvider.CacheKey(from: req.from, to: req.to, date: dateStr)
      if seen.insert(key).inserted {
        uniqueNeeded.append(req)
      }
    }

    // Fetch all needed rates
    let rates = try ExchangeRateProvider.fetchRates(requests: uniqueNeeded)

    // Apply rates to input data
    return try inputData.map { item in
      switch item {
      case .transaction(let t):
        guard let currency = t.originalCurrency, t.exchangeRate == nil else { return item }
        let dateStr = self.formatDate(t.date)
        let key = ExchangeRateProvider.CacheKey(from: currency, to: "GBP", date: dateStr)
        guard let rate = rates[key] else {
          throw ExchangeRateError.noData(from: currency, to: "GBP", date: dateStr)
        }
        let convertedPrice = (t.originalPrice ?? t.price) * rate
        let convertedExpenses = (t.originalExpenses ?? t.expenses) * rate
        return .transaction(Transaction(
          id: t.id,
          sourceOrder: t.sourceOrder,
          type: t.type,
          date: t.date,
          asset: t.asset,
          quantity: t.quantity,
          price: convertedPrice,
          expenses: convertedExpenses,
          explicitTotalCost: t.explicitTotalCost,
          explicitTotalValue: t.explicitTotalValue,
          originalCurrency: currency,
          exchangeRate: rate,
          originalPrice: t.originalPrice ?? t.price,
          originalExpenses: t.originalExpenses ?? t.expenses))

      case .assetEvent(let e):
        guard let currency = e.originalCurrency, e.exchangeRate == nil else { return item }
        let dateStr = self.formatDate(e.date)
        let key = ExchangeRateProvider.CacheKey(from: currency, to: "GBP", date: dateStr)
        guard let rate = rates[key] else {
          throw ExchangeRateError.noData(from: currency, to: "GBP", date: dateStr)
        }
        let originalValue = e.originalValue ?? e.distributionValue
        let convertedValue = originalValue * rate
        return .assetEvent(try AssetEvent(
          id: e.id,
          sourceOrder: e.sourceOrder,
          type: e.type,
          date: e.date,
          asset: e.asset,
          distributionAmount: e.distributionAmount,
          distributionValue: convertedValue,
          originalCurrency: currency,
          exchangeRate: rate,
          originalValue: originalValue))
      }
    }
  }

  private static func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.calendar = UTC.calendar
    formatter.timeZone = UTC.timeZone
    return formatter.string(from: date)
  }
}
