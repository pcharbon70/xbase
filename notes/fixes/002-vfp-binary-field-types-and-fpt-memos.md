# Fix: Visual FoxPro binary field types and FPT memo files are not supported

## Bug Summary
Opening a Visual FoxPro table works, but reading any record that contains a
`Y` (currency), `B` (double), `G` (general) or `0` (`_NullFlags`) field fails
with `{:error, :unknown_field_type}`. VFP memo fields (`M`, 4 bytes) are read as
empty, and their `.fpt` memo file is never opened. A 4-byte binary `I` integer
whose bytes happen to look like digits is misread as text. The real SBT vendor
table (`apvend01.dbf`, 728 records, VFP format) cannot be read at all.

## Root Cause
- `FieldParser.parse/2` has no clauses for `Y`, `B`, `G` or `0`, so they fall
  through to `:unknown_field_type`.
- The `M` clause assumes a dBase III 10-byte ASCII block number. VFP stores a
  4-byte little-endian integer, so `Integer.parse/1` fails and the value
  becomes `nil`.
- The `I` and `T` clauses try text parsing first and fall back to binary.
  VFP always stores them in binary, so a binary value made of digit and space
  bytes is misread.
- `MemoHandler.has_memo_support?/1` only accepts versions `0x83`, `0x8B` and
  `0xF5`. VFP (`0x30`, `0x31`, `0x32`) signals memos with bit `0x02` of the
  table flags byte (offset 28, parsed as `mdx_flag`). `discover_dbt_path/1`
  only looks for `.dbt`.
- There is no reader for the FPT format: a 512-byte header with the next free
  block and block size stored big-endian, and blocks of
  `<<type::32-big, length::32-big, data>>`.

## Existing Usage Rules Violations
None.

## Reproduction Test
`test/xbase/vfp_compat_test.exs`, describes "Visual FoxPro binary field types"
and "FPT memo files".

## Test Output
```
test Y currency is an 8-byte integer scaled by 10,000
right: {:error, :unknown_field_type}
test B double is an 8-byte little-endian float
right: {:error, :unknown_field_type}
test a 4-byte M field is a binary memo block number
left:  {:ok, {:memo_ref, 42}}
right: {:ok, nil}
test a G general field is a binary memo block number
right: {:error, :unknown_field_type}
test a 4-byte I integer is always binary, even when its bytes look like digits
left:  {:ok, 824_188_960}
right: {:ok, 1}
test the _NullFlags system field is returned as raw bytes
right: {:error, :unknown_field_type}
test a table using Y, B, M and G fields can be read
code:  assert {:ok, record} = Parser.read_record(dbf, 0)
right: {:error, :unknown_field_type}
test memo text is read from the table's FPT file
left:  {:ok, %{"ID" => "1", "NOTES" => "Livrer au quai 3"}}
right: {:ok, %{"ID" => "1", "NOTES" => nil}}
```
("a 4-byte M field with block 0 has no memo" passes today and is a guard.)

## Proposed Solution
In `FieldParser.parse/2`, add or adjust these clauses:
- `Y`: `<<v::little-signed-64>>` scaled by 10,000. The return type depends on
  the decision below.
- `B`: `<<v::little-float-64>>`.
- `M` and `G` with length 4: `<<n::little-32>>`, giving `{:memo_ref, n}`, or
  `nil` when `n == 0`. The 10-byte ASCII `M` clause stays for dBase.
- `I` with length 4: binary only. `T` with length 8: binary first, keeping the
  existing text fallback for odd dBase files.
- `0` (`_NullFlags`): return the raw bytes.

For memos:
- Add `Xbase.FptParser` with `open_fpt/1`, `read_memo/2` and `close_fpt/1`,
  read-only.
- `MemoHandler`: treat VFP versions with table flag `0x02` as memo-capable.
  `discover_dbt_path/1` looks for `.fpt`/`.FPT` next to the table and falls back
  to `.dbt`. Use `FptParser` for `.fpt` files. Memo text is decoded with the
  table encoding (see fix 001).

