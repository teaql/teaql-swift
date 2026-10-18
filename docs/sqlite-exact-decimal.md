# Exact Decimal storage in the SQLite provider

Modeled Swift `Decimal` values must not pass through SQLite `NUMERIC` affinity:
SQLite may silently convert even a text-bound value to binary `REAL`. New
TeaQL-managed Decimal columns therefore use `DECIMAL_TEXT` (TEXT affinity), a
numeric `TEAQL_DECIMAL` collation, and a validation `CHECK`. The provider
registers the collation and validation function on each SQLite connection.

The supported path is typed audited mutation, bounded Q, and E readback. The
provider also uses an exact Decimal accumulator for `SUM`; `MIN`, `MAX` and
numeric ordering use the collation. `AVG(Decimal)` is rejected until a
rounding/scale policy is defined. Foundation `Decimal` normalizes spellings
such as `3.50` to `3.5`; this implementation preserves the numeric value, not
the original lexical scale.

`ensureSchema` rejects an existing `NUMERIC` Decimal column or one missing
the required collation/validation. It does not rewrite the table: values
already stored as `REAL` may have lost digits and cannot be safely recovered
from the rounded database value. An operator must migrate from an authoritative
exact source, then rerun `ensureSchema` and the application conformance tests.

Direct SQLite connections outside TeaQL also need the registered collation
and validation function to write these tables. Use the TeaQL SQLite provider
for normal application access; do not treat an arbitrary SQLite CLI update as
an equivalent mutation path.

The narrow regressions are in
[`ExactDecimalSQLiteTests.swift`](../Tests/TeaQLSQLiteTests/ExactDecimalSQLiteTests.swift).
The full generated-application/public-package comparison is tracked by
[`teaql-swift #44`](https://github.com/teaql/teaql-swift/issues/44). A local
source test is not a public package release.
