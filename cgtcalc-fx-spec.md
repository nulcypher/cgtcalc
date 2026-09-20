# cgtcalc-fx — Currency preprocessor specification (draft)

## Status
Approved for implementation. Companion tool to `cgtcalc`; keeps all
currency-conversion concerns out of the CGT engine.

## Purpose
Convert a source transaction file whose monetary amounts may be in foreign
currencies into a clean, GBP-only file that `cgtcalc` consumes unchanged.

Currency conversion is a data-preparation concern, deliberately separated from
the CGT calculation. The engine only ever sees GBP.

Rationale (from experience building this):
- The `cgtcalc` engine should stay single-currency and simple.
- Foreign-currency handling is niche; a preprocessor keeps it optional and out
  of the core.
- ECB reference rates *restate over time* (we observed 82 of 83 historical
  CHF/GBP rates drift between two fetches a month apart). Filed tax figures must
  remain reproducible, so fetched rates must be cached and treated as immutable.

## Non-goals
- Parsing broker PDFs / statements. That is bespoke per broker and per user, and
  is explicitly out of scope (KISS). The preprocessor takes already-extracted
  rows.
- Any change to `cgtcalc`'s own input grammar or engine.

## Language / packaging
A second Swift executable target in the `cgtcalc` package (e.g. `cgtcalc-fx`),
consistent with the existing codebase and reusing its `Decimal`/date parsing.
Upstreamable as an optional tool.

## Source file format
Standard `cgtcalc` rows. Each monetary token may carry a three-letter ISO 4217
currency code as a **prefix, with no space**. A token with no prefix is GBP.

```
BUY     15/01/2020 AMZN.NYSE 6 USD1437.86 USD7.78
SELL    25/07/2023 UBSG.SIX 346 CHF18.86 CHF34.26
CAPDIST 07/05/2012 UBSG.SIX 872 CHF87.20
BUY     10/02/2021 AMZN.NYSE 4 USD3162.00 GBP9.95   # mixed: USD price, GBP dealing fee
BUY     01/01/2020 LON:FOO 100 GBP1.50 GBP20        # explicit GBP prefix
SELL    03/03/2020 LON:FOO 100 1.75 20              # bare numbers = GBP, passed through
# comments and blank lines are preserved
```

Rules:
- The prefix qualifies the individual token, so a single row may mix currencies
  if ever required (each monetary field converts independently at the row date).
- A bare number (no prefix) is GBP. An explicit `GBP` prefix is also accepted and
  is equivalent: it resolves to a rate of 1.0 and is never looked up or fetched.
  This is handy for readability on mixed-currency rows (e.g. `USD1437.86 GBP20`).
- Non-monetary tokens (quantities, SPLIT/UNSPLIT multipliers, RESTRUCT ratios,
  dates, asset names, the `TOTALCOST` keyword) never carry a prefix and are never
  converted.
- `SPOUSEIN ... TOTALCOST <amount>` and `SPOUSEOUT` amounts are GBP cost handoffs
  and are passed through unchanged.
- Comment lines (`#…`) and blank lines are emitted unchanged.
- The conversion target is always GBP (this is a UK CGT tool).

## Conversion rules
For a token `CCC<number>` on a row dated `D`:
1. Resolve the rate `r` for `(D, CCC)` (see Rate resolution).
2. Emit `number * r`, formatted to a fixed 6 decimal places (deterministic,
   parses cleanly in `cgtcalc`).

Fields converted:
- BUY / SELL: `price`, `expenses`.
- CAPRETURN / CAPDIST / DIVIDEND: `value`.
Fields never converted: quantities, multipliers, ratios, TOTALCOST handoffs.

Rate direction convention: `GBP = foreign_amount * rate` (i.e. 1 unit of the
foreign currency = `rate` GBP). Documented in the cache header.

## Rate resolution
- `GBP` (explicit or implied by a bare number) resolves to rate 1.0 with no cache
  entry and no network access.
- For any other currency, look up `(date, currency)` in the cache.
- **Explicit mode (default): fail on miss.** If any required rate is not cached,
  the tool exits non-zero and lists every missing `(date, currency)` pair. It
  performs no network access. This guarantees reproducibility: the same source +
  same cache always produces identical output.
