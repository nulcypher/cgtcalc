import ArgumentParser
import Foundation

private func writeStderr(_ message: String) {
  let line = message.hasSuffix("\n") ? message : message + "\n"
  FileHandle.standardError.write(Data(line.utf8))
}

private func formatError(_ error: Error) -> String {
  (error as? LocalizedError)?.errorDescription ?? String(describing: error)
}

@main
struct CGTCalcFXCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "cgtcalc-fx",
    abstract: "Convert a foreign-currency-annotated cgtcalc source file into GBP-only cgtcalc input.",
    version: "0.1.0")

  @Argument(help: "Source file with currency-prefixed monetary tokens (use '-' for stdin).")
  var filename: String

  @Option(name: .long, help: "Rate cache CSV (date,currency,rate,source,fetched_on).")
  var cache: String = "fx-rates-cache.csv"

  @Flag(name: .long, help: "Fetch and append any missing rates from the rate source.")
  var fetch: Bool = false

  @Option(name: .long, help: "Rate source key. Currently: ECB (Frankfurter).")
  var source: String = "ECB"

  @Option(name: .long, help: "After a successful run, copy the cache to this frozen snapshot path.")
  var snapshot: String?

  @Option(name: .shortAndLong, help: "Output file (default: stdout).")
  var outputFile: String?

  mutating func run() throws {
    // Read source.
    let contents: String
    do {
      if self.filename == "-" {
        contents = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
      } else {
        contents = try String(contentsOf: URL(fileURLWithPath: self.filename), encoding: .utf8)
      }
    } catch {
      writeStderr("Error reading source: \(formatError(error))"); throw ExitCode(1)
    }

    // Parse.
    let lines: [SourceLine]
    do {
      lines = try SourceParser.parse(contents)
    } catch {
      writeStderr("Error parsing source: \(formatError(error))"); throw ExitCode(1)
    }

    // Load cache.
    let cacheURL = URL(fileURLWithPath: self.cache)
    var rateCache: RateCache
    do {
      rateCache = try RateCache.load(from: cacheURL)
    } catch {
      writeStderr("Error loading rate cache: \(formatError(error))"); throw ExitCode(1)
    }

    // Prepare a fetcher if --fetch was given.
    let rateSource = self.makeSource()
    let today = Self.isoToday()

    // Mixed-provenance warning: if we may rely on cached rows whose source differs
    // from the one now selected, make that visible rather than silently blending
    // sources. See "Switching rate source" in cgtcalc-fx-spec.md.
    if self.fetch {
      let otherSources = rateCache.distinctSources().subtracting([rateSource.identifier])
      if !otherSources.isEmpty {
        let list = otherSources.sorted().joined(separator: ", ")
        writeStderr(
          "Warning: rate cache already contains rows from a different source (\(list)) "
          + "than the selected source (\(rateSource.identifier)). Existing rows are used "
          + "as-is and are not re-fetched, so this run may mix sources. To apply "
          + "\(rateSource.identifier) retroactively, delete the cache and start over "
          + "(git preserves the previous cache).")
      }
    }

    let fetcher: ((String, String) throws -> CachedRate)? = self.fetch ? { currency, isoDate in
      let rate = try rateSource.rate(for: currency, on: isoDate)
      return CachedRate(
        date: isoDate, currency: currency, rate: rate,
        source: rateSource.identifier, fetchedOn: today)
    } : nil

    // Convert.
    let result: (output: String, cache: RateCache)
    do {
      result = try Converter.convert(lines: lines, cache: rateCache, fetch: fetcher)
    } catch {
      writeStderr("Error converting: \(formatError(error))"); throw ExitCode(1)
    }

    // Persist cache if it grew (fetch mode). Save is safe: RateCache.add already
    // enforced append-only immutability during conversion.
    if self.fetch {
      do { try result.cache.save(to: cacheURL) }
      catch { writeStderr("Error writing cache: \(formatError(error))"); throw ExitCode(1) }
    }

    // Optional snapshot.
    if let snapshot {
      do { try result.cache.save(to: URL(fileURLWithPath: snapshot)) }
      catch { writeStderr("Error writing snapshot: \(formatError(error))"); throw ExitCode(1) }
    }

    // Emit output.
    if let outputFile {
      do { try result.output.write(toFile: outputFile, atomically: true, encoding: .utf8) }
      catch { writeStderr("Error writing output: \(formatError(error))"); throw ExitCode(1) }
    } else {
      print(result.output, terminator: "")
    }
  }

  private func makeSource() -> RateSource {
    switch self.source.uppercased() {
    case "ECB", "FRANKFURTER":
      FrankfurterRateSource()
    default:
      FrankfurterRateSource()
    }
  }

  private static func isoToday() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(identifier: "UTC")
    return f.string(from: Date())
  }
}
