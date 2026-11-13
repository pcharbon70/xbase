# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Before 1.0.0, a
minor version may contain breaking changes.

## [Unreleased]

## [0.2.0] - Unreleased

This release makes Visual FoxPro tables readable, including tables with
accented text, currency fields and `.fpt` memo files.

### Breaking changes

- Text in `C` and memo fields is now decoded from the table's code page to
  UTF-8 when reading, and encoded back when writing. The code page comes from
  the header's language driver byte:
  - Windows-1252: `0x03` and `0x57`;
  - DOS 437: `0x01`;
  - DOS 850: `0x02`.

  Tables with any other code page byte, including `0x00`, are unchanged.
  Callers that converted the raw bytes themselves should pass `encoding: :raw`
  to `Xbase.Parser.open_dbf/3` to keep the previous behaviour.

### Added

- `Xbase.Parser.open_dbf/3`, with an `encoding:` option
  (`:raw | :cp1252 | :cp437 | :cp850`) that overrides the header. An unknown
  value returns `{:error, {:invalid_encoding, value}}`.
- `Xbase.CodePage`, for converting between a code page and UTF-8.
- Reading Visual FoxPro field types:
  - `Y` currency, returned as an exact `Decimal`;
  - `B` double, returned as a float;
  - 4-byte `M` and `G` memo references;
  - the `_NullFlags` system field, returned as raw bytes.
- `Xbase.FptParser`, read-only support for Visual FoxPro `.fpt` memo files.
  `Xbase.MemoHandler.open_dbf_with_memo/3` finds them automatically next to
  the table.
- `decimal` is now a runtime dependency (`~> 2.0 or ~> 3.0`).

### Fixed

- Writing a character the table's code page cannot represent returns
  `{:error, {:unencodable, field_name, char}}` instead of storing bytes the
  table cannot read.
- 4-byte `I` integers are always read as binary. Before, an integer whose
  bytes looked like digits was misread as text.
- Appending a record to a Visual FoxPro table no longer fails with
  `:header_length_mismatch`. Header validation now allows for the 263-byte
  database container backlink.
- The README, guides and API reference now match what `read_records/1` and
  `stream_records/1` return: plain field maps of active records. The API
  reference no longer documents `read_all_records/2`, which does not exist.
- Compile warnings under Elixir 1.20 for variables used in `size(...)`
  without the pin operator.

### Not supported yet

- Writing Visual FoxPro binary types (`Y`, `B`, `G`). Writing a record to a
  table with these fields returns an error rather than corrupting the table.
- Writing `.fpt` memo files. Opening one for writing returns
  `{:error, :fpt_write_not_supported}`.
- Visual FoxPro `V`, `Q` and `W` (varchar, varbinary and blob) fields.

## [0.1.0] - 2025-06-20

Initial release.

### Added

- Header and field descriptor parsing for dBase III, IV, 5, FoxPro and
  Visual FoxPro files.
- Reading records with `C`, `N`, `D`, `L`, `M`, `I` and `T` fields. Numeric
  fields filled with `*` (overflow) are read as `nil`.
- Creating tables, and appending, updating, deleting, undeleting and packing
  records.
- Transactions with rollback (`Xbase.Parser.transaction/2` and
  `Xbase.MemoHandler.memo_transaction/2`), batch operations and record
  counting.
- Streaming large tables with `stream_records/1`, `stream_where/2` and
  `stream_records_with_progress/2`.
- Reading and writing dBase memo files (`.dbt`), with block caching.
- Reading CDX index files.

[Unreleased]: https://github.com/pcharbon70/xbase/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/pcharbon70/xbase/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/pcharbon70/xbase/releases/tag/v0.1.0