- **Fetch mode (`--fetch`): fetch missing rates** from the configured rate
  source, append them to the cache, then convert. Rates already present are
  never re-fetched and never overwritten.

## Pluggable rate sources
Rate fetching is modular behind a protocol so the built-in default can be swapped
or extended.

```
protocol RateSource {
    /// Stable identifier stored in the cache provenance column (e.g. "ECB").
    var identifier: String { get }
    /// Fetch GBP-per-unit rate for `currency` on `date` (or nearest prior
    /// business day, returning the date actually used).
    func rate(for currency: String, on date: Date) throws -> (rate: Decimal, effectiveDate: Date)
}
```

- **Built-in default: Frankfurter** (ECB reference rates), `identifier = "ECB"`.
- The source is selectable with `--source <key>`; the chosen source's
  `identifier` is written into the cache `source` column for every row it fetches
  (provenance).
- Additional sources (e.g. a broker's own published rates, HMRC monthly/spot
  rates, a manual CSV importer) can be added by conforming to `RateSource`
  without touching the conversion logic.
- Business-day handling: sources map non-trading days to the nearest prior
  trading day; the cache pins the **requested** date to the rate actually used,
  so re-runs are stable.

### Rate source resilience (rate limiting, retries, batching)
Network rate sources may throttle or intermittently fail. This is a property of
the source module, not the conversion logic. The built-in Frankfurter/ECB source
in particular is observed to rate-limit rapid sequential requests and to return
transient 5xx/timeout responses. The `RateSource` implementation therefore must:

- **Pace requests.** Insert a small, configurable delay between consecutive
  fetches. Frankfurter tolerates roughly 0.2s spacing in practice, so the default
  should be around that (not the more conservative 0.5s first tried); expose it as
  a parameter so it can be tuned per source or if throttling behaviour changes.
- **Retry with backoff.** On transient network errors / 5xx / timeouts, retry a
  bounded number of times with exponential backoff; only surface an error after
  retries are exhausted. Do **not** retry on a definitive "no rate" response.
- **De-duplicate and batch.** Resolve the set of distinct `(date, currency)` pairs
  needed for a run and fetch each at most once, so a large source file with many
  rows on the same date makes one request per unique date, not per row.
- **Fail cleanly and partially-safely.** If fetching ultimately fails, any rates
  successfully fetched so far are still appended to the cache (respecting the
  safety rules), so a re-run resumes rather than repeating work; the tool then
  exits non-zero listing the pairs it could not obtain.
- **Detect throttling responses.** Treat HTML/error bodies (e.g. a Cloudflare 522
  page) as failures, not as a rate — never parse a non-JSON body as a rate.

Because the cache makes fetching a one-off cost per `(date, currency)`, these
concerns only bite on first population; subsequent runs read the cache with no
network access.

## Rate cache
Plain, git-friendly CSV. Columns:

```
date,currency,rate,source,fetched_on
2020-01-15,USD,0.76892,ECB,2026-09-20
2012-05-07,CHF,0.67241,ECB,2026-09-20
```

- `date`     — the transaction/entitlement date the rate applies to (YYYY-MM-DD).
- `currency` — ISO 4217 code (target GBP implied).
- `rate`     — GBP per unit of `currency` (`GBP = amount * rate`).
- `source`   — the `RateSource.identifier` that produced it (provenance).
- `fetched_on` — date the rate was retrieved (audit).

Header comment records the direction convention and provenance meaning.

### Cache safety strategy
The cache is the authoritative record of the rates behind filed returns, so it is
protected as follows:

1. **Append-only / immutable rows (core).** An existing `(date, currency)` entry
   is never modified or deleted. Fetch mode only appends missing rows. Once a rate
   is cached it is frozen, so later provider restatements cannot change a filed
   figure.
2. **Git-committed (core).** The cache lives in version control; every change is a
   reviewable diff and fully revertible. Git provides the historical versions.
3. **Sorted, stable serialisation (core).** The cache is always rewritten sorted
   by `date,currency` so appends produce minimal, obvious diffs and never reorder
   existing rows.
4. **Integrity assertion (safety).** On write, the tool verifies every pre-existing
   `(date, currency)` still maps to its original `rate` (and source). If a fetch
   ever yields a different rate for an existing key, it refuses to write and warns
   — protecting against provider drift or bugs silently altering history.
