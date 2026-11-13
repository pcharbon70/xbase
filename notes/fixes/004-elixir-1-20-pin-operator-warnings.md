# Fix: compile warnings under Elixir 1.20 for variables used in size(...)

## Bug Summary
Under Elixir 1.20, the library emits 7 warnings: "the variable ... is accessed
inside size(...) of a bitstring but it was defined outside of the match. You
must precede it with the pin operator". Projects compiling with
`--warnings-as-errors` see the noise from the dependency, and a future Elixir
version may turn it into an error.

## Root Cause
Binary patterns use variables bound before the match in `size(...)` without
`^`. Elixir 1.20 requires the pin operator there.

## Existing Usage Rules Violations
Elixir 1.20 language rule: outer variables in `size/1` must be pinned.

## Reproduction Test
`mix compile --force` (a compiler check rather than an ExUnit test):
```
"offset"       lib/xbase/parser.ex:1185:24      Xbase.Parser.parse_fields_from_record/4
"field_length" lib/xbase/parser.ex:1185:57      Xbase.Parser.parse_fields_from_record/4
"offset"       lib/xbase/parser.ex:1242:26      Xbase.Parser.parse_fields_recursive/3
"offset"       lib/xbase/parser.ex:1246:28      Xbase.Parser.parse_fields_recursive/3
"key_length"   lib/xbase/cdx_parser.ex:270:35   Xbase.CdxParser.parse_keys_and_pointers/6
"key_length"   lib/xbase/cdx_parser.ex:279:35   Xbase.CdxParser.parse_keys_and_pointers/6
"key_length"   lib/xbase/cdx_parser.ex:288:35   Xbase.CdxParser.parse_keys_and_pointers/6
```

## Proposed Solution
Add `^` to each listed variable inside `size(...)`. The pin operator is valid
on the supported range (`elixir: "~> 1.18"`).

## Changes Required
1. `lib/xbase/parser.ex`: lines 1185, 1242 and 1246.
2. `lib/xbase/cdx_parser.ex`: lines 270, 279 and 288.

## Potential Side Effects
None: same semantics.

## Regression Prevention
`mix compile --force --warnings-as-errors` must pass. Optionally, add it to CI.

## Questions for Pascal
None.

## Implementation Log
- Added `^` to `offset` and `field_length` (`parser.ex`) and to `key_length`
  (`cdx_parser.ex`) inside `size(...)`.

## Final Implementation
As proposed.

## Test Results
- Full suite: `mix test --include integration --include performance`, 297
  passed and 0 failed (baseline on `main`: 268 passed, 2 failed in the
  prrolls.DBF integration tests; see fix 003).
- `MIX_ENV=test mix compile --force --warnings-as-errors`: passes.
- `mix hex.audit`: no retired or vulnerable packages.
- The library code compiles with 0 warnings. One test-only warning remains,
  "comparison between distinct types" in `test/integration_test.exs`; it was
  there before this fix and is out of scope.

## Verification Checklist
- [x] Bug is fixed
- [x] No regressions introduced
- [x] Tests cover the fix (compiler check)
- [x] Code follows patterns

## Conclusion
Fixed.
