# Fix: Character fields are returned in the table's code page, not UTF-8

## Bug Summary
`C` fields come back as the raw bytes stored in the file. Tables written by
Visual FoxPro or DOS applications use a single-byte code page, so any accented
character produces a binary that is not valid UTF-8 (for example "Québec"
becomes `<<..., 81, 117, 233, 98, 101, 99>>`). In a real 3,243-record VFP table,
every record is affected.

## Root Cause
`Xbase.FieldParser.parse/2` for type `C` only trims trailing spaces. The code
page byte at offset 29 of the header is already parsed into
`Header.language_driver`, but nothing uses it. The parser has no access to the
header when it parses a field.

## Existing Usage Rules Violations
None. Elixir strings are expected to be UTF-8, and the library returns
non-UTF-8 binaries as if they were strings.

## Reproduction Test
`test/xbase/vfp_compat_test.exs`, describe "code page decoding":
- "character fields from a Windows-1252 table are returned as UTF-8"
- "Windows-1252 characters outside Latin-1 decode correctly"
- "character fields from a DOS code page 437 table are returned as UTF-8"
- "updating a Windows-1252 table keeps its text encoded in Windows-1252"
  (regression guard: passes today and must keep passing)

## Test Output
```
test code page decoding character fields from a Windows-1252 table are returned as UTF-8
Assertion with == failed
code:  assert record.data["CITY"] == "St-Laurent, Québec"
left:  <<83, 116, 45, 76, 97, 117, 114, 101, 110, 116, 44, 32, 81, 117, ...
right: "St-Laurent, Québec"

test code page decoding Windows-1252 characters outside Latin-1 decode correctly
left:  <<128, 32, 53, 32, 108, 146, 97, 110>>
right: "€ 5 l’an"

test code page decoding character fields from a DOS code page 437 table are returned as UTF-8
left:  <<81, 117, 130, 98, 101, 99>>
right: "Québec"
```

## Proposed Solution
- Add `Xbase.CodePage`, which maps the header's code page byte to an encoding
  and converts in both directions:
  - `0x03` and `0x57`: Windows-1252, with an explicit table for 0x80–0x9F and
    Latin-1 for the rest.
  - `0x01`: DOS 437, and `0x02`: DOS 850, as 128-entry tables.
  - `0x00` or any unknown byte: no conversion, so the current behaviour is kept.
- `Parser.open_dbf/2,3` resolves the encoding once and stores it in the dbf
  map. A new optional `opts` argument, `encoding: :raw | :cp1252 | :cp437 |
  :cp850`, overrides the header, and `:raw` restores the old behaviour.
- `read_record/2` decodes `C` field values after `FieldParser.parse/2`.
  `FieldParser` itself stays encoding-agnostic.
- Writing (`append_record`, `update_record`, batch variants) encodes `C` values
  back to the table's code page before padding. A character the code page
  cannot represent returns `{:error, {:unencodable, field, char}}` rather than
  silently writing UTF-8 bytes.
- Field length is checked after encoding, in bytes, as today.

## Changes Required
1. `lib/xbase/code_page.ex`: new module with the code page tables, `decode/2`
   and `encode/2`.
2. `lib/xbase/parser.ex`: in `open_dbf`, store `:encoding`; in `read_record`,
   decode `C` fields; in the encoding paths, encode `C` fields.
3. `lib/xbase/memo_handler.ex`: decode memo text with the same encoding.
4. README and getting-started guide: document the `encoding` option.

## Potential Side Effects
- Callers that worked around raw bytes themselves (for example with
  `:unicode.characters_to_binary(v, :latin1)`) would double-decode. They can
  pass `encoding: :raw`. This is a behaviour change, so bump the version to
  0.2.0.
- Tables with code page byte `0x00` are unchanged.

## Regression Prevention
The reproduction tests, plus round-trip tests: write UTF-8 → bytes on disk are
in the code page → read back as UTF-8.

## Questions for Pascal
1. Decode automatically from the header (recommended), or only when
   `encoding:` is passed?

## Decisions
- Decode automatically from the header; `encoding: :raw` opts out (approved).

## Implementation Log
- Added `lib/xbase/code_page.ex`. Its 0x80–0xFF tables for Windows-1252,
  DOS 437 and DOS 850 were generated from reference codecs. Bytes a code page
  leaves undefined map to the same code point, so decoding never loses data.
- `Parser.open_dbf/3` takes `encoding:` and rejects unknown values with
  `{:error, {:invalid_encoding, value}}`. The resolved encoding is stored in
  the dbf map by `open_dbf`, `create_dbf`, `refresh_dbf_state` and `pack`.
- `read_record/2` decodes `C` fields. `read_records/1`, `stream_records/1` and
  the batch functions inherit this because they use `read_record/2`.
- `C` fields are encoded back before every record write: `append_record`,
  `update_record`, `batch_append_records`, batch updates and `pack`.
- `MemoHandler` decodes memo text on read and encodes it on write.

## Final Implementation
Text is converted at the parser boundary; `FieldParser` and `FieldEncoder`
are unchanged. A character the code page cannot represent returns
`{:error, {:unencodable, field_name, char}}`.

## Test Results
- Reproduction tests: passing.
- New tests (`test/xbase/vfp_compat_test.exs`, "code page decoding"):
  - append and batch append round trip;
  - `pack` keeps Windows-1252 bytes;
  - unencodable character;
  - `encoding: :raw`;
  - invalid encoding option;
  - code page 0 unchanged;
  - memo text decoding.
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
Fixed in 0.2.0, which is a behaviour change, as recorded in CHANGELOG.md.
Possible follow-up: `FieldEncoder` truncates `C` values with
`String.slice/3`, which counts graphemes rather than bytes. On `:raw` tables,
multi-byte UTF-8 text can therefore exceed the field length. Encoded tables
are not affected, because their text is single-byte by then.
