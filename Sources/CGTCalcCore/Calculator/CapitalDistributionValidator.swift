import Foundation

/// Validates general capital distributions (`CAPDIST`) against the available pool cost.
///
/// A `CAPDIST` reduces the Section 104 pool's allowable cost across the whole holding.
/// Under TCGA 1992 s.122, a capital distribution that exceeds the remaining base cost is a
/// part disposal: the excess over cost is a chargeable gain. This tool does not yet compute
/// that excess gain, so a distribution larger than the remaining cost is rejected here rather
/// than silently truncating the cost at zero (which would understate the gain).
///
/// Future enhancement: instead of rejecting, consume the cost down to zero and report the
/// remainder to the user as an amount that must be treated as a chargeable gain. That requires
/// a warnings channel from the calculation through to the report, which does not exist yet.
enum CapitalDistributionValidator {
  static let monetaryTolerance = Decimal.parse("0.0001") ?? Decimal(0)

  static func validate(asset: String, date: Date, value: Decimal, availableCost: Decimal) throws {
    guard value <= availableCost + self.monetaryTolerance else {
      throw CalculationError.unsupportedCapitalDistribution(
        asset: asset,
        date: date,
        value: value,
        availableCost: availableCost)
    }
  }
}
