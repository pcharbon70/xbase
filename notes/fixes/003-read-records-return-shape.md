# Fix: read_records/stream_records return shape contradicts the docs

## Bug Summary
`read_record/2` returns `%Xbase.Types.Record{data: ..., deleted: ...}`, but
`read_records/1` and `stream_records/1` return bare field maps. The README and
the guides contradict each other:
- The `read_records/1` `@doc` says "List of record data maps", which matches
  the code.
- The README stream example uses `record.data["AGE"]`.
- `docs/guides/getting_started.md` and `docs/guides/streaming.md` use
  `record.data[...]` and `record.deleted` on `stream_records/1` results.

Code that follows the guides crashes with
`** (KeyError) key :data not found`.

## Root Cause
`read_records_recursive/4` and the `stream_records/1` resource function both
accumulate `record.data` instead of `record`. They already skip deleted
records, so `record.deleted` is always false in their output anyway.

## Existing Usage Rules Violations
None.

## Reproduction Test
Pending the decision below: the test asserts whichever contract is chosen.

## Test Output
Observed in a consumer project:
```
** (KeyError) key :data not found in: %{"ITEM2" => "", ...}
```

## Proposed Solution
Two options:
- **A. Keep maps; fix the docs (recommended).** Non-breaking, and it matches
  the existing `@doc`. Fix the README and guide examples: drop `.data` and the
  redundant `Stream.reject(& &1.deleted)`. Add a test that pins the map shape
  for both functions.
- **B. Return `%Record{}` structs.** Matches the guides and is consistent with
  `read_record/2`, but it is a breaking change for current users.

## Changes Required
- A: `README.md`, `docs/guides/getting_started.md`, `docs/guides/streaming.md`,
  `docs/guides/memo_fields.md` and `docs/guides/performance.md` (stream
  examples), plus tests.
- B: `lib/xbase/parser.ex` (two places), the same docs, and existing tests that
  rely on maps.

## Potential Side Effects
- A: none at runtime.
- B: breaks every caller of `read_records/1` and `stream_records/1`.

## Regression Prevention
Tests that assert the exact element shape of both functions.

## Questions for Pascal
1. Option A (keep maps, fix the docs) or option B (return structs)?

## Decisions
- Option A: keep maps and fix the docs (approved).

## Implementation Log
- Added `test/xbase/record_shape_test.exs`. It pins `read_record/2` to
  `%Record{}`, and `read_records/1` and `stream_records/1` to plain maps of
  active records.
- Fixed examples in `README.md` and in the `getting_started`, `streaming`,
  `memo_fields` and `performance` guides. Each code block was checked by
  hand: examples using `read_record/2` keep `.data` and `.deleted`, and the
  redundant `Stream.reject(& &1.deleted)` after `stream_records/1` was
  removed.
- `docs/api/parser.md` documented a non-existent `read_all_records/2` with an
  `:include_deleted` option. It now documents `read_records/1` and
  `stream_records/1` as they are. `memo_fields.md` also called
  `read_all_records`.
- The two integration tests that failed on `main` ("streams through large
  real dataset efficiently" and "handles large dataset statistics") treated
  streamed records as structs, causing `KeyError :deleted`. They now use maps.

## Final Implementation
Documentation and tests only; no runtime change.

## Test Results
- New tests: `record_shape_test.exs` (3 tests), passing.
- The two previously failing integration tests now pass.
- Full suite: `mix test --include integration --include performance`, 297
  passed and 0 failed (baseline on `main`: 268 passed, 2 failed in the
  prrolls.DBF integration tests; see fix 003).
- `MIX_ENV=test mix compile --force --warnings-as-errors`: passes.
- `mix hex.audit`: no retired or vulnerable packages.

## Verification Checklist
- [x] Bug is fixed
- [x] No regressions introduced
- [x] Tests cover the fix
- [x] Code follows patterns

## Conclusion
The documented contract now matches the code.
