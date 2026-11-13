defmodule Xbase.VfpCompatTest do
  @moduledoc """
  Reproduction tests for reading Visual FoxPro tables: code page decoding,
  VFP binary field types and FPT memo files.
  """
  use ExUnit.Case, async: true

  alias Xbase.{FieldParser, MemoHandler, Parser}
  alias Xbase.Types.FieldDescriptor

  @tmp_dir Path.join(System.tmp_dir!(), "xbase_vfp_compat_test")

  setup do
    dir = Path.join(@tmp_dir, "#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # Builds a Visual FoxPro style DBF: 32-byte header, field descriptors,
  # 0x0D terminator and the 263-byte database container backlink.
  defp write_vfp_dbf(path, fields, rows, opts \\ []) do
    version = Keyword.get(opts, :version, 0x30)
    code_page = Keyword.get(opts, :code_page, 0x03)
    table_flags = Keyword.get(opts, :table_flags, 0x00)

    header_length = 32 + 32 * length(fields) + 1 + 263
    record_length = 1 + Enum.sum(Enum.map(fields, fn {_, _, len, _} -> len end))

    header =
      <<version, 125, 11, 12, length(rows)::little-32, header_length::little-16,
        record_length::little-16, 0::16, 0, 0, 0::12*8, table_flags, code_page, 0::16>>

    {descriptors, _} =
      Enum.map_reduce(fields, 1, fn {name, type, len, dec}, displacement ->
        padded = String.pad_trailing(name, 11, <<0>>)

        {<<padded::binary-size(11), type::binary-size(1), displacement::little-32, len, dec,
           0::14*8>>, displacement + len}
      end)

    records = Enum.map(rows, fn row -> <<0x20>> <> row end)

    File.write!(
      path,
      IO.iodata_to_binary([header, descriptors, <<0x0D>>, :binary.copy(<<0>>, 263), records])
    )
  end

  defp c(text, len), do: String.pad_trailing(text, len)

  describe "code page decoding" do
    test "character fields from a Windows-1252 table are returned as UTF-8", %{dir: dir} do
      path = Path.join(dir, "cp1252.dbf")
      # "St-Laurent, Québec" with é encoded as Windows-1252 byte 0xE9
      write_vfp_dbf(path, [{"CITY", "C", 20, 0}], [c("St-Laurent, Qu\xE9bec", 20)],
        code_page: 0x03
      )

      {:ok, dbf} = Parser.open_dbf(path)
      {:ok, record} = Parser.read_record(dbf, 0)
      Parser.close_dbf(dbf)

      assert record.data["CITY"] == "St-Laurent, Québec"
    end

    test "Windows-1252 characters outside Latin-1 decode correctly", %{dir: dir} do
      path = Path.join(dir, "cp1252_extra.dbf")
      # 0x80 is the euro sign and 0x92 a right single quote in Windows-1252
      write_vfp_dbf(path, [{"NOTE", "C", 10, 0}], [c("\x80 5 l\x92an", 10)], code_page: 0x03)

      {:ok, dbf} = Parser.open_dbf(path)
      {:ok, record} = Parser.read_record(dbf, 0)
      Parser.close_dbf(dbf)

      assert record.data["NOTE"] == "€ 5 l’an"
    end

    test "character fields from a DOS code page 437 table are returned as UTF-8", %{dir: dir} do
      path = Path.join(dir, "cp437.dbf")
      # é is byte 0x82 in code page 437
      write_vfp_dbf(path, [{"CITY", "C", 10, 0}], [c("Qu\x82bec", 10)],
        version: 0x03,
        code_page: 0x01
      )

      {:ok, dbf} = Parser.open_dbf(path)
      {:ok, record} = Parser.read_record(dbf, 0)
      Parser.close_dbf(dbf)

      assert record.data["CITY"] == "Québec"
    end

    test "updating a Windows-1252 table keeps its text encoded in Windows-1252", %{dir: dir} do
      path = Path.join(dir, "cp1252_update.dbf")

      write_vfp_dbf(path, [{"CITY", "C", 20, 0}, {"CODE", "C", 4, 0}], [
        c("St-Laurent, Qu\xE9bec", 20) <> c("A", 4)
      ])

      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      {:ok, dbf} = Parser.update_record(dbf, 0, %{"CODE" => "B"})
      Parser.close_dbf(dbf)

      bytes = File.read!(path)
      assert :binary.match(bytes, "St-Laurent, Qu\xE9bec") != :nomatch
      assert :binary.match(bytes, "Québec") == :nomatch
    end

    test "appended UTF-8 text is stored in the table's code page and read back", %{dir: dir} do
      path = Path.join(dir, "cp1252_append.dbf")
      write_vfp_dbf(path, [{"CITY", "C", 20, 0}], [])

      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      {:ok, dbf} = Parser.append_record(dbf, %{"CITY" => "Montréal €"})
      {:ok, dbf} = Parser.batch_append_records(dbf, [%{"CITY" => "Lévis"}])
      {:ok, records} = Parser.read_records(dbf)
      Parser.close_dbf(dbf)

      assert Enum.map(records, & &1["CITY"]) == ["Montréal €", "Lévis"]
      bytes = File.read!(path)
      assert :binary.match(bytes, "Montr\xE9al \x80") != :nomatch
      assert :binary.match(bytes, "L\xE9vis") != :nomatch
    end

    test "packing keeps text in the table's code page", %{dir: dir} do
      path = Path.join(dir, "cp1252_pack.dbf")
      packed_path = Path.join(dir, "cp1252_packed.dbf")
      write_vfp_dbf(path, [{"CITY", "C", 20, 0}], [c("Qu\xE9bec", 20), c("Gasp\xE9", 20)])

      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      {:ok, dbf} = Parser.mark_deleted(dbf, 1)
      {:ok, packed} = Parser.pack(dbf, packed_path)
      Parser.close_dbf(dbf)
      Parser.close_dbf(packed)

      assert :binary.match(File.read!(packed_path), "Qu\xE9bec") != :nomatch
    end

    test "a character the code page cannot store is an error, not corrupt data", %{dir: dir} do
      path = Path.join(dir, "cp1252_unencodable.dbf")
      write_vfp_dbf(path, [{"CITY", "C", 20, 0}], [])

      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      result = Parser.append_record(dbf, %{"CITY" => "東京"})
      Parser.close_dbf(dbf)

      assert {:error, {:unencodable, "CITY", "東"}} = result
    end

    test "encoding: :raw returns the stored bytes unchanged", %{dir: dir} do
      path = Path.join(dir, "cp1252_raw.dbf")
      write_vfp_dbf(path, [{"CITY", "C", 10, 0}], [c("Qu\xE9bec", 10)])

      {:ok, dbf} = Parser.open_dbf(path, [:read], encoding: :raw)
      {:ok, record} = Parser.read_record(dbf, 0)
      Parser.close_dbf(dbf)

      assert record.data["CITY"] == "Qu\xE9bec"
    end

    test "an unknown encoding option is rejected", %{dir: dir} do
      path = Path.join(dir, "cp1252_bad_option.dbf")
      write_vfp_dbf(path, [{"CITY", "C", 10, 0}], [])

      assert {:error, {:invalid_encoding, :ebcdic}} =
               Parser.open_dbf(path, [:read], encoding: :ebcdic)
    end

    test "a table without a code page keeps its bytes unchanged", %{dir: dir} do
      path = Path.join(dir, "no_code_page.dbf")
      write_vfp_dbf(path, [{"CITY", "C", 10, 0}], [c("Qu\xE9bec", 10)], code_page: 0x00)

      {:ok, dbf} = Parser.open_dbf(path)
      {:ok, record} = Parser.read_record(dbf, 0)
      Parser.close_dbf(dbf)

      assert record.data["CITY"] == "Qu\xE9bec"
    end
  end

  describe "Visual FoxPro binary field types" do
    test "Y currency is an 8-byte integer scaled by 10,000" do
      field = %FieldDescriptor{name: "BALANCE", type: "Y", length: 8, decimal_count: 4}

      assert {:ok, value} = FieldParser.parse(field, <<1_234_567::little-signed-64>>)
      assert to_string(value) == "123.4567"
    end

    test "Y currency keeps the sign of negative amounts" do
      field = %FieldDescriptor{name: "BALANCE", type: "Y", length: 8, decimal_count: 4}

      assert {:ok, value} = FieldParser.parse(field, <<-1_234_567::little-signed-64>>)
      assert to_string(value) == "-123.4567"
    end

    test "Y currency is returned as an exact Decimal" do
      field = %FieldDescriptor{name: "BALANCE", type: "Y", length: 8, decimal_count: 4}

      assert {:ok, %Decimal{} = value} = FieldParser.parse(field, <<1_000::little-signed-64>>)
      assert Decimal.equal?(value, Decimal.new("0.1"))
    end

    test "B double is an 8-byte little-endian float" do
      field = %FieldDescriptor{name: "RATIO", type: "B", length: 8, decimal_count: 2}

      assert {:ok, 1.5} = FieldParser.parse(field, <<1.5::little-float-64>>)
    end

    test "a 4-byte M field is a binary memo block number" do
      field = %FieldDescriptor{name: "NOTES", type: "M", length: 4, decimal_count: 0}

      assert {:ok, {:memo_ref, 42}} = FieldParser.parse(field, <<42::little-32>>)
    end

    test "a 4-byte M field with block 0 has no memo" do
      field = %FieldDescriptor{name: "NOTES", type: "M", length: 4, decimal_count: 0}

      assert {:ok, nil} = FieldParser.parse(field, <<0::little-32>>)
    end

    test "a G general field is a binary memo block number" do
      field = %FieldDescriptor{name: "PICTURE", type: "G", length: 4, decimal_count: 0}

      assert {:ok, {:memo_ref, 7}} = FieldParser.parse(field, <<7::little-32>>)
    end

    test "a 4-byte I integer is always binary, even when its bytes look like digits" do
      field = %FieldDescriptor{name: "ID", type: "I", length: 4, decimal_count: 0}
      # 0x31202020 is stored little-endian as the bytes "   1"
      assert {:ok, 0x31202020} = FieldParser.parse(field, <<0x31202020::little-signed-32>>)
    end

    test "the _NullFlags system field is returned as raw bytes" do
      field = %FieldDescriptor{name: "_NullFlags", type: "0", length: 1, decimal_count: 0}

      assert {:ok, <<0b101>>} = FieldParser.parse(field, <<0b101>>)
    end

    test "a table using Y, B, M and G fields can be read", %{dir: dir} do
      path = Path.join(dir, "vendors.dbf")

      fields = [
        {"VENDNO", "C", 6, 0},
        {"BALANCE", "Y", 8, 4},
        {"RATIO", "B", 8, 2},
        {"VNDMEMO", "M", 4, 0},
        {"VENDGEN", "G", 4, 0}
      ]

      row =
        c("E0290", 6) <>
          <<250_000::little-signed-64>> <>
          <<0.25::little-float-64>> <> <<0::little-32>> <> <<0::little-32>>

      write_vfp_dbf(path, fields, [row], table_flags: 0x02)

      {:ok, dbf} = Parser.open_dbf(path)
      assert {:ok, record} = Parser.read_record(dbf, 0)
      Parser.close_dbf(dbf)

      assert record.data["VENDNO"] == "E0290"
      assert to_string(record.data["BALANCE"]) == "25.0000"
      assert record.data["RATIO"] == 0.25
      assert record.data["VNDMEMO"] == nil
    end
  end

  describe "FPT memo files" do
    # FPT: 512-byte header (next free block and block size, big-endian), then
    # blocks of <<type::32-big, length::32-big, data>>.
    defp write_fpt(path, block_size, memos) do
      first_block = div(512, block_size)

      {blocks, next_block} =
        Enum.map_reduce(memos, first_block, fn text, block ->
          body = <<1::big-32, byte_size(text)::big-32, text::binary>>
          blocks_used = div(byte_size(body) + block_size - 1, block_size)
          padded = body <> :binary.copy(<<0>>, blocks_used * block_size - byte_size(body))
          {{block, padded}, block + blocks_used}
        end)

      header = <<next_block::big-32, 0::16, block_size::big-16, 0::504*8>>
      File.write!(path, IO.iodata_to_binary([header | Enum.map(blocks, &elem(&1, 1))]))
      Enum.map(blocks, &elem(&1, 0))
    end

    test "memo text is read from the table's FPT file", %{dir: dir} do
      dbf_path = Path.join(dir, "notes.dbf")
      [block] = write_fpt(Path.join(dir, "notes.fpt"), 64, ["Livrer au quai 3"])

      write_vfp_dbf(
        dbf_path,
        [{"ID", "C", 4, 0}, {"NOTES", "M", 4, 0}],
        [
          c("1", 4) <> <<block::little-32>>
        ],
        table_flags: 0x02
      )

      {:ok, handler} = MemoHandler.open_dbf_with_memo(dbf_path)
      result = MemoHandler.read_record_with_memo(handler, 0)
      MemoHandler.close_memo_files(handler)

      assert {:ok, %{"ID" => "1", "NOTES" => "Livrer au quai 3"}} = result
    end

    test "memo text is decoded from the table's code page", %{dir: dir} do
      dbf_path = Path.join(dir, "notes_cp1252.dbf")
      [block] = write_fpt(Path.join(dir, "notes_cp1252.fpt"), 64, ["Exp\xE9dier \xE0 Qu\xE9bec"])

      write_vfp_dbf(dbf_path, [{"NOTES", "M", 4, 0}], [<<block::little-32>>], table_flags: 0x02)

      {:ok, handler} = MemoHandler.open_dbf_with_memo(dbf_path)
      result = MemoHandler.read_record_with_memo(handler, 0)
      MemoHandler.close_memo_files(handler)

      assert {:ok, %{"NOTES" => "Expédier à Québec"}} = result
    end

    test "memos spanning several blocks are read whole", %{dir: dir} do
      dbf_path = Path.join(dir, "long_notes.dbf")
      long_text = String.duplicate("0123456789", 20)
      [first, second] = write_fpt(Path.join(dir, "long_notes.fpt"), 64, [long_text, "short"])

      write_vfp_dbf(
        dbf_path,
        [{"NOTES", "M", 4, 0}],
        [<<first::little-32>>, <<second::little-32>>],
        table_flags: 0x02
      )

      {:ok, handler} = MemoHandler.open_dbf_with_memo(dbf_path)
      first_result = MemoHandler.read_record_with_memo(handler, 0)
      second_result = MemoHandler.read_record_with_memo(handler, 1)
      MemoHandler.close_memo_files(handler)

      assert {:ok, %{"NOTES" => ^long_text}} = first_result
      assert {:ok, %{"NOTES" => "short"}} = second_result
    end

    test "opening an FPT memo table for writing is refused", %{dir: dir} do
      dbf_path = Path.join(dir, "notes_write.dbf")
      write_fpt(Path.join(dir, "notes_write.fpt"), 64, ["text"])
      write_vfp_dbf(dbf_path, [{"NOTES", "M", 4, 0}], [<<8::little-32>>], table_flags: 0x02)

      assert {:error, :fpt_write_not_supported} =
               MemoHandler.open_dbf_with_memo(dbf_path, [:read, :write])
    end
  end
end