## Changes Required
1. `lib/xbase/field_parser.ex`: the clauses above.
2. `lib/xbase/fpt_parser.ex`: new read-only FPT reader.
3. `lib/xbase/memo_handler.ex`: VFP memo detection, `.fpt` discovery, and
   choosing between the FPT and DBT readers.
4. `lib/xbase/types.ex`: an `FptFile` struct.
5. Update existing `field_parser_test.exs` I/T expectations only if they relied
   on the text-first behaviour for 4-byte `I` fields (to be confirmed when
   running the suite).

## Potential Side Effects
- Writing VFP binary types stays unsupported. `FieldEncoder` has no `Y`, `B` or
  `G` clauses, so `update_record` on such a table returns an error rather than
  corrupting it. Write support would be a separate feature.
- `Y` as `Decimal` adds a runtime dependency.
- VFP `V`, `Q` and `W` (varchar, varbinary, blob) are still unsupported and
  out of scope.

## Regression Prevention
The reproduction tests. The real-file check (`apvend01.dbf`) is run manually,
because that data cannot go into the repository.

## Questions for Pascal
1. `Y` currency: return `Decimal` and add `{:decimal, "~> 2.0"}` as a
   dependency (exact; recommended), or a float (no dependency, but money
   rounding errors)?
2. Is read-only VFP support enough for now?

## Decisions
- `Y` returns `Decimal`; `decimal` added as `~> 2.0 or ~> 3.0` (approved).
- Read-only VFP support for now (approved).

## Implementation Log
- `FieldParser`:
  - `Y` returns `Decimal.new(sign, abs(value), -4)`, and `B` returns a float.
  - 4-byte `M` and `G` fields give `{:memo_ref, n}`, or `nil` for block 0.
  - 4-byte `I` fields are read as binary only.
  - `_NullFlags` (`0`) returns the raw bytes.
- Added `lib/xbase/fpt_parser.ex` and the `FptFile` struct in `types.ex`.
- `MemoHandler`:
  - VFP versions `0x30`–`0x32` with table flag `0x02` are treated as
    memo-capable.
  - `.fpt`/`.FPT` files are discovered automatically and read with
    `FptParser`.
  - Opening an FPT table for writing returns
    `{:error, :fpt_write_not_supported}`.
- Discovered while testing: `validate_header_consistency/1` (used by
  `append_record`) ignored the 263-byte VFP backlink, so appending to any VFP
  table failed with `:header_length_mismatch`. It now adds 263 for VFP
  versions.

## Final Implementation
As proposed, plus the header-validation fix above.

## Test Results
- Reproduction tests: passing.
- New tests:
  - negative `Y`;
  - `Y` as an exact `Decimal`;
  - FPT memos spanning several blocks;
  - FPT memo text decoding;
  - opening an FPT table for writing is refused.
- Full suite: `mix test --include integration --include performance`, 297
  passed and 0 failed (baseline on `main`: 268 passed, 2 failed in the
  prrolls.DBF integration tests; see fix 003).
- `MIX_ENV=test mix compile --force --warnings-as-errors`: passes.
- `mix hex.audit`: no retired or vulnerable packages.
- Real-file check (run manually; the data cannot go into the repository):
  - legacy `reqs.dbf`: 3,243 records, 0 with invalid UTF-8, and
    "St-Laurent, Québec" decoded correctly.
  - SBT `apvend01.dbf`: 728 records, 0 with invalid UTF-8. `BALANCE` and
    `YTDPUR` are Decimals, memo text was read from `apvend01.fpt` for 29
    vendors, and accented names such as "TYCO FEU ET SÉCURITÉ INTÉGRÉS" are
    correct.

## Verification Checklist
- [x] Bug is fixed
- [x] No regressions introduced
- [x] Tests cover the fix
- [x] Code follows patterns

## Conclusion
VFP tables, including SBT's, can be read in full. Writing VFP binary types,
writing FPT memos, and `V`/`Q`/`W` fields remain unsupported.
