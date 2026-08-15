import Foundation

// MARK: - Transaction Types

public enum TransactionType: String {
  case buy = "BUY"
  case sell = "SELL"
  case spouseIn = "SPOUSEIN"
  case spouseOut = "SPOUSEOUT"

  public var isAcquisition: Bool {
    switch self {
    case .buy, .spouseIn:
      true
    case .sell, .spouseOut:
      false
    }
  }

  public var isTaxableDisposal: Bool {
    self == .sell
  }

  public var isSpouseTransferOut: Bool {
    self == .spouseOut
  }
}

// MARK: - Transaction

public struct Transaction: Identifiable {
  public let id: UUID
  public let sourceOrder: Int?
  public let type: TransactionType
  public let date: Date
  public let asset: String
  public let quantity: Decimal
  public let price: Decimal
  public let expenses: Decimal
  /// Exact acquisition cost supplied independently of a per-unit price, used by lossless spouse handoffs.
  public let explicitTotalCost: Decimal?
  /// Exact total trade value retained when a synthetic transaction represents merged source rows.
  public let explicitTotalValue: Decimal?

  /// Original foreign currency label (e.g. "USD"), nil when amounts are already in GBP.
  public let originalCurrency: String?
  /// Exchange rate used to convert to GBP (1 foreign unit = rate GBP), nil when no conversion applied.
  public let exchangeRate: Decimal?
  /// Per-unit price in the original foreign currency before conversion.
  public let originalPrice: Decimal?
  /// Expenses in the original foreign currency before conversion.
  public let originalExpenses: Decimal?

  /// Creates a buy or sell transaction row.
  /// - Parameters:
  ///   - id: Stable identifier for matching and encoding.
  ///   - sourceOrder: Zero-based parsed row order, if known.
  ///   - type: `BUY` or `SELL`.
  ///   - date: Trade date.
  ///   - asset: Asset identifier.
  ///   - quantity: Quantity traded.
  ///   - price: Per-unit trade price (in GBP after any conversion).
  ///   - expenses: Dealing costs for the trade (in GBP after any conversion).
  ///   - originalCurrency: Foreign currency label, if amounts were converted.
  ///   - exchangeRate: Rate used to convert from foreign currency to GBP.
  ///   - originalPrice: Per-unit price in foreign currency before conversion.
  ///   - originalExpenses: Expenses in foreign currency before conversion.
  public init(
    id: UUID = UUID(),
    sourceOrder: Int? = nil,
    type: TransactionType,
    date: Date,
    asset: String,
    quantity: Decimal,
    price: Decimal,
    expenses: Decimal,
    explicitTotalCost: Decimal? = nil,
    explicitTotalValue: Decimal? = nil,
    originalCurrency: String? = nil,
    exchangeRate: Decimal? = nil,
    originalPrice: Decimal? = nil,
    originalExpenses: Decimal? = nil)
  {
    self.id = id
    self.sourceOrder = sourceOrder
    self.type = type
    self.date = date
    self.asset = asset
    self.quantity = quantity
    self.price = price
    self.expenses = expenses
    self.explicitTotalCost = explicitTotalCost
    self.explicitTotalValue = explicitTotalValue
    self.originalCurrency = originalCurrency
    self.exchangeRate = exchangeRate
    self.originalPrice = originalPrice
    self.originalExpenses = originalExpenses
  }

  public var totalValue: Decimal {
    self.explicitTotalValue ?? (self.quantity * self.price)
  }

  public var totalCost: Decimal {
    self.explicitTotalCost ?? (self.totalValue + self.expenses)
  }

  public var proceeds: Decimal {
    // Proceeds = full sale amount (quantity * price)
    // Expenses reduce the gain, not proceeds
    self.totalValue
  }
}

// MARK: - Input Data

public enum InputData {
  case transaction(Transaction)
  case assetEvent(AssetEvent)

  public var date: Date {
    switch self {
    case .transaction(let t): t.date
    case .assetEvent(let e): e.date
    }
  }

  public var asset: String {
    switch self {
    case .transaction(let t): t.asset
    case .assetEvent(let e): e.asset
    }
  }
}