5. **Provenance columns (adopted).** `source` and `fetched_on` make each rate
   self-documenting for audit.
6. **Per-filing snapshot (manual habit / optional `--snapshot`).** At filing time,
   copy the cache to a dated read-only file stored alongside the return PDF
   (e.g. `fx-rates-2024-25-filed.csv`), freezing the exact rates behind that
   submission independently of later cache growth.

### Switching rate source
The cache key is `(date, currency)` — **`source` is provenance, not identity.**
This has deliberate consequences if you ever change `--source` (e.g. from ECB to
some new source):

- **Existing rows are never re-fetched or changed.** A cached `(date, currency)`
  is served from the cache regardless of the currently selected source, so the new
  source is *not* consulted for dates already present. Filed figures cannot change
  underneath you. (If a fetch ever did yield a different rate for an existing key,
  the append-only immutability assertion rejects the write rather than overwriting.)
- **Only uncached dates are fetched from the new source.** Those new rows are
  tagged with the new `source`. The result is therefore a **mixed-provenance
  cache**: some rows `ECB`, some from the new source, and a single calculation may
  blend both.
- To make that visible rather than silent, `--fetch` **warns** when the selected
  source differs from the source of rows it is already relying on from the cache.

Three possible policies (current behaviour is A):

- **A — source is provenance only (current).** First source to populate a
  `(date, currency)` wins forever; switching source only affects uncached dates;
  filed figures never change. Mixed-provenance is possible (hence the warning).
- **B — source is part of cache identity.** Key becomes `(date, currency, source)`;
  a calculation selects which source to use. Switching source would fetch fresh
  rates even for existing dates and could produce different numbers from a previous
  submission. (Future decision, not implemented.)
- **C — one source per cache file.** A cache is single-source by construction;
  switching means pointing at a different cache file. (Future decision.)

**If you want to adopt a new source and apply it retroactively**, the deliberate
manual act is simply: **delete the cache and start over** with the new source. Git
preserves the previous cache (and any per-filing snapshots), so this is reversible
and fully diffable. You may then need to *restate* prior figures — but since
reputable reference-rate sources track each other closely, the delta should be
small. Treat any material delta as a signal to investigate rather than accept.

## CLI
```
cgtcalc-fx <source-file>
           [--cache <path>]        # default ./fx-rates-cache.csv
           [--fetch]               # allow fetching + appending missing rates
           [--source <key>]        # rate source, default ECB (Frankfurter)
           [--snapshot <path>]     # optional: copy cache to a frozen snapshot after run
           [-o <output-file>]      # default stdout
```

Behaviour:
- Reads the source file, resolves rates, writes GBP-only `cgtcalc` input.
- Explicit (no `--fetch`): errors listing missing `(date, currency)` pairs.
- `--fetch`: appends missing rates from `--source`, respecting the safety rules.
- Output is a valid `cgtcalc` input file; pipe or pass it straight to `cgtcalc`.

## Worked pipeline
```
cgtcalc-fx trades-src.txt --cache fx-rates-cache.csv --fetch -o trades-gbp.txt
cgtcalc trades-gbp.txt --rounding aggregate -o report.txt
```

## Resolved during implementation
- **`--snapshot` implemented.** Provided as an optional flag; manual snapshotting
  remains available too.
- **Emitted GBP precision:** fixed at 6 decimal places (`NSDecimalRound .plain`).
  Whole-pound tax rounding is `cgtcalc`'s job downstream, so the preprocessor keeps
  full working precision.
- **Existing cache migrated** from the legacy 3-column `date,currency,rate` to the
  5-column provenance format. The 122 rates behind the filed August 2026 figures
  were backfilled as `source = ECB`, `fetched_on = 2026-08-19` (they were fetched
  live from Frankfurter/ECB during that filing run).
- **Provenance columns do real work.** ECB reference rates were observed to drift
  between fetches (82 of 83 historical CHF rates changed between an August and a
  September pull). `source`/`fetched_on` plus the append-only immutability rule are
  what make a filed figure reproducible despite that drift.

## Open questions / future
- Whether to support a `MANUAL`/CSV-import rate source for rates taken from a
  broker contract note (would record `source = "broker"` or similar).
- Whether to add a `--verify` mode that re-fetches and reports drift against the
  cache without writing, as an audit aid.
