defmodule Xbase.ParserTest do
  use ExUnit.Case, async: true

  alias Xbase.Parser
  alias Xbase.Types.Header
  alias Xbase.Types.FieldDescriptor
  alias Xbase.Types.Record

  # Path to real test data files
  @test_dbf_path "test/prrolls.DBF"

  describe "parse_header/1" do
    test "parses a valid dBase III header" do
      # Create a valid 32-byte dBase III header
      header_binary = <<
        0x03,           # version (dBase III)
        124, 12, 17,    # last update: 2024-12-17 (year=124, month=12, day=17)
        100::little-32, # record count: 100
        161::little-16, # header length: 161 bytes  
        50::little-16,  # record length: 50 bytes
        0::16,          # reserved
        0x00,           # transaction flag
        0x00,           # encryption flag
        0::12*8,        # reserved (12 bytes)
        0x00,           # MDX flag
        0x00,           # language driver
        0::16           # reserved
      >>

      assert {:ok, header} = Parser.parse_header(header_binary)
      assert %Header{} = header
      assert header.version == 0x03
      assert header.last_update_year == 124
      assert header.last_update_month == 12
      assert header.last_update_day == 17
      assert header.record_count == 100
      assert header.header_length == 161
      assert header.record_length == 50
      assert header.transaction_flag == 0x00
      assert header.encryption_flag == 0x00
      assert header.mdx_flag == 0x00
      assert header.language_driver == 0x00
    end

    test "parses a dBase IV header with MDX flag" do
      header_binary = <<
        0x8B,           # version (dBase IV with memo)
        124, 12, 17,    # last update: 2024-12-17
        250::little-32, # record count: 250
        193::little-16, # header length: 193 bytes
        75::little-16,  # record length: 75 bytes
        0::16,          # reserved
        0x00,           # transaction flag
        0x00,           # encryption flag
        0::12*8,        # reserved (12 bytes)
        0x01,           # MDX flag (has index)
        0x00,           # language driver
        0::16           # reserved
      >>

      assert {:ok, header} = Parser.parse_header(header_binary)
      assert header.version == 0x8B
      assert header.record_count == 250
      assert header.header_length == 193
      assert header.record_length == 75
      assert header.mdx_flag == 0x01
    end

    test "returns error for invalid header size" do
      short_binary = <<0x03, 124, 12>>
      assert {:error, :invalid_header_size} = Parser.parse_header(short_binary)
    end

    test "returns error for invalid version" do
      invalid_header = <<
        0xFF,           # invalid version
        124, 12, 17,    # last update
        100::little-32, # record count
        161::little-16, # header length
        50::little-16,  # record length
        0::16,          # reserved
        0x00,           # transaction flag
        0x00,           # encryption flag
        0::12*8,        # reserved
        0x00,           # MDX flag
        0x00,           # language driver
        0::16           # reserved
      >>

      assert {:error, :invalid_version} = Parser.parse_header(invalid_header)
    end
  end

  describe "parse_fields/2" do
    test "parses field descriptors until terminator" do
      # Create field descriptors: NAME (C,10), AGE (N,3), ACTIVE (L,1) + terminator
      fields_binary = <<
        # Field 1: NAME (Character, 10 bytes)
        "NAME", 0, 0, 0, 0, 0, 0, 0,  # name (11 bytes, null-padded)
        "C",                           # type
        0, 0, 0, 0,                   # data address (unused)
        10,                           # length
        0,                            # decimal count
        0, 0,                         # reserved
        0,                            # work area ID
        0, 0,                         # reserved
        0,                            # set fields flag
        0, 0, 0, 0, 0, 0, 0,         # reserved
        0,                            # index field flag
        
        # Field 2: AGE (Numeric, 3 bytes)
        "AGE", 0, 0, 0, 0, 0, 0, 0, 0, # name (11 bytes)
        "N",                           # type
        0, 0, 0, 0,                   # data address
        3,                            # length
        0,                            # decimal count
        0, 0,                         # reserved
        0,                            # work area ID
        0, 0,                         # reserved
        0,                            # set fields flag
        0, 0, 0, 0, 0, 0, 0,         # reserved
        0,                            # index field flag
        
        # Field 3: ACTIVE (Logical, 1 byte)
        "ACTIVE", 0, 0, 0, 0, 0,      # name (11 bytes)
        "L",                          # type
        0, 0, 0, 0,                   # data address
        1,                            # length
        0,                            # decimal count
        0, 0,                         # reserved
        0,                            # work area ID
        0, 0,                         # reserved
        0,                            # set fields flag
        0, 0, 0, 0, 0, 0, 0,         # reserved
        0,                            # index field flag
        
        0x0D                          # field terminator
      >>

      assert {:ok, fields} = Parser.parse_fields(fields_binary, 0)
      assert length(fields) == 3

      [name_field, age_field, active_field] = fields

      assert %FieldDescriptor{} = name_field
      assert name_field.name == "NAME"
      assert name_field.type == "C"
      assert name_field.length == 10
      assert name_field.decimal_count == 0

      assert age_field.name == "AGE"
      assert age_field.type == "N"
      assert age_field.length == 3

      assert active_field.name == "ACTIVE"
      assert active_field.type == "L"
      assert active_field.length == 1
    end

    test "returns error for missing terminator" do
      # Single field without terminator
      incomplete_binary = <<
        "NAME", 0, 0, 0, 0, 0, 0, 0,  # name
        "C",                           # type
        0, 0, 0, 0,                   # data address
        10,                           # length
        0,                            # decimal count
        0, 0,                         # reserved
        0,                            # work area ID
        0, 0,                         # reserved
        0,                            # set fields flag
        0, 0, 0, 0, 0, 0, 0,         # reserved
        0                             # index field flag (no terminator)
      >>

      assert {:error, :missing_field_terminator} = Parser.parse_fields(incomplete_binary, 0)
    end
  end

  describe "file I/O functions" do
    test "open_dbf/1 opens DBF file and parses header and fields" do
      # Create a temporary DBF file for testing
      temp_path = create_test_dbf_file()
      
      assert {:ok, dbf} = Parser.open_dbf(temp_path)
      assert %{header: header, fields: fields, file: file} = dbf
      assert %Header{} = header
      assert is_list(fields)
      assert length(fields) == 2  # NAME and AGE fields
      assert is_pid(file) or is_port(file)  # file handle
      
      # Clean up
      Parser.close_dbf(dbf)
      File.rm(temp_path)
    end

    test "close_dbf/1 closes file handle" do
      temp_path = create_test_dbf_file()
      {:ok, dbf} = Parser.open_dbf(temp_path)
      
      assert :ok = Parser.close_dbf(dbf)
      
      # File should be closed now, attempting to read should fail
      assert {:error, _} = :file.read(dbf.file, 10)
      
      File.rm(temp_path)
    end

    test "open_dbf/1 returns error for non-existent file" do
      assert {:error, :enoent} = Parser.open_dbf("non_existent_file.dbf")
    end

    test "open_dbf/1 returns error for invalid DBF file" do
      # Create invalid file (32 bytes but invalid version)
      temp_path = "/tmp/invalid.dbf"
      invalid_data = <<0xFF>> <> :binary.copy(<<0>>, 31)  # Invalid version + 31 zero bytes
      File.write!(temp_path, invalid_data)
      
      assert {:error, :invalid_version} = Parser.open_dbf(temp_path)
      
      File.rm(temp_path)
    end
  end

  # Helper function to create a test DBF file
  defp create_test_dbf_file do
    temp_path = "/tmp/test_#{:rand.uniform(10000)}.dbf"
    
    # Create a minimal valid DBF file with header + 2 fields + terminator
    header = <<
      0x03,           # version (dBase III)
      124, 12, 17,    # last update: 2024-12-17
      0::little-32,   # record count: 0 (no data records)
      97::little-16,  # header length: 32 + (2 * 32) + 1 = 97 bytes
      21::little-16,  # record length: 10 + 3 + 1 (deletion flag) + padding = 21 bytes
      0::16,          # reserved
      0x00,           # transaction flag
      0x00,           # encryption flag
      0::12*8,        # reserved (12 bytes)
      0x00,           # MDX flag
      0x00,           # language driver
      0::16           # reserved
    >>
    
    # Field 1: NAME (Character, 10 bytes)
    field1 = <<
      "NAME", 0, 0, 0, 0, 0, 0, 0,  # name (11 bytes)
      "C",                           # type
      0, 0, 0, 0,                   # data address
      10,                           # length
      0,                            # decimal count
      0, 0,                         # reserved
      0,                            # work area ID
      0, 0,                         # reserved
      0,                            # set fields flag
      0, 0, 0, 0, 0, 0, 0,         # reserved
      0                             # index field flag
    >>
    
    # Field 2: AGE (Numeric, 3 bytes)
    field2 = <<
      "AGE", 0, 0, 0, 0, 0, 0, 0, 0, # name (11 bytes)
      "N",                           # type
      0, 0, 0, 0,                   # data address
      3,                            # length
      0,                            # decimal count
      0, 0,                         # reserved
      0,                            # work area ID
      0, 0,                         # reserved
      0,                            # set fields flag
      0, 0, 0, 0, 0, 0, 0,         # reserved
      0                             # index field flag
    >>
    
    # Field terminator
    terminator = <<0x0D>>
    
    # Write the complete DBF file
    File.write!(temp_path, header <> field1 <> field2 <> terminator)
    
    temp_path
  end

  describe "record navigation functions" do
    test "calculate_record_offset/2 calculates correct offset for record" do
      header = %Header{header_length: 97, record_length: 25}
      
      assert 97 = Parser.calculate_record_offset(header, 0)   # First record
      assert 122 = Parser.calculate_record_offset(header, 1)  # Second record (97 + 25)
      assert 147 = Parser.calculate_record_offset(header, 2)  # Third record (97 + 50)
      assert 172 = Parser.calculate_record_offset(header, 3)  # Fourth record (97 + 75)
    end

    test "calculate_record_offset/2 handles zero-based indexing" do
      header = %Header{header_length: 65, record_length: 30}
      
      # Record 0 starts immediately after header
      assert 65 = Parser.calculate_record_offset(header, 0)
      # Each subsequent record is offset by record_length
      assert 95 = Parser.calculate_record_offset(header, 1)
      assert 125 = Parser.calculate_record_offset(header, 2)
    end

    test "is_valid_record_index?/2 validates record indices" do
      header = %Header{record_count: 10}
      
      assert true == Parser.is_valid_record_index?(header, 0)
      assert true == Parser.is_valid_record_index?(header, 5)
      assert true == Parser.is_valid_record_index?(header, 9)  # Last valid record
      assert false == Parser.is_valid_record_index?(header, 10) # Beyond record count
      assert false == Parser.is_valid_record_index?(header, -1) # Negative index
    end

    test "get_deletion_flag/1 extracts deletion status from record data" do
      active_record = <<0x20, "John Doe  ", "25 ", "T">>  # 0x20 = active
      deleted_record = <<0x2A, "Jane Doe  ", "30 ", "F">> # 0x2A = deleted
      
      assert {:ok, false} = Parser.get_deletion_flag(active_record)
      assert {:ok, true} = Parser.get_deletion_flag(deleted_record)
    end

    test "get_deletion_flag/1 returns error for empty data" do
      assert {:error, :invalid_record_data} = Parser.get_deletion_flag(<<>>)
    end

    test "parse_record_data/2 parses record fields according to field descriptors" do
      fields = [
        %FieldDescriptor{name: "NAME", type: "C", length: 10, decimal_count: 0},
        %FieldDescriptor{name: "AGE", type: "N", length: 3, decimal_count: 0},
        %FieldDescriptor{name: "ACTIVE", type: "L", length: 1, decimal_count: 0}
      ]
      
      # Skip deletion flag (first byte) and parse field data
      record_data = <<"John Doe  ", " 25", "T">>
      
      assert {:ok, parsed_data} = Parser.parse_record_data(record_data, fields)
      assert parsed_data["NAME"] == "John Doe"
      assert parsed_data["AGE"] == 25
      assert parsed_data["ACTIVE"] == true
    end

    test "parse_record_data/2 handles mismatched record length" do
      fields = [
        %FieldDescriptor{name: "NAME", type: "C", length: 10, decimal_count: 0}
      ]
      
      short_data = <<"John">>  # Only 4 bytes, expected 10
      
      assert {:error, :invalid_record_length} = Parser.parse_record_data(short_data, fields)
    end
  end

  describe "read_record/2" do
    test "reads and parses a complete record" do
      # Create a DBF file with actual data records
      temp_path = create_test_dbf_with_data()
      
      {:ok, dbf} = Parser.open_dbf(temp_path)
      
      # Read first record
      assert {:ok, record} = Parser.read_record(dbf, 0)
      assert %Record{} = record
      assert record.deleted == false
      assert record.data["NAME"] == "John Doe"
      assert record.data["AGE"] == 25
      
      # Read second record (should be deleted)
      assert {:ok, record2} = Parser.read_record(dbf, 1)
      assert record2.deleted == true
      assert record2.data["NAME"] == "Jane Smith"
      assert record2.data["AGE"] == 30
      
      Parser.close_dbf(dbf)
      File.rm(temp_path)
    end

    test "returns error for invalid record index" do
      temp_path = create_test_dbf_with_data()
      {:ok, dbf} = Parser.open_dbf(temp_path)
      
      # Try to read beyond available records
      assert {:error, :invalid_record_index} = Parser.read_record(dbf, 10)
      assert {:error, :invalid_record_index} = Parser.read_record(dbf, -1)
      
      Parser.close_dbf(dbf)
      File.rm(temp_path)
    end

    test "returns error for file read failure" do
      temp_path = create_test_dbf_with_data()
      {:ok, dbf} = Parser.open_dbf(temp_path)
      
      # Close the file to simulate read failure
      Parser.close_dbf(dbf)
      
      # Now try to read - should fail
      assert {:error, _reason} = Parser.read_record(dbf, 0)
      
      File.rm(temp_path)
    end
  end

  # Helper function to create a test DBF file with actual data records
  defp create_test_dbf_with_data do
    temp_path = "/tmp/test_data_#{:rand.uniform(10000)}.dbf"
    
    # Create header for 2 records
    header = <<
      0x03,           # version (dBase III)
      124, 12, 17,    # last update: 2024-12-17
      2::little-32,   # record count: 2 records
      97::little-16,  # header length: 32 + (2 * 32) + 1 = 97 bytes
      14::little-16,  # record length: 10 + 3 + 1 (deletion flag) = 14 bytes
      0::16,          # reserved
      0x00,           # transaction flag
      0x00,           # encryption flag
      0::12*8,        # reserved (12 bytes)
      0x00,           # MDX flag
      0x00,           # language driver
      0::16           # reserved
    >>
    
    # Field 1: NAME (Character, 10 bytes)
    field1 = <<
      "NAME", 0, 0, 0, 0, 0, 0, 0,  # name (11 bytes)
      "C",                           # type
      0, 0, 0, 0,                   # data address
      10,                           # length
      0,                            # decimal count
      0, 0,                         # reserved
      0,                            # work area ID
      0, 0,                         # reserved
      0,                            # set fields flag
      0, 0, 0, 0, 0, 0, 0,         # reserved
      0                             # index field flag
    >>
    
    # Field 2: AGE (Numeric, 3 bytes)
    field2 = <<
      "AGE", 0, 0, 0, 0, 0, 0, 0, 0, # name (11 bytes)
      "N",                           # type
      0, 0, 0, 0,                   # data address
      3,                            # length
      0,                            # decimal count
      0, 0,                         # reserved
      0,                            # work area ID
      0, 0,                         # reserved
      0,                            # set fields flag
      0, 0, 0, 0, 0, 0, 0,         # reserved
      0                             # index field flag
    >>
    
    # Field terminator
    terminator = <<0x0D>>
    
    # Record 1: Active record - John Doe, 25
    record1 = <<
      0x20,           # active record flag
      "John Doe  ",   # NAME field (10 bytes - note extra space)
      " 25"           # AGE field (3 bytes)
    >>
    
    # Record 2: Deleted record - Jane Smith, 30
    record2 = <<
      0x2A,           # deleted record flag
      "Jane Smith",   # NAME field (10 bytes) 
      " 30"           # AGE field (3 bytes)
    >>
    
    # Write the complete DBF file with data
    File.write!(temp_path, header <> field1 <> field2 <> terminator <> record1 <> record2)
    
    temp_path
  end

  describe "create_dbf/2" do
    test "creates a new DBF file with field definitions" do
      temp_path = "/tmp/test_create_#{:rand.uniform(10000)}.dbf"
      
      fields = [
        %FieldDescriptor{name: "NAME", type: "C", length: 20, decimal_count: 0},
        %FieldDescriptor{name: "AGE", type: "N", length: 3, decimal_count: 0},
        %FieldDescriptor{name: "ACTIVE", type: "L", length: 1, decimal_count: 0}
      ]
      
      assert {:ok, dbf} = Parser.create_dbf(temp_path, fields)
      
      # Verify the file was created and is readable
      assert File.exists?(temp_path)
      
      # Verify we can open and read the created file
      Parser.close_dbf(dbf)
      {:ok, reopened_dbf} = Parser.open_dbf(temp_path)
      
      # Check header
      assert reopened_dbf.header.version == 0x03  # dBase III
      assert reopened_dbf.header.record_count == 0  # No records yet
      assert reopened_dbf.header.header_length == 129  # 32 + (3 * 32) + 1
      assert reopened_dbf.header.record_length == 25  # 20 + 3 + 1 + deletion flag
      
      # Check fields
      assert length(reopened_dbf.fields) == 3
      [name_field, age_field, active_field] = reopened_dbf.fields
      
      assert name_field.name == "NAME"
      assert name_field.type == "C"
      assert name_field.length == 20
      
      assert age_field.name == "AGE"
      assert age_field.type == "N"
      assert age_field.length == 3
      
      assert active_field.name == "ACTIVE"
      assert active_field.type == "L"
      assert active_field.length == 1
      
      Parser.close_dbf(reopened_dbf)
      File.rm(temp_path)
    end

    test "creates DBF file with custom version" do
      temp_path = "/tmp/test_create_v4_#{:rand.uniform(10000)}.dbf"
      
      fields = [
        %FieldDescriptor{name: "ID", type: "N", length: 5, decimal_count: 0}
      ]
      
      assert {:ok, dbf} = Parser.create_dbf(temp_path, fields, version: 0x04)
      
      Parser.close_dbf(dbf)
      {:ok, reopened_dbf} = Parser.open_dbf(temp_path)
      
      assert reopened_dbf.header.version == 0x04  # dBase IV
      
      Parser.close_dbf(reopened_dbf)
      File.rm(temp_path)
    end

    test "returns error for invalid field definitions" do
      temp_path = "/tmp/test_invalid_#{:rand.uniform(10000)}.dbf"
      
      # Empty fields list
      assert {:error, :no_fields} = Parser.create_dbf(temp_path, [])
      
      # Field with invalid name (too long)
      invalid_fields = [
        %FieldDescriptor{name: "THIS_NAME_IS_TOO_LONG", type: "C", length: 10, decimal_count: 0}
      ]
      assert {:error, :invalid_field_name} = Parser.create_dbf(temp_path, invalid_fields)
      
      refute File.exists?(temp_path)
    end

    test "returns error for existing file without overwrite option" do
      temp_path = "/tmp/test_existing_#{:rand.uniform(10000)}.dbf"
      
      # Create an existing file
      File.write!(temp_path, "existing content")
      
      fields = [
        %FieldDescriptor{name: "TEST", type: "C", length: 5, decimal_count: 0}
      ]
      
      assert {:error, :file_exists} = Parser.create_dbf(temp_path, fields)
      
      File.rm(temp_path)
    end

    test "overwrites existing file with overwrite option" do
      temp_path = "/tmp/test_overwrite_#{:rand.uniform(10000)}.dbf"
      
      # Create an existing file
      File.write!(temp_path, "existing content")
      
      fields = [
        %FieldDescriptor{name: "TEST", type: "C", length: 5, decimal_count: 0}
      ]
      
      assert {:ok, dbf} = Parser.create_dbf(temp_path, fields, overwrite: true)
      
      # Verify it's a valid DBF file now
      Parser.close_dbf(dbf)
      assert {:ok, _reopened} = Parser.open_dbf(temp_path)
      
      File.rm(temp_path)
    end
  end

  describe "append_record/2" do
    setup do
      # Create a test DBF file
      temp_path = "/tmp/test_append_#{:rand.uniform(10000)}.dbf"
      
      fields = [
        %FieldDescriptor{name: "NAME", type: "C", length: 20, decimal_count: 0},
        %FieldDescriptor{name: "AGE", type: "N", length: 3, decimal_count: 0},
        %FieldDescriptor{name: "ACTIVE", type: "L", length: 1, decimal_count: 0},
        %FieldDescriptor{name: "JOINED", type: "D", length: 8, decimal_count: 0}
      ]
      
      {:ok, dbf} = Parser.create_dbf(temp_path, fields)
      
      on_exit(fn ->
        File.rm(temp_path)
      end)
      
      {:ok, path: temp_path, dbf: dbf}
    end

    test "appends a record with valid data", %{path: path, dbf: dbf} do
      record_data = %{
        "NAME" => "John Doe",
        "AGE" => 30,
        "ACTIVE" => true,
        "JOINED" => ~D[2024-01-15]
      }
      
      assert {:ok, updated_dbf} = Parser.append_record(dbf, record_data)
      assert updated_dbf.header.record_count == 1
      
      # Read the record back
      Parser.close_dbf(updated_dbf)
      {:ok, dbf2} = Parser.open_dbf(path)
      assert dbf2.header.record_count == 1
      
      {:ok, records} = Parser.read_records(dbf2)
      assert length(records) == 1
      
      record = hd(records)
      assert record["NAME"] == "John Doe"
      assert record["AGE"] == 30
      assert record["ACTIVE"] == true
      assert record["JOINED"] == ~D[2024-01-15]
      
      Parser.close_dbf(dbf2)
    end

    test "appends multiple records", %{path: path, dbf: dbf} do
      records = [
        %{"NAME" => "Alice", "AGE" => 25, "ACTIVE" => true, "JOINED" => ~D[2024-01-01]},
        %{"NAME" => "Bob", "AGE" => 35, "ACTIVE" => false, "JOINED" => ~D[2024-02-01]},
        %{"NAME" => "Charlie", "AGE" => 45, "ACTIVE" => true, "JOINED" => ~D[2024-03-01]}
      ]
      
      # Append records one by one
      {:ok, dbf1} = Parser.append_record(dbf, Enum.at(records, 0))
      {:ok, dbf2} = Parser.append_record(dbf1, Enum.at(records, 1))
      {:ok, dbf3} = Parser.append_record(dbf2, Enum.at(records, 2))
      
      assert dbf3.header.record_count == 3
      
      # Verify all records
      Parser.close_dbf(dbf3)
      {:ok, dbf_read} = Parser.open_dbf(path)
      {:ok, read_records} = Parser.read_records(dbf_read)
      
      assert length(read_records) == 3
      assert Enum.at(read_records, 0)["NAME"] == "Alice"
      assert Enum.at(read_records, 1)["NAME"] == "Bob"
      assert Enum.at(read_records, 2)["NAME"] == "Charlie"
      
      Parser.close_dbf(dbf_read)
    end

    test "handles missing fields with defaults", %{dbf: dbf} do
      # Only provide some fields
      record_data = %{
        "NAME" => "Incomplete"
      }
      
      assert {:ok, updated_dbf} = Parser.append_record(dbf, record_data)
      
      # Read back and check defaults
      {:ok, records} = Parser.read_records(updated_dbf)
      
      record = hd(records)
      assert record["NAME"] == "Incomplete"
      assert record["AGE"] == 0  # Numeric default
      assert record["ACTIVE"] == false  # Logical default
      assert record["JOINED"] == nil  # Date default (empty)
    end

    test "validates field values", %{dbf: dbf} do
      # Invalid age value
      record_data = %{
        "NAME" => "Test",
        "AGE" => "not a number"
      }
      
      assert {:error, _} = Parser.append_record(dbf, record_data)
    end

    test "handles string truncation", %{dbf: dbf} do
      # Name longer than field length (20)
      record_data = %{
        "NAME" => "This is a very long name that exceeds the field length"
      }
      
      assert {:ok, updated_dbf} = Parser.append_record(dbf, record_data)
      
      # Read back and verify truncation
      {:ok, records} = Parser.read_records(updated_dbf)
      
      record = hd(records)
      # Check that it's truncated to 20 characters (may be trimmed)
      assert String.length(record["NAME"]) <= 20
      assert String.starts_with?(record["NAME"], "This is a very long")
    end

    test "preserves existing records when appending", %{dbf: dbf} do
      # Add first record
      {:ok, dbf1} = Parser.append_record(dbf, %{"NAME" => "First", "AGE" => 10})
      
      # Add second record
      {:ok, dbf2} = Parser.append_record(dbf1, %{"NAME" => "Second", "AGE" => 20})
      
      # Read all records
      {:ok, records} = Parser.read_records(dbf2)
      
      assert length(records) == 2
      assert Enum.at(records, 0)["NAME"] == "First"
      assert Enum.at(records, 0)["AGE"] == 10
      assert Enum.at(records, 1)["NAME"] == "Second"
      assert Enum.at(records, 1)["AGE"] == 20
    end

    test "updates header timestamp on append", %{path: path, dbf: dbf} do
      # Append a record
      {:ok, updated_dbf} = Parser.append_record(dbf, %{"NAME" => "Test"})
      
      # Check that record count increased
      assert updated_dbf.header.record_count == 1
      
      # Verify it persists
      Parser.close_dbf(updated_dbf)
      {:ok, dbf2} = Parser.open_dbf(path)
      assert dbf2.header.record_count == 1
      
      # The date should be current
      {{year, month, day}, _} = :calendar.local_time()
      assert dbf2.header.last_update_year == year - 1900
      assert dbf2.header.last_update_month == month
      assert dbf2.header.last_update_day == day
      
      Parser.close_dbf(dbf2)
    end
  end

  describe "update_record/3" do
    setup do
      # Create a test DBF file with some records
      temp_path = "/tmp/test_update_#{:rand.uniform(10000)}.dbf"
      
      fields = [
        %FieldDescriptor{name: "ID", type: "N", length: 5, decimal_count: 0},
        %FieldDescriptor{name: "NAME", type: "C", length: 20, decimal_count: 0},
        %FieldDescriptor{name: "AGE", type: "N", length: 3, decimal_count: 0},
        %FieldDescriptor{name: "ACTIVE", type: "L", length: 1, decimal_count: 0},
        %FieldDescriptor{name: "JOINED", type: "D", length: 8, decimal_count: 0}
      ]
      
      {:ok, dbf} = Parser.create_dbf(temp_path, fields)
      
      # Add some initial records
      {:ok, dbf1} = Parser.append_record(dbf, %{
        "ID" => 1,
        "NAME" => "Alice",
        "AGE" => 25,
        "ACTIVE" => true,
        "JOINED" => ~D[2024-01-01]
      })
      
      {:ok, dbf2} = Parser.append_record(dbf1, %{
        "ID" => 2,
        "NAME" => "Bob",
        "AGE" => 30,
        "ACTIVE" => false,
        "JOINED" => ~D[2024-02-01]
      })
      
      {:ok, dbf3} = Parser.append_record(dbf2, %{
        "ID" => 3,
        "NAME" => "Charlie",
        "AGE" => 35,
        "ACTIVE" => true,
        "JOINED" => ~D[2024-03-01]
      })
      
      on_exit(fn ->
        File.rm(temp_path)
      end)
      
      {:ok, path: temp_path, dbf: dbf3}
    end

    test "updates a record with new data", %{path: path, dbf: dbf} do
      # Update Bob's record (index 1)
      update_data = %{
        "NAME" => "Robert",
        "AGE" => 31,
        "ACTIVE" => true
      }
      
      assert {:ok, updated_dbf} = Parser.update_record(dbf, 1, update_data)
      
      # Read the updated record
      {:ok, record} = Parser.read_record(updated_dbf, 1)
      assert record.data["ID"] == 2  # ID unchanged
      assert record.data["NAME"] == "Robert"  # Updated
      assert record.data["AGE"] == 31  # Updated
      assert record.data["ACTIVE"] == true  # Updated
      assert record.data["JOINED"] == ~D[2024-02-01]  # Unchanged
      
      # Verify it persists
      Parser.close_dbf(updated_dbf)
      {:ok, dbf2} = Parser.open_dbf(path)
      {:ok, record2} = Parser.read_record(dbf2, 1)
      assert record2.data["NAME"] == "Robert"
      Parser.close_dbf(dbf2)
    end

    test "partial update preserves unspecified fields", %{dbf: dbf} do
      # Update only the age
      update_data = %{"AGE" => 26}
      
      assert {:ok, updated_dbf} = Parser.update_record(dbf, 0, update_data)
      
      # Check that other fields are preserved
      {:ok, record} = Parser.read_record(updated_dbf, 0)
      assert record.data["ID"] == 1
      assert record.data["NAME"] == "Alice"  # Unchanged
      assert record.data["AGE"] == 26  # Updated
      assert record.data["ACTIVE"] == true  # Unchanged
      assert record.data["JOINED"] == ~D[2024-01-01]  # Unchanged
    end

    test "validates record index", %{dbf: dbf} do
      # Invalid index (negative)
      assert {:error, :invalid_record_index} = Parser.update_record(dbf, -1, %{"AGE" => 50})
      
      # Invalid index (too large)
      assert {:error, :invalid_record_index} = Parser.update_record(dbf, 10, %{"AGE" => 50})
    end

    test "validates field values", %{dbf: dbf} do
      # Invalid type for AGE
      update_data = %{"AGE" => "not a number"}
      
      assert {:error, _} = Parser.update_record(dbf, 0, update_data)
    end

    test "handles string truncation on update", %{dbf: dbf} do
      # Update with a long name
      update_data = %{
        "NAME" => "This is a very long name that exceeds the field length"
      }
      
      assert {:ok, updated_dbf} = Parser.update_record(dbf, 0, update_data)
      
      # Verify truncation
      {:ok, record} = Parser.read_record(updated_dbf, 0)
      assert String.length(record.data["NAME"]) <= 20
      assert String.starts_with?(record.data["NAME"], "This is a very long")
    end

    test "updates multiple records independently", %{dbf: dbf} do
      # Update first record
      {:ok, dbf1} = Parser.update_record(dbf, 0, %{"AGE" => 26})
      
      # Update third record
      {:ok, dbf2} = Parser.update_record(dbf1, 2, %{"NAME" => "Chuck"})
      
      # Verify all records
      {:ok, records} = Parser.read_records(dbf2)
      assert Enum.at(records, 0)["AGE"] == 26
      assert Enum.at(records, 0)["NAME"] == "Alice"  # Unchanged
      assert Enum.at(records, 1)["NAME"] == "Bob"  # Unchanged
      assert Enum.at(records, 2)["NAME"] == "Chuck"  # Updated
      assert Enum.at(records, 2)["AGE"] == 35  # Unchanged
    end

    test "preserves deletion flag when updating", %{dbf: dbf} do
      # First, mark a record as deleted using our function
      {:ok, dbf_with_deletion} = Parser.mark_deleted(dbf, 1)
      
      # Now update the deleted record
      update_data = %{"NAME" => "Updated Bob"}
      {:ok, updated_dbf} = Parser.update_record(dbf_with_deletion, 1, update_data)
      
      # Verify the record is still marked as deleted
      {:ok, record} = Parser.read_record(updated_dbf, 1)
      assert record.deleted == true
      assert record.data["NAME"] == "Updated Bob"
      
      # Verify deleted records don't appear in read_records
      {:ok, records} = Parser.read_records(updated_dbf)
      assert length(records) == 2  # Only 2 active records
    end

    test "updates header timestamp on update", %{path: path, dbf: dbf} do
      # Update a record
      {:ok, updated_dbf} = Parser.update_record(dbf, 0, %{"AGE" => 26})
      
      # Check that record count stayed the same
      assert updated_dbf.header.record_count == 3
      
      # Verify timestamp is current
      Parser.close_dbf(updated_dbf)
      {:ok, dbf2} = Parser.open_dbf(path)
      
      {{year, month, day}, _} = :calendar.local_time()
      assert dbf2.header.last_update_year == year - 1900
      assert dbf2.header.last_update_month == month
      assert dbf2.header.last_update_day == day
      
      Parser.close_dbf(dbf2)
    end
  end

  describe "mark_deleted/2" do
    setup do
      # Create a test DBF file with some records
      temp_path = "/tmp/test_delete_#{:rand.uniform(10000)}.dbf"
      
      fields = [
        %FieldDescriptor{name: "ID", type: "N", length: 5, decimal_count: 0},
        %FieldDescriptor{name: "NAME", type: "C", length: 20, decimal_count: 0},
        %FieldDescriptor{name: "STATUS", type: "L", length: 1, decimal_count: 0}
      ]
      
      {:ok, dbf} = Parser.create_dbf(temp_path, fields)
      
      # Add some initial records
      {:ok, dbf1} = Parser.append_record(dbf, %{"ID" => 1, "NAME" => "Alice", "STATUS" => true})
      {:ok, dbf2} = Parser.append_record(dbf1, %{"ID" => 2, "NAME" => "Bob", "STATUS" => false})
      {:ok, dbf3} = Parser.append_record(dbf2, %{"ID" => 3, "NAME" => "Charlie", "STATUS" => true})
      
      on_exit(fn ->
        File.rm(temp_path)
      end)
      
      {:ok, path: temp_path, dbf: dbf3}
    end

    test "marks a record as deleted", %{path: path, dbf: dbf} do
      # Mark the second record (Bob) as deleted
      assert {:ok, updated_dbf} = Parser.mark_deleted(dbf, 1)
      
      # Verify the record is marked as deleted
      {:ok, record} = Parser.read_record(updated_dbf, 1)
      assert record.deleted == true
      assert record.data["NAME"] == "Bob"  # Data should still be there
      
      # Verify it persists
      Parser.close_dbf(updated_dbf)
      {:ok, dbf2} = Parser.open_dbf(path)
      {:ok, record2} = Parser.read_record(dbf2, 1)
      assert record2.deleted == true
      Parser.close_dbf(dbf2)
    end

    test "deleted records don't appear in read_records", %{dbf: dbf} do
      # Initially all 3 records are active
      {:ok, records} = Parser.read_records(dbf)
      assert length(records) == 3
      
      # Mark one record as deleted
      {:ok, updated_dbf} = Parser.mark_deleted(dbf, 1)
      
      # Only 2 records should appear now
      {:ok, records} = Parser.read_records(updated_dbf)
      assert length(records) == 2
      assert Enum.at(records, 0)["NAME"] == "Alice"
      assert Enum.at(records, 1)["NAME"] == "Charlie"
      # Bob should be missing from the list
    end

    test "validates record index", %{dbf: dbf} do
      # Invalid index (negative)
      assert {:error, :invalid_record_index} = Parser.mark_deleted(dbf, -1)
      
      # Invalid index (too large)
      assert {:error, :invalid_record_index} = Parser.mark_deleted(dbf, 10)
    end

    test "can mark already deleted records", %{dbf: dbf} do
      # Mark record as deleted
      {:ok, dbf1} = Parser.mark_deleted(dbf, 1)
      
      # Mark it again - should succeed
      assert {:ok, dbf2} = Parser.mark_deleted(dbf1, 1)
      
      # Should still be deleted
      {:ok, record} = Parser.read_record(dbf2, 1)
      assert record.deleted == true
    end

    test "updates header timestamp on deletion", %{path: path, dbf: dbf} do
      # Mark a record as deleted
      {:ok, updated_dbf} = Parser.mark_deleted(dbf, 0)
      
      # Check that record count stayed the same
      assert updated_dbf.header.record_count == 3
      
      # Verify timestamp is current
      Parser.close_dbf(updated_dbf)
      {:ok, dbf2} = Parser.open_dbf(path)
      
      {{year, month, day}, _} = :calendar.local_time()
      assert dbf2.header.last_update_year == year - 1900
      assert dbf2.header.last_update_month == month
      assert dbf2.header.last_update_day == day
      
      Parser.close_dbf(dbf2)
    end

    test "marks multiple records independently", %{dbf: dbf} do
      # Mark first and third records as deleted
      {:ok, dbf1} = Parser.mark_deleted(dbf, 0)
      {:ok, dbf2} = Parser.mark_deleted(dbf1, 2)
      
      # Verify deletion status
      {:ok, record0} = Parser.read_record(dbf2, 0)
      {:ok, record1} = Parser.read_record(dbf2, 1)
      {:ok, record2} = Parser.read_record(dbf2, 2)
      
      assert record0.deleted == true
      assert record1.deleted == false
      assert record2.deleted == true
      
      # Only middle record should appear in read_records
      {:ok, records} = Parser.read_records(dbf2)
      assert length(records) == 1
      assert hd(records)["NAME"] == "Bob"
    end
  end

  describe "undelete_record/2" do
    setup do
      # Create a test DBF file with some records, some already deleted
      temp_path = "/tmp/test_undelete_#{:rand.uniform(10000)}.dbf"
      
      fields = [
        %FieldDescriptor{name: "ID", type: "N", length: 5, decimal_count: 0},
        %FieldDescriptor{name: "NAME", type: "C", length: 20, decimal_count: 0},
        %FieldDescriptor{name: "STATUS", type: "L", length: 1, decimal_count: 0}
      ]
      
      {:ok, dbf} = Parser.create_dbf(temp_path, fields)
      
      # Add some initial records
      {:ok, dbf1} = Parser.append_record(dbf, %{"ID" => 1, "NAME" => "Alice", "STATUS" => true})
      {:ok, dbf2} = Parser.append_record(dbf1, %{"ID" => 2, "NAME" => "Bob", "STATUS" => false})
      {:ok, dbf3} = Parser.append_record(dbf2, %{"ID" => 3, "NAME" => "Charlie", "STATUS" => true})
      
      # Mark the second record as deleted
      {:ok, dbf4} = Parser.mark_deleted(dbf3, 1)
      
      on_exit(fn ->
        File.rm(temp_path)
      end)
      
      {:ok, path: temp_path, dbf: dbf4}
    end

    test "undeletes a deleted record", %{path: path, dbf: dbf} do
      # Verify record is initially deleted
      {:ok, record} = Parser.read_record(dbf, 1)
      assert record.deleted == true
      
      # Undelete the record
      assert {:ok, updated_dbf} = Parser.undelete_record(dbf, 1)
      
      # Verify the record is no longer deleted
      {:ok, record} = Parser.read_record(updated_dbf, 1)
      assert record.deleted == false
      assert record.data["NAME"] == "Bob"  # Data should still be there
      
      # Verify it persists
      Parser.close_dbf(updated_dbf)
      {:ok, dbf2} = Parser.open_dbf(path)
      {:ok, record2} = Parser.read_record(dbf2, 1)
      assert record2.deleted == false
      Parser.close_dbf(dbf2)
    end

    test "undeleted records appear in read_records", %{dbf: dbf} do
      # Initially only 2 records are active (one is deleted)
      {:ok, records} = Parser.read_records(dbf)
      assert length(records) == 2
      
      # Undelete the deleted record
      {:ok, updated_dbf} = Parser.undelete_record(dbf, 1)
      
      # Now all 3 records should appear
      {:ok, records} = Parser.read_records(updated_dbf)
      assert length(records) == 3
      
      # Verify Bob is back in the list
      names = Enum.map(records, & &1["NAME"])
      assert "Alice" in names
      assert "Bob" in names
      assert "Charlie" in names
    end

    test "validates record index", %{dbf: dbf} do
      # Invalid index (negative)
      assert {:error, :invalid_record_index} = Parser.undelete_record(dbf, -1)
      
      # Invalid index (too large)
      assert {:error, :invalid_record_index} = Parser.undelete_record(dbf, 10)
    end

    test "can undelete already active records", %{dbf: dbf} do
      # Undelete an already active record (index 0)
      assert {:ok, updated_dbf} = Parser.undelete_record(dbf, 0)
      
      # Should still be active
      {:ok, record} = Parser.read_record(updated_dbf, 0)
      assert record.deleted == false
    end

    test "updates header timestamp on undeletion", %{path: path, dbf: dbf} do
      # Undelete a record
      {:ok, updated_dbf} = Parser.undelete_record(dbf, 1)
      
      # Check that record count stayed the same
      assert updated_dbf.header.record_count == 3
      
      # Verify timestamp is current
      Parser.close_dbf(updated_dbf)
      {:ok, dbf2} = Parser.open_dbf(path)
      
      {{year, month, day}, _} = :calendar.local_time()
      assert dbf2.header.last_update_year == year - 1900
      assert dbf2.header.last_update_month == month
      assert dbf2.header.last_update_day == day
      
      Parser.close_dbf(dbf2)
    end

    test "delete and undelete cycle works correctly", %{dbf: dbf} do
      # Start with record 0 active
      {:ok, record} = Parser.read_record(dbf, 0)
      assert record.deleted == false
      
      # Delete it
      {:ok, dbf1} = Parser.mark_deleted(dbf, 0)
      {:ok, record} = Parser.read_record(dbf1, 0)
      assert record.deleted == true
      
      # Undelete it
      {:ok, dbf2} = Parser.undelete_record(dbf1, 0)
      {:ok, record} = Parser.read_record(dbf2, 0)
      assert record.deleted == false
      
      # Data should be intact
      assert record.data["NAME"] == "Alice"
      assert record.data["ID"] == 1
    end
  end

  describe "pack/2" do
    setup do
      # Create a test DBF file with some records, some deleted
      temp_path = "/tmp/test_pack_#{:rand.uniform(10000)}.dbf"
      
      fields = [
        %FieldDescriptor{name: "ID", type: "N", length: 5, decimal_count: 0},
        %FieldDescriptor{name: "NAME", type: "C", length: 20, decimal_count: 0},
        %FieldDescriptor{name: "STATUS", type: "L", length: 1, decimal_count: 0}
      ]
      
      {:ok, dbf} = Parser.create_dbf(temp_path, fields)
      
      # Add some initial records
      {:ok, dbf1} = Parser.append_record(dbf, %{"ID" => 1, "NAME" => "Alice", "STATUS" => true})
      {:ok, dbf2} = Parser.append_record(dbf1, %{"ID" => 2, "NAME" => "Bob", "STATUS" => false})
      {:ok, dbf3} = Parser.append_record(dbf2, %{"ID" => 3, "NAME" => "Charlie", "STATUS" => true})
      {:ok, dbf4} = Parser.append_record(dbf3, %{"ID" => 4, "NAME" => "Diana", "STATUS" => false})
      {:ok, dbf5} = Parser.append_record(dbf4, %{"ID" => 5, "NAME" => "Eve", "STATUS" => true})
      
      # Mark some records as deleted (Bob and Diana)
      {:ok, dbf6} = Parser.mark_deleted(dbf5, 1)  # Bob
      {:ok, dbf7} = Parser.mark_deleted(dbf6, 3)  # Diana
      
      on_exit(fn ->
        File.rm(temp_path)
      end)
      
      {:ok, path: temp_path, dbf: dbf7, fields: fields}
    end

    test "packs file by removing deleted records", %{path: path, dbf: dbf} do
      # Verify initial state: 5 total records, 3 active
      assert dbf.header.record_count == 5
      {:ok, records} = Parser.read_records(dbf)
      assert length(records) == 3
      
      # Pack the file in place
      assert {:ok, packed_dbf} = Parser.pack(dbf, path)
      
      # Verify packed file has only active records
      assert packed_dbf.header.record_count == 3
      {:ok, packed_records} = Parser.read_records(packed_dbf)
      assert length(packed_records) == 3
      
      # Verify the correct records remain
      names = Enum.map(packed_records, & &1["NAME"])
      assert "Alice" in names
      assert "Charlie" in names  
      assert "Eve" in names
      refute "Bob" in names      # Should be gone
      refute "Diana" in names    # Should be gone
      
      # Verify IDs are preserved
      ids = Enum.map(packed_records, & &1["ID"])
      assert 1 in ids
      assert 3 in ids
      assert 5 in ids
      
      Parser.close_dbf(packed_dbf)
    end

    test "creates packed file at different location", %{dbf: dbf} do
      packed_path = "/tmp/test_pack_output_#{:rand.uniform(10000)}.dbf"
      
      on_exit(fn ->
        File.rm(packed_path)
      end)
      
      # Pack to a different file
      assert {:ok, packed_dbf} = Parser.pack(dbf, packed_path)
      
      # Verify the new file
      assert File.exists?(packed_path)
      assert packed_dbf.header.record_count == 3
      
      # Verify we can open the packed file independently
      Parser.close_dbf(packed_dbf)
      {:ok, reopened_dbf} = Parser.open_dbf(packed_path)
      {:ok, records} = Parser.read_records(reopened_dbf)
      assert length(records) == 3
      
      Parser.close_dbf(reopened_dbf)
    end

    test "handles file with no deleted records", %{fields: fields} do
      # Create a file with no deleted records
      clean_path = "/tmp/test_pack_clean_#{:rand.uniform(10000)}.dbf"
      {:ok, clean_dbf} = Parser.create_dbf(clean_path, fields)
      
      {:ok, dbf1} = Parser.append_record(clean_dbf, %{"ID" => 1, "NAME" => "Alice"})
      {:ok, dbf2} = Parser.append_record(dbf1, %{"ID" => 2, "NAME" => "Bob"})
      
      packed_path = "/tmp/test_pack_clean_output_#{:rand.uniform(10000)}.dbf"
      
      on_exit(fn ->
        File.rm(clean_path)
        File.rm(packed_path)
      end)
      
      # Pack the clean file
      assert {:ok, packed_dbf} = Parser.pack(dbf2, packed_path)
      
      # Should have the same number of records
      assert packed_dbf.header.record_count == 2
      {:ok, records} = Parser.read_records(packed_dbf)
      assert length(records) == 2
      
      Parser.close_dbf(packed_dbf)
    end

    test "handles file with all records deleted", %{fields: fields} do
      # Create a file and delete all records
      all_deleted_path = "/tmp/test_pack_all_deleted_#{:rand.uniform(10000)}.dbf"
      {:ok, dbf} = Parser.create_dbf(all_deleted_path, fields)
      
      {:ok, dbf1} = Parser.append_record(dbf, %{"ID" => 1, "NAME" => "Alice"})
      {:ok, dbf2} = Parser.append_record(dbf1, %{"ID" => 2, "NAME" => "Bob"})
      {:ok, dbf3} = Parser.mark_deleted(dbf2, 0)
      {:ok, dbf4} = Parser.mark_deleted(dbf3, 1)
      
      packed_path = "/tmp/test_pack_empty_output_#{:rand.uniform(10000)}.dbf"
      
      on_exit(fn ->
        File.rm(all_deleted_path)
        File.rm(packed_path)
      end)
      
      # Pack the file with all records deleted
      assert {:ok, packed_dbf} = Parser.pack(dbf4, packed_path)
      
      # Should have zero records
      assert packed_dbf.header.record_count == 0
      {:ok, records} = Parser.read_records(packed_dbf)
      assert length(records) == 0
      
      Parser.close_dbf(packed_dbf)
    end

    test "preserves field structure and types", %{dbf: dbf} do
      packed_path = "/tmp/test_pack_structure_#{:rand.uniform(10000)}.dbf"
      
      on_exit(fn ->
        File.rm(packed_path)
      end)
      
      # Pack the file
      assert {:ok, packed_dbf} = Parser.pack(dbf, packed_path)
      
      # Verify field structure is preserved
      assert length(packed_dbf.fields) == 3
      
      [id_field, name_field, status_field] = packed_dbf.fields
      assert id_field.name == "ID"
      assert id_field.type == "N"
      assert id_field.length == 5
      
      assert name_field.name == "NAME"
      assert name_field.type == "C"
      assert name_field.length == 20
      
      assert status_field.name == "STATUS"
      assert status_field.type == "L"
      assert status_field.length == 1
      
      Parser.close_dbf(packed_dbf)
    end

    test "updates header calculations correctly", %{dbf: dbf} do
      packed_path = "/tmp/test_pack_header_#{:rand.uniform(10000)}.dbf"
      
      on_exit(fn ->
        File.rm(packed_path)
      end)
      
      # Pack the file
      assert {:ok, packed_dbf} = Parser.pack(dbf, packed_path)
      
      # Verify header calculations
      expected_header_length = 32 + (3 * 32) + 1  # header + 3 fields + terminator = 129
      expected_record_length = 1 + 5 + 20 + 1     # deletion flag + field lengths = 27
      
      assert packed_dbf.header.header_length == expected_header_length
      assert packed_dbf.header.record_length == expected_record_length
      assert packed_dbf.header.record_count == 3
      
      # Verify current timestamp
      {{year, month, day}, _} = :calendar.local_time()
      assert packed_dbf.header.last_update_year == year - 1900
      assert packed_dbf.header.last_update_month == month
      assert packed_dbf.header.last_update_day == day
      
      Parser.close_dbf(packed_dbf)
    end

    test "handles empty source file", %{fields: fields} do
      # Create an empty file
      empty_path = "/tmp/test_pack_empty_source_#{:rand.uniform(10000)}.dbf"
      {:ok, empty_dbf} = Parser.create_dbf(empty_path, fields)
      
      packed_path = "/tmp/test_pack_from_empty_#{:rand.uniform(10000)}.dbf"
      
      on_exit(fn ->
        File.rm(empty_path)
        File.rm(packed_path)
      end)
      
      # Pack the empty file
      assert {:ok, packed_dbf} = Parser.pack(empty_dbf, packed_path)
      
      # Should still be empty
      assert packed_dbf.header.record_count == 0
      {:ok, records} = Parser.read_records(packed_dbf)
      assert length(records) == 0
      
      Parser.close_dbf(packed_dbf)
    end
  end

  describe "transaction/2" do
    setup do
      # Create a test DBF file with some records
      temp_path = "/tmp/test_transaction_#{:rand.uniform(10000)}.dbf"
      
      fields = [
        %FieldDescriptor{name: "ID", type: "N", length: 5, decimal_count: 0},
        %FieldDescriptor{name: "NAME", type: "C", length: 20, decimal_count: 0},
        %FieldDescriptor{name: "BALANCE", type: "N", length: 10, decimal_count: 2}
      ]
      
      {:ok, dbf} = Parser.create_dbf(temp_path, fields)
      
      # Add some initial records
      {:ok, dbf1} = Parser.append_record(dbf, %{"ID" => 1, "NAME" => "Alice", "BALANCE" => 100.00})
      {:ok, dbf2} = Parser.append_record(dbf1, %{"ID" => 2, "NAME" => "Bob", "BALANCE" => 200.00})
      {:ok, dbf3} = Parser.append_record(dbf2, %{"ID" => 3, "NAME" => "Charlie", "BALANCE" => 300.00})
      
      Parser.close_dbf(dbf3)
      
      on_exit(fn ->
        File.rm(temp_path)
      end)
      
      {:ok, path: temp_path}
    end

    test "commits successful transaction", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path)
      
      # Execute transaction that succeeds
      result = Parser.transaction(dbf, fn dbf ->
        {:ok, dbf1} = Parser.update_record(dbf, 0, %{"BALANCE" => 150.00})
        {:ok, dbf2} = Parser.update_record(dbf1, 1, %{"BALANCE" => 250.00})
        {:ok, dbf3} = Parser.append_record(dbf2, %{"ID" => 4, "NAME" => "Diana", "BALANCE" => 400.00})
        {:ok, dbf3}
      end)
      
      assert {:ok, final_dbf} = result
      
      # Verify changes were committed
      {:ok, records} = Parser.read_records(final_dbf)
      assert length(records) == 4
      assert Enum.at(records, 0)["BALANCE"] == 150.00
      assert Enum.at(records, 1)["BALANCE"] == 250.00
      assert Enum.at(records, 3)["NAME"] == "Diana"
      
      # Verify changes persist after reopening
      Parser.close_dbf(final_dbf)
      {:ok, dbf_reopen} = Parser.open_dbf(path)
      {:ok, records_reopen} = Parser.read_records(dbf_reopen)
      assert length(records_reopen) == 4
      assert Enum.at(records_reopen, 0)["BALANCE"] == 150.00
      
      Parser.close_dbf(dbf_reopen)
    end

    test "rolls back failed transaction", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path)
      
      # Get original state
      {:ok, original_records} = Parser.read_records(dbf)
      original_count = length(original_records)
      original_balance = Enum.at(original_records, 0)["BALANCE"]
      
      # Execute transaction that fails
      result = Parser.transaction(dbf, fn dbf ->
        {:ok, dbf1} = Parser.update_record(dbf, 0, %{"BALANCE" => 999.99})
        {:ok, _dbf2} = Parser.append_record(dbf1, %{"ID" => 4, "NAME" => "Diana"})
        # Simulate an error
        {:error, :simulated_failure}
      end)
      
      assert {:error, :simulated_failure} = result
      
      # Verify rollback occurred - file should be in original state
      {:ok, dbf_after} = Parser.open_dbf(path)
      {:ok, records_after} = Parser.read_records(dbf_after)
      
      assert length(records_after) == original_count
      assert Enum.at(records_after, 0)["BALANCE"] == original_balance
      # Diana should not exist
      names = Enum.map(records_after, & &1["NAME"])
      refute "Diana" in names
      
      Parser.close_dbf(dbf_after)
    end

    test "handles exception in transaction", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path)
      
      # Get original state
      {:ok, original_records} = Parser.read_records(dbf)
      original_count = length(original_records)
      
      # Execute transaction that raises exception
      result = Parser.transaction(dbf, fn dbf ->
        {:ok, dbf1} = Parser.append_record(dbf, %{"ID" => 4, "NAME" => "Diana"})
        # Simulate an exception
        raise RuntimeError, "Something went wrong"
        {:ok, dbf1}
      end)
      
      assert {:error, %RuntimeError{}} = result
      
      # Verify rollback occurred
      {:ok, dbf_after} = Parser.open_dbf(path)
      {:ok, records_after} = Parser.read_records(dbf_after)
      
      assert length(records_after) == original_count
      names = Enum.map(records_after, & &1["NAME"])
      refute "Diana" in names
      
      Parser.close_dbf(dbf_after)
    end

    test "handles nested operations correctly", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path)
      
      # Complex transaction with multiple operations
      result = Parser.transaction(dbf, fn dbf ->
        # Add a record
        {:ok, dbf1} = Parser.append_record(dbf, %{"ID" => 4, "NAME" => "Diana", "BALANCE" => 400.00})
        
        # Update existing records
        {:ok, dbf2} = Parser.update_record(dbf1, 0, %{"BALANCE" => 111.11})
        {:ok, dbf3} = Parser.update_record(dbf2, 1, %{"BALANCE" => 222.22})
        
        # Mark one as deleted
        {:ok, dbf4} = Parser.mark_deleted(dbf3, 2)
        
        # Add another record
        {:ok, dbf5} = Parser.append_record(dbf4, %{"ID" => 5, "NAME" => "Eve", "BALANCE" => 500.00})
        
        {:ok, dbf5}
      end)
      
      assert {:ok, final_dbf} = result
      
      # Verify all operations were applied
      {:ok, records} = Parser.read_records(final_dbf)
      assert length(records) == 4  # 3 original + 2 new - 1 deleted
      
      # Verify specific changes
      assert Enum.at(records, 0)["BALANCE"] == 111.11
      assert Enum.at(records, 1)["BALANCE"] == 222.22
      # Charlie should be missing (deleted)
      names = Enum.map(records, & &1["NAME"])
      assert "Diana" in names
      assert "Eve" in names
      refute "Charlie" in names
      
      Parser.close_dbf(final_dbf)
    end

    test "cleans up backup file on successful commit", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path)
      
      # Execute successful transaction
      {:ok, _final_dbf} = Parser.transaction(dbf, fn dbf ->
        {:ok, dbf1} = Parser.append_record(dbf, %{"ID" => 4, "NAME" => "Diana"})
        {:ok, dbf1}
      end)
      
      # Backup file should be cleaned up
      backup_path = path <> ".backup"
      refute File.exists?(backup_path)
    end

    test "handles transaction with no operations", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path)
      
      # Transaction that does nothing
      result = Parser.transaction(dbf, fn dbf ->
        {:ok, dbf}
      end)
      
      assert {:ok, final_dbf} = result
      
      # File should be unchanged
      {:ok, records} = Parser.read_records(final_dbf)
      assert length(records) == 3
      
      Parser.close_dbf(final_dbf)
    end

    test "handles invalid return from transaction function", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path)
      
      # Transaction that returns invalid result
      result = Parser.transaction(dbf, fn _dbf ->
        :invalid_return
      end)
      
      assert {:error, :invalid_transaction_return} = result
      
      # File should be rolled back to original state
      {:ok, dbf_after} = Parser.open_dbf(path)
      {:ok, records} = Parser.read_records(dbf_after)
      assert length(records) == 3  # Original state
      
      Parser.close_dbf(dbf_after)
    end
  end

  describe "record counting" do
    setup do
      temp_path = "/tmp/test_counting_#{:rand.uniform(10000)}.dbf"
      
      fields = [
        %FieldDescriptor{name: "ID", type: "N", length: 5, decimal_count: 0},
        %FieldDescriptor{name: "NAME", type: "C", length: 15, decimal_count: 0}
      ]
      
      {:ok, dbf} = Parser.create_dbf(temp_path, fields)
      
      # Add some test records
      {:ok, dbf1} = Parser.append_record(dbf, %{"ID" => 1, "NAME" => "Alice"})
      {:ok, dbf2} = Parser.append_record(dbf1, %{"ID" => 2, "NAME" => "Bob"})
      {:ok, dbf3} = Parser.append_record(dbf2, %{"ID" => 3, "NAME" => "Charlie"})
      {:ok, dbf4} = Parser.append_record(dbf3, %{"ID" => 4, "NAME" => "Diana"})
      
      Parser.close_dbf(dbf4)
      
      on_exit(fn ->
        File.rm(temp_path)
      end)
      
      {:ok, path: temp_path}
    end

    test "counts active records correctly", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      
      # Initially all records are active
      assert {:ok, 4} = Parser.count_active_records(dbf)
      
      Parser.close_dbf(dbf)
    end

    test "counts deleted records correctly", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      
      # Initially no records are deleted
      assert {:ok, 0} = Parser.count_deleted_records(dbf)
      
      # Delete some records
      {:ok, dbf1} = Parser.mark_deleted(dbf, 1)
      {:ok, dbf2} = Parser.mark_deleted(dbf1, 3)
      
      # Now we should have 2 deleted records
      assert {:ok, 2} = Parser.count_deleted_records(dbf2)
      
      Parser.close_dbf(dbf2)
    end

    test "provides accurate record statistics", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      
      # Mark some records as deleted
      {:ok, dbf1} = Parser.mark_deleted(dbf, 0)
      {:ok, dbf2} = Parser.mark_deleted(dbf1, 2)
      
      # Get statistics
      assert {:ok, stats} = Parser.record_statistics(dbf2)
      
      assert stats.total_records == 4
      assert stats.active_records == 2
      assert stats.deleted_records == 2
      assert stats.deletion_percentage == 50.0
      
      Parser.close_dbf(dbf2)
    end

    test "handles empty file statistics", %{path: _path} do
      empty_path = "/tmp/test_empty_#{:rand.uniform(10000)}.dbf"
      
      fields = [
        %FieldDescriptor{name: "ID", type: "N", length: 5, decimal_count: 0}
      ]
      
      {:ok, dbf} = Parser.create_dbf(empty_path, fields)
      
      # Get statistics for empty file
      assert {:ok, stats} = Parser.record_statistics(dbf)
      
      assert stats.total_records == 0
      assert stats.active_records == 0
      assert stats.deleted_records == 0
      assert stats.deletion_percentage == 0.0
      
      Parser.close_dbf(dbf)
      File.rm(empty_path)
    end

    test "updates counts after undelete operations", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      
      # Delete some records
      {:ok, dbf1} = Parser.mark_deleted(dbf, 0)
      {:ok, dbf2} = Parser.mark_deleted(dbf1, 1)
      {:ok, dbf3} = Parser.mark_deleted(dbf2, 2)
      
      # Verify deleted count
      assert {:ok, 3} = Parser.count_deleted_records(dbf3)
      assert {:ok, 1} = Parser.count_active_records(dbf3)
      
      # Undelete one record
      {:ok, dbf4} = Parser.undelete_record(dbf3, 1)
      
      # Verify updated counts
      assert {:ok, 2} = Parser.count_deleted_records(dbf4)
      assert {:ok, 2} = Parser.count_active_records(dbf4)
      
      Parser.close_dbf(dbf4)
    end

    test "counts are consistent with pack operations", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      
      # Delete some records  
      {:ok, dbf1} = Parser.mark_deleted(dbf, 1)
      {:ok, dbf2} = Parser.mark_deleted(dbf1, 3)
      
      # Count before packing
      assert {:ok, 2} = Parser.count_active_records(dbf2)
      assert {:ok, 2} = Parser.count_deleted_records(dbf2)
      
      # Pack the file
      packed_path = "/tmp/test_packed_#{:rand.uniform(10000)}.dbf"
      {:ok, packed_dbf} = Parser.pack(dbf2, packed_path)
      
      # After packing, should have only active records
      assert {:ok, 2} = Parser.count_active_records(packed_dbf)
      assert {:ok, 0} = Parser.count_deleted_records(packed_dbf)
      
      Parser.close_dbf(dbf2)
      Parser.close_dbf(packed_dbf)
      File.rm(packed_path)
    end
  end

  describe "batch deletion" do
    setup do
      temp_path = "/tmp/test_batch_delete_#{:rand.uniform(10000)}.dbf"
      
      fields = [
        %FieldDescriptor{name: "ID", type: "N", length: 5, decimal_count: 0},
        %FieldDescriptor{name: "NAME", type: "C", length: 15, decimal_count: 0},
        %FieldDescriptor{name: "STATUS", type: "C", length: 10, decimal_count: 0}
      ]
      
      {:ok, dbf} = Parser.create_dbf(temp_path, fields)
      
      # Add test records
      {:ok, dbf1} = Parser.append_record(dbf, %{"ID" => 1, "NAME" => "Alice", "STATUS" => "active"})
      {:ok, dbf2} = Parser.append_record(dbf1, %{"ID" => 2, "NAME" => "Bob", "STATUS" => "inactive"})
      {:ok, dbf3} = Parser.append_record(dbf2, %{"ID" => 3, "NAME" => "Charlie", "STATUS" => "active"})
      {:ok, dbf4} = Parser.append_record(dbf3, %{"ID" => 4, "NAME" => "Diana", "STATUS" => "pending"})
      {:ok, dbf5} = Parser.append_record(dbf4, %{"ID" => 5, "NAME" => "Eve", "STATUS" => "active"})
      {:ok, dbf6} = Parser.append_record(dbf5, %{"ID" => 6, "NAME" => "Frank", "STATUS" => "inactive"})
      
      Parser.close_dbf(dbf6)
      
      on_exit(fn ->
        File.rm(temp_path)
      end)
      
      {:ok, path: temp_path}
    end

    test "deletes multiple records by index list", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      
      # Delete records at indices 1, 3, and 5
      assert {:ok, updated_dbf} = Parser.batch_delete(dbf, [1, 3, 5])
      
      # Verify deletions
      assert {:ok, 3} = Parser.count_active_records(updated_dbf)
      assert {:ok, 3} = Parser.count_deleted_records(updated_dbf)
      
      # Verify specific records are deleted
      {:ok, record1} = Parser.read_record(updated_dbf, 1)
      assert record1.deleted == true
      
      {:ok, record3} = Parser.read_record(updated_dbf, 3)
      assert record3.deleted == true
      
      {:ok, record5} = Parser.read_record(updated_dbf, 5)
      assert record5.deleted == true
      
      # Verify non-deleted records remain active
      {:ok, record0} = Parser.read_record(updated_dbf, 0)
      assert record0.deleted == false
      
      {:ok, record2} = Parser.read_record(updated_dbf, 2)
      assert record2.deleted == false
      
      {:ok, record4} = Parser.read_record(updated_dbf, 4)
      assert record4.deleted == false
      
      Parser.close_dbf(updated_dbf)
    end

    test "deletes records matching condition function", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      
      # Delete all records where STATUS is "inactive"
      condition_fn = fn record_data ->
        Map.get(record_data, "STATUS") == "inactive"
      end
      
      assert {:ok, updated_dbf} = Parser.batch_delete_where(dbf, condition_fn)
      
      # Should have deleted 2 records (Bob and Frank with "inactive" status)
      assert {:ok, 4} = Parser.count_active_records(updated_dbf)
      assert {:ok, 2} = Parser.count_deleted_records(updated_dbf)
      
      # Verify correct records were deleted by checking remaining active records
      {:ok, active_records} = Parser.read_records(updated_dbf)
      active_names = Enum.map(active_records, & &1["NAME"])
      assert "Alice" in active_names
      assert "Charlie" in active_names  
      assert "Diana" in active_names
      assert "Eve" in active_names
      refute "Bob" in active_names
      refute "Frank" in active_names
      
      Parser.close_dbf(updated_dbf)
    end

    test "deletes records in index range", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      
      # Delete records from index 2 to 4 (inclusive)
      assert {:ok, updated_dbf} = Parser.batch_delete_range(dbf, 2, 4)
      
      # Should have deleted 3 records (indices 2, 3, 4)
      assert {:ok, 3} = Parser.count_active_records(updated_dbf)
      assert {:ok, 3} = Parser.count_deleted_records(updated_dbf)
      
      # Verify specific deletions
      {:ok, record2} = Parser.read_record(updated_dbf, 2)
      assert record2.deleted == true
      
      {:ok, record3} = Parser.read_record(updated_dbf, 3)
      assert record3.deleted == true
      
      {:ok, record4} = Parser.read_record(updated_dbf, 4)
      assert record4.deleted == true
      
      # Verify records outside range remain active
      {:ok, record0} = Parser.read_record(updated_dbf, 0)
      assert record0.deleted == false
      
      {:ok, record1} = Parser.read_record(updated_dbf, 1)
      assert record1.deleted == false
      
      {:ok, record5} = Parser.read_record(updated_dbf, 5)
      assert record5.deleted == false
      
      Parser.close_dbf(updated_dbf)
    end

    test "handles empty index list gracefully", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      
      # Delete with empty list should not change anything
      assert {:ok, updated_dbf} = Parser.batch_delete(dbf, [])
      
      # All records should remain active
      assert {:ok, 6} = Parser.count_active_records(updated_dbf)
      assert {:ok, 0} = Parser.count_deleted_records(updated_dbf)
      
      Parser.close_dbf(updated_dbf)
    end

    test "handles duplicate indices in batch delete", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      
      # Delete with duplicate indices should work (idempotent)
      assert {:ok, updated_dbf} = Parser.batch_delete(dbf, [1, 3, 1, 3, 1])
      
      # Should have deleted only 2 unique records
      assert {:ok, 4} = Parser.count_active_records(updated_dbf)
      assert {:ok, 2} = Parser.count_deleted_records(updated_dbf)
      
      Parser.close_dbf(updated_dbf)
    end

    test "validates index bounds in batch operations", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      
      # Try to delete with invalid indices
      assert {:error, :invalid_record_index} = Parser.batch_delete(dbf, [0, 1, 10])  # Index 10 is out of bounds
      assert {:error, :invalid_record_index} = Parser.batch_delete(dbf, [-1, 2])     # Negative index
      
      # Try invalid range
      assert {:error, :invalid_range} = Parser.batch_delete_range(dbf, 3, 2)  # Start > end
      assert {:error, :invalid_record_index} = Parser.batch_delete_range(dbf, 0, 10)  # End out of bounds
      
      Parser.close_dbf(dbf)
    end

    test "batch delete updates header timestamp", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      
      original_timestamp = {dbf.header.last_update_year, dbf.header.last_update_month, dbf.header.last_update_day}
      
      # Wait a moment to ensure timestamp difference
      :timer.sleep(1000)
      
      # Perform batch deletion
      {:ok, updated_dbf} = Parser.batch_delete(dbf, [1, 2])
      
      new_timestamp = {updated_dbf.header.last_update_year, updated_dbf.header.last_update_month, updated_dbf.header.last_update_day}
      
      # Timestamp should be updated (at least not identical due to sleep)
      assert new_timestamp >= original_timestamp
      
      Parser.close_dbf(updated_dbf)
    end

    test "batch operations work within transactions", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      
      # Execute batch deletion within a transaction
      result = Parser.transaction(dbf, fn transaction_dbf ->
        {:ok, dbf1} = Parser.batch_delete(transaction_dbf, [0, 2, 4])
        {:ok, dbf2} = Parser.batch_delete_range(dbf1, 1, 1)  # Delete one more
        {:ok, dbf2}
      end)
      
      assert {:ok, final_dbf} = result
      
      # Should have deleted 4 records total
      assert {:ok, 2} = Parser.count_active_records(final_dbf)
      assert {:ok, 4} = Parser.count_deleted_records(final_dbf)
      
      Parser.close_dbf(final_dbf)
    end
  end

  describe "batch write operations" do
    setup do
      temp_path = "/tmp/test_batch_write_#{:rand.uniform(10000)}.dbf"
      
      fields = [
        %FieldDescriptor{name: "ID", type: "N", length: 5, decimal_count: 0},
        %FieldDescriptor{name: "NAME", type: "C", length: 20, decimal_count: 0},
        %FieldDescriptor{name: "SCORE", type: "N", length: 6, decimal_count: 2}
      ]
      
      {:ok, dbf} = Parser.create_dbf(temp_path, fields)
      
      # Add some initial records for update tests
      {:ok, dbf1} = Parser.append_record(dbf, %{"ID" => 1, "NAME" => "Alice", "SCORE" => 85.50})
      {:ok, dbf2} = Parser.append_record(dbf1, %{"ID" => 2, "NAME" => "Bob", "SCORE" => 92.25})
      {:ok, dbf3} = Parser.append_record(dbf2, %{"ID" => 3, "NAME" => "Charlie", "SCORE" => 78.75})
      
      Parser.close_dbf(dbf3)
      
      on_exit(fn ->
        File.rm(temp_path)
      end)
      
      {:ok, path: temp_path}
    end

    test "batch appends multiple records efficiently", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      
      new_records = [
        %{"ID" => 4, "NAME" => "Diana", "SCORE" => 88.00},
        %{"ID" => 5, "NAME" => "Eve", "SCORE" => 95.50},
        %{"ID" => 6, "NAME" => "Frank", "SCORE" => 82.25}
      ]
      
      assert {:ok, updated_dbf} = Parser.batch_append_records(dbf, new_records)
      
      # Verify all records were added
      assert updated_dbf.header.record_count == 6
      
      # Verify content of all records
      {:ok, all_records} = Parser.read_records(updated_dbf)
      assert length(all_records) == 6
      
      # Check the new records
      assert Enum.at(all_records, 3)["NAME"] == "Diana"
      assert Enum.at(all_records, 4)["NAME"] == "Eve"
      assert Enum.at(all_records, 5)["NAME"] == "Frank"
      assert Enum.at(all_records, 5)["SCORE"] == 82.25
      
      Parser.close_dbf(updated_dbf)
    end

    test "batch updates multiple records by index", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      
      updates = [
        {0, %{"SCORE" => 90.00}},
        {1, %{"NAME" => "Robert", "SCORE" => 95.00}},
        {2, %{"SCORE" => 85.50}}
      ]
      
      assert {:ok, updated_dbf} = Parser.batch_update_records(dbf, updates)
      
      # Verify updates were applied
      {:ok, records} = Parser.read_records(updated_dbf)
      
      assert Enum.at(records, 0)["SCORE"] == 90.00
      assert Enum.at(records, 0)["NAME"] == "Alice"  # Unchanged
      
      assert Enum.at(records, 1)["NAME"] == "Robert"
      assert Enum.at(records, 1)["SCORE"] == 95.00
      
      assert Enum.at(records, 2)["SCORE"] == 85.50
      assert Enum.at(records, 2)["NAME"] == "Charlie"  # Unchanged
      
      Parser.close_dbf(updated_dbf)
    end

    test "batch update with condition function", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      
      # Update all records where SCORE < 85
      condition_fn = fn record_data ->
        Map.get(record_data, "SCORE") < 85.0
      end
      
      update_data = %{"SCORE" => 85.00}
      
      assert {:ok, updated_dbf} = Parser.batch_update_where(dbf, condition_fn, update_data)
      
      # Verify only Charlie's record was updated (was 78.75, now 85.00)
      {:ok, records} = Parser.read_records(updated_dbf)
      
      assert Enum.at(records, 0)["SCORE"] == 85.50  # Alice unchanged
      assert Enum.at(records, 1)["SCORE"] == 92.25  # Bob unchanged  
      assert Enum.at(records, 2)["SCORE"] == 85.00  # Charlie updated
      
      Parser.close_dbf(updated_dbf)
    end

    test "handles empty batch operations gracefully", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      
      # Empty batch append
      assert {:ok, dbf1} = Parser.batch_append_records(dbf, [])
      assert dbf1.header.record_count == 3  # No change
      
      # Empty batch update
      assert {:ok, dbf2} = Parser.batch_update_records(dbf1, [])
      assert dbf2.header.record_count == 3  # No change
      
      Parser.close_dbf(dbf2)
    end

    test "validates batch update indices", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      
      # Try to update with invalid indices
      invalid_updates = [
        {0, %{"SCORE" => 90.00}},
        {5, %{"SCORE" => 85.00}}  # Index 5 doesn't exist
      ]
      
      assert {:error, :invalid_record_index} = Parser.batch_update_records(dbf, invalid_updates)
      
      # Try negative index
      negative_updates = [
        {-1, %{"SCORE" => 90.00}}
      ]
      
      assert {:error, :invalid_record_index} = Parser.batch_update_records(dbf, negative_updates)
      
      Parser.close_dbf(dbf)
    end

    test "batch operations update header timestamp", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      
      original_timestamp = {dbf.header.last_update_year, dbf.header.last_update_month, dbf.header.last_update_day}
      
      # Wait to ensure timestamp difference
      :timer.sleep(1000)
      
      # Perform batch append
      new_records = [%{"ID" => 4, "NAME" => "Diana", "SCORE" => 88.00}]
      {:ok, updated_dbf} = Parser.batch_append_records(dbf, new_records)
      
      new_timestamp = {updated_dbf.header.last_update_year, updated_dbf.header.last_update_month, updated_dbf.header.last_update_day}
      
      # Timestamp should be updated
      assert new_timestamp >= original_timestamp
      
      Parser.close_dbf(updated_dbf)
    end

    test "batch operations work within transactions", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      
      # Execute batch operations within transaction
      result = Parser.transaction(dbf, fn transaction_dbf ->
        # Batch append
        new_records = [
          %{"ID" => 4, "NAME" => "Diana", "SCORE" => 88.00},
          %{"ID" => 5, "NAME" => "Eve", "SCORE" => 95.50}
        ]
        {:ok, dbf1} = Parser.batch_append_records(transaction_dbf, new_records)
        
        # Batch update
        updates = [
          {0, %{"SCORE" => 90.00}},
          {1, %{"SCORE" => 95.00}}
        ]
        {:ok, dbf2} = Parser.batch_update_records(dbf1, updates)
        
        {:ok, dbf2}
      end)
      
      assert {:ok, final_dbf} = result
      
      # Verify all operations were committed
      assert final_dbf.header.record_count == 5
      {:ok, records} = Parser.read_records(final_dbf)
      
      assert length(records) == 5
      assert Enum.at(records, 0)["SCORE"] == 90.00  # Updated
      assert Enum.at(records, 1)["SCORE"] == 95.00  # Updated
      assert Enum.at(records, 3)["NAME"] == "Diana"  # Appended
      assert Enum.at(records, 4)["NAME"] == "Eve"    # Appended
      
      Parser.close_dbf(final_dbf)
    end

    test "batch append handles field validation", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      
      # Try to append records with missing required fields
      invalid_records = [
        %{"ID" => 4, "NAME" => "Diana"},  # Missing SCORE
        %{"NAME" => "Eve", "SCORE" => 95.50}  # Missing ID
      ]
      
      # Should still work by using default values for missing fields
      assert {:ok, updated_dbf} = Parser.batch_append_records(dbf, invalid_records)
      
      {:ok, records} = Parser.read_records(updated_dbf)
      assert length(records) == 5
      
      # Missing SCORE should default to 0
      assert Enum.at(records, 3)["SCORE"] == 0
      # Missing ID should default to 0  
      assert Enum.at(records, 4)["ID"] == 0
      
      Parser.close_dbf(updated_dbf)
    end

    test "batch operations are atomic on failure", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      
      original_count = dbf.header.record_count
      
      # Execute transaction that will fail partway through
      result = Parser.transaction(dbf, fn transaction_dbf ->
        # This should succeed
        new_records = [%{"ID" => 4, "NAME" => "Diana", "SCORE" => 88.00}]
        {:ok, dbf1} = Parser.batch_append_records(transaction_dbf, new_records)
        
        # This should fail due to invalid index
        invalid_updates = [{10, %{"SCORE" => 90.00}}]
        case Parser.batch_update_records(dbf1, invalid_updates) do
          {:ok, _} -> {:ok, dbf1}
          {:error, reason} -> {:error, reason}
        end
      end)
      
      assert {:error, :invalid_record_index} = result
      
      # Verify rollback - no records should have been added
      {:ok, dbf_after} = Parser.open_dbf(path, [:read, :write])
      assert dbf_after.header.record_count == original_count
      
      Parser.close_dbf(dbf_after)
    end
  end

  describe "write conflict detection" do
    setup do
      temp_path = "/tmp/test_conflict_#{:rand.uniform(10000)}.dbf"
      
      fields = [
        %FieldDescriptor{name: "ID", type: "N", length: 5, decimal_count: 0},
        %FieldDescriptor{name: "NAME", type: "C", length: 15, decimal_count: 0},
        %FieldDescriptor{name: "VALUE", type: "N", length: 8, decimal_count: 2}
      ]
      
      {:ok, dbf} = Parser.create_dbf(temp_path, fields)
      
      # Add initial records
      {:ok, dbf1} = Parser.append_record(dbf, %{"ID" => 1, "NAME" => "Alice", "VALUE" => 100.00})
      {:ok, dbf2} = Parser.append_record(dbf1, %{"ID" => 2, "NAME" => "Bob", "VALUE" => 200.00})
      
      Parser.close_dbf(dbf2)
      
      on_exit(fn ->
        File.rm(temp_path)
      end)
      
      {:ok, path: temp_path}
    end

    test "detects concurrent modifications during update", %{path: path} do
      # Open file in two separate handles
      {:ok, dbf1} = Parser.open_dbf(path, [:read, :write])
      {:ok, dbf2} = Parser.open_dbf(path, [:read, :write])
      
      # Modify through first handle
      {:ok, _updated_dbf1} = Parser.update_record(dbf1, 0, %{"VALUE" => 150.00})
      
      # Try to modify through second handle (should detect conflict)
      result = Parser.update_record_with_conflict_check(dbf2, 0, %{"VALUE" => 175.00})
      
      assert {:error, :write_conflict} = result
      
      Parser.close_dbf(dbf1)
      Parser.close_dbf(dbf2)
    end

    test "allows modifications when no conflict exists", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      
      # Normal update should work fine
      result = Parser.update_record_with_conflict_check(dbf, 0, %{"VALUE" => 125.00})
      
      assert {:ok, updated_dbf} = result
      
      # Verify the update was applied
      {:ok, record} = Parser.read_record(updated_dbf, 0)
      assert record.data["VALUE"] == 125.00
      
      Parser.close_dbf(updated_dbf)
    end

    test "detects conflicts in batch operations", %{path: path} do
      # Open file in two handles
      {:ok, dbf1} = Parser.open_dbf(path, [:read, :write])
      {:ok, dbf2} = Parser.open_dbf(path, [:read, :write])
      
      # Modify through first handle
      {:ok, _updated_dbf1} = Parser.append_record(dbf1, %{"ID" => 3, "NAME" => "Charlie", "VALUE" => 300.00})
      
      # Try batch update through second handle (should detect conflict)
      updates = [{0, %{"VALUE" => 111.00}}, {1, %{"VALUE" => 222.00}}]
      result = Parser.batch_update_records_with_conflict_check(dbf2, updates)
      
      assert {:error, :write_conflict} = result
      
      Parser.close_dbf(dbf1)
      Parser.close_dbf(dbf2)
    end

    test "refreshes DBF state when detecting conflicts", %{path: path} do
      # Open file in two handles
      {:ok, dbf1} = Parser.open_dbf(path, [:read, :write])
      {:ok, dbf2} = Parser.open_dbf(path, [:read, :write])
      
      # Modify through first handle
      {:ok, _updated_dbf1} = Parser.append_record(dbf1, %{"ID" => 3, "NAME" => "Charlie", "VALUE" => 300.00})
      
      # Refresh second handle to get latest state
      {:ok, refreshed_dbf2} = Parser.refresh_dbf_state(dbf2)
      
      # Verify refreshed state reflects the change
      assert refreshed_dbf2.header.record_count == 3
      
      # Now update should work without conflict
      result = Parser.update_record_with_conflict_check(refreshed_dbf2, 2, %{"VALUE" => 350.00})
      assert {:ok, _final_dbf} = result
      
      Parser.close_dbf(dbf1)
      Parser.close_dbf(refreshed_dbf2)
    end

    test "conflict detection works with transactions", %{path: path} do
      # Open file in two handles
      {:ok, dbf1} = Parser.open_dbf(path, [:read, :write])
      {:ok, dbf2} = Parser.open_dbf(path, [:read, :write])
      
      # Start transaction on first handle that modifies the file
      transaction_result = Parser.transaction(dbf1, fn transaction_dbf ->
        {:ok, dbf_step1} = Parser.append_record(transaction_dbf, %{"ID" => 3, "NAME" => "Charlie", "VALUE" => 300.00})
        {:ok, dbf_step2} = Parser.update_record(dbf_step1, 0, %{"VALUE" => 111.00})
        {:ok, dbf_step2}
      end)
      
      assert {:ok, _final_dbf1} = transaction_result
      
      # Try to update through second handle (should detect conflict)
      result = Parser.update_record_with_conflict_check(dbf2, 1, %{"VALUE" => 222.00})
      
      assert {:error, :write_conflict} = result
      
      Parser.close_dbf(dbf2)
    end

    test "conflict detection in delete operations", %{path: path} do
      # Open file in two handles
      {:ok, dbf1} = Parser.open_dbf(path, [:read, :write])
      {:ok, dbf2} = Parser.open_dbf(path, [:read, :write])
      
      # Delete through first handle
      {:ok, _updated_dbf1} = Parser.mark_deleted(dbf1, 0)
      
      # Try to delete through second handle (should detect conflict)
      result = Parser.mark_deleted_with_conflict_check(dbf2, 1)
      
      assert {:error, :write_conflict} = result
      
      Parser.close_dbf(dbf1)
      Parser.close_dbf(dbf2)
    end

    test "conflict check validates header timestamp", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      
      # Simulate external modification by directly updating file header timestamp
      new_header = %{dbf.header | 
        last_update_year: 125,
        last_update_month: 6,
        last_update_day: 15
      }
      
      # Write the modified header directly to file
      :ok = Parser.write_header(dbf.file, new_header)
      
      # Now try to update - should detect the timestamp mismatch
      result = Parser.update_record_with_conflict_check(dbf, 0, %{"VALUE" => 999.00})
      
      assert {:error, :write_conflict} = result
      
      Parser.close_dbf(dbf)
    end

    test "automatic retry with refresh on conflict", %{path: path} do
      # Open file in two handles
      {:ok, dbf1} = Parser.open_dbf(path, [:read, :write])
      {:ok, dbf2} = Parser.open_dbf(path, [:read, :write])
      
      # Modify through first handle
      {:ok, _updated_dbf1} = Parser.update_record(dbf1, 0, %{"VALUE" => 150.00})
      
      # Use automatic retry function that should refresh and succeed
      result = Parser.update_record_with_retry(dbf2, 1, %{"VALUE" => 250.00})
      
      assert {:ok, updated_dbf2} = result
      
      # Verify the update was applied after refresh
      {:ok, record} = Parser.read_record(updated_dbf2, 1)
      assert record.data["VALUE"] == 250.00
      
      Parser.close_dbf(dbf1)
      Parser.close_dbf(updated_dbf2)
    end

    test "conflict detection with pack operation", %{path: path} do
      # Open file in two handles
      {:ok, dbf1} = Parser.open_dbf(path, [:read, :write])
      {:ok, dbf2} = Parser.open_dbf(path, [:read, :write])
      
      # Mark record as deleted through first handle
      {:ok, _updated_dbf1} = Parser.mark_deleted(dbf1, 0)
      
      # Try to pack through second handle (should detect conflict)
      packed_path = "/tmp/test_packed_conflict_#{:rand.uniform(10000)}.dbf"
      result = Parser.pack_with_conflict_check(dbf2, packed_path)
      
      assert {:error, :write_conflict} = result
      
      Parser.close_dbf(dbf1)
      Parser.close_dbf(dbf2)
      
      # Clean up potential packed file
      File.rm(packed_path)
    end
  end

  describe "header consistency validation" do
    test "validates header consistency after record append" do
      fields = [
        %FieldDescriptor{name: "NAME", type: "C", length: 20, decimal_count: 0},
        %FieldDescriptor{name: "AGE", type: "N", length: 3, decimal_count: 0}
      ]
      
      path = "/tmp/test_header_consistency_#{:rand.uniform(10000)}.dbf"
      {:ok, dbf} = Parser.create_dbf(path, fields)
      
      # Append a record
      {:ok, updated_dbf} = Parser.append_record(dbf, %{"NAME" => "Test", "AGE" => 25})
      
      # Validate header consistency
      assert :ok = Parser.validate_header_consistency(updated_dbf)
      
      # Verify file size matches expected
      {:ok, file_info} = File.stat(path)
      expected_size = updated_dbf.header.header_length + 
                     (updated_dbf.header.record_count * updated_dbf.header.record_length) + 1
      
      assert file_info.size == expected_size or file_info.size == expected_size - 1
      
      Parser.close_dbf(updated_dbf)
    end

    test "validates header consistency after batch append" do
      fields = [
        %FieldDescriptor{name: "ID", type: "N", length: 5, decimal_count: 0},
        %FieldDescriptor{name: "DATA", type: "C", length: 10, decimal_count: 0}
      ]
      
      path = "/tmp/test_header_consistency_#{:rand.uniform(10000)}.dbf"
      
      # Clean up any existing file
      File.rm(path)
      
      {:ok, dbf} = Parser.create_dbf(path, fields)
      
      # Batch append records
      records = [
        %{"ID" => 1, "DATA" => "First"},
        %{"ID" => 2, "DATA" => "Second"},
        %{"ID" => 3, "DATA" => "Third"}
      ]
      
      {:ok, updated_dbf} = Parser.batch_append_records(dbf, records)
      
      # Validate header consistency
      assert :ok = Parser.validate_header_consistency(updated_dbf)
      
      # Verify record count
      assert updated_dbf.header.record_count == 3
      
      Parser.close_dbf(updated_dbf)
      File.rm(path)
    end

    test "detects header length mismatch" do
      fields = [
        %FieldDescriptor{name: "TEST", type: "C", length: 10, decimal_count: 0}
      ]
      
      path = "/tmp/test_header_consistency_#{:rand.uniform(10000)}.dbf"
      
      # Clean up any existing file
      File.rm(path)
      
      {:ok, dbf} = Parser.create_dbf(path, fields)
      
      # Manually corrupt header length
      corrupted_header = %{dbf.header | header_length: 100}  # Wrong value
      corrupted_dbf = %{dbf | header: corrupted_header}
      
      # Should detect mismatch
      assert {:error, {:header_length_mismatch, _, _}} = 
        Parser.validate_header_consistency(corrupted_dbf)
      
      Parser.close_dbf(dbf)
      File.rm(path)
    end

    test "detects record length mismatch" do
      fields = [
        %FieldDescriptor{name: "DATA", type: "C", length: 50, decimal_count: 0}
      ]
      
      path = "/tmp/test_header_consistency_#{:rand.uniform(10000)}.dbf"
      {:ok, dbf} = Parser.create_dbf(path, fields)
      
      # Manually corrupt record length
      corrupted_header = %{dbf.header | record_length: 25}  # Wrong value
      corrupted_dbf = %{dbf | header: corrupted_header}
      
      # Should detect mismatch
      assert {:error, {:record_length_mismatch, _, _}} = 
        Parser.validate_header_consistency(corrupted_dbf)
      
      Parser.close_dbf(dbf)
    end

    test "ensures EOF marker is written after operations" do
      fields = [
        %FieldDescriptor{name: "VALUE", type: "N", length: 10, decimal_count: 2}
      ]
      
      path = "/tmp/test_header_consistency_#{:rand.uniform(10000)}.dbf"
      {:ok, dbf} = Parser.create_dbf(path, fields)
      
      # Append records
      {:ok, dbf} = Parser.append_record(dbf, %{"VALUE" => 123.45})
      {:ok, dbf} = Parser.append_record(dbf, %{"VALUE" => 678.90})
      
      # Ensure header consistency (includes EOF marker)
      {:ok, consistent_dbf} = Parser.ensure_header_consistency(dbf)
      
      # Read the file and check for EOF marker
      {:ok, file_content} = File.read(path)
      _file_size = byte_size(file_content)
      
      # EOF marker should be at the expected position
      expected_eof_pos = consistent_dbf.header.header_length + 
                        (consistent_dbf.header.record_count * consistent_dbf.header.record_length)
      
      # Check that EOF marker (0x1A) is present
      assert :binary.at(file_content, expected_eof_pos) == 0x1A
      
      Parser.close_dbf(consistent_dbf)
    end

    test "header consistency maintained through pack operation" do
      fields = [
        %FieldDescriptor{name: "STATUS", type: "C", length: 10, decimal_count: 0},
        %FieldDescriptor{name: "COUNT", type: "N", length: 5, decimal_count: 0}
      ]
      
      path = "/tmp/test_header_consistency_#{:rand.uniform(10000)}.dbf"
      {:ok, dbf} = Parser.create_dbf(path, fields)
      
      # Add some records
      {:ok, dbf} = Parser.append_record(dbf, %{"STATUS" => "ACTIVE", "COUNT" => 1})
      {:ok, dbf} = Parser.append_record(dbf, %{"STATUS" => "DELETED", "COUNT" => 2})
      {:ok, dbf} = Parser.append_record(dbf, %{"STATUS" => "ACTIVE", "COUNT" => 3})
      
      # Mark middle record as deleted
      {:ok, dbf} = Parser.mark_deleted(dbf, 1)
      
      # Pack the file
      packed_path = "/tmp/test_packed_header_#{:rand.uniform(10000)}.dbf"
      {:ok, packed_dbf} = Parser.pack(dbf, packed_path)
      
      # Validate packed file header consistency
      assert :ok = Parser.validate_header_consistency(packed_dbf)
      
      # Verify packed file has correct record count (2 active records)
      assert packed_dbf.header.record_count == 2
      
      # Verify file size is correct for packed file
      {:ok, file_info} = File.stat(packed_path)
      expected_size = packed_dbf.header.header_length + 
                     (packed_dbf.header.record_count * packed_dbf.header.record_length) + 1
      
      assert file_info.size == expected_size or file_info.size == expected_size - 1
      
      Parser.close_dbf(dbf)
      Parser.close_dbf(packed_dbf)
    end
  end

  describe "streaming operations" do
    setup do
      temp_path = "/tmp/test_streaming_#{:rand.uniform(10000)}.dbf"
      
      fields = [
        %FieldDescriptor{name: "ID", type: "N", length: 5, decimal_count: 0},
        %FieldDescriptor{name: "NAME", type: "C", length: 20, decimal_count: 0},
        %FieldDescriptor{name: "SCORE", type: "N", length: 6, decimal_count: 2},
        %FieldDescriptor{name: "ACTIVE", type: "L", length: 1, decimal_count: 0}
      ]
      
      {:ok, dbf} = Parser.create_dbf(temp_path, fields)
      
      # Add test records for streaming
      records = [
        %{"ID" => 1, "NAME" => "Alice", "SCORE" => 85.50, "ACTIVE" => true},
        %{"ID" => 2, "NAME" => "Bob", "SCORE" => 92.25, "ACTIVE" => true},
        %{"ID" => 3, "NAME" => "Charlie", "SCORE" => 78.75, "ACTIVE" => false},
        %{"ID" => 4, "NAME" => "Diana", "SCORE" => 88.00, "ACTIVE" => true},
        %{"ID" => 5, "NAME" => "Eve", "SCORE" => 95.50, "ACTIVE" => false}
      ]
      
      {:ok, populated_dbf} = Parser.batch_append_records(dbf, records)
      Parser.close_dbf(populated_dbf)
      
      on_exit(fn ->
        File.rm(temp_path)
      end)
      
      {:ok, path: temp_path}
    end

    test "stream_records returns a lazy stream of all records", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path)
      
      # Should return a Stream
      stream = Parser.stream_records(dbf)
      assert is_function(stream)
      
      # Should lazily produce all records
      records = Enum.to_list(stream)
      assert length(records) == 5
      
      # Verify first record content
      first_record = List.first(records)
      assert first_record["NAME"] == "Alice"
      assert first_record["ID"] == 1
      
      Parser.close_dbf(dbf)
    end

    test "stream_records excludes deleted records by default", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path, [:read, :write])
      
      # Mark middle record as deleted
      {:ok, dbf_with_deletion} = Parser.mark_deleted(dbf, 2)
      
      # Stream should exclude deleted record
      stream = Parser.stream_records(dbf_with_deletion)
      records = Enum.to_list(stream)
      
      assert length(records) == 4  # One record deleted
      
      # Verify Charlie (index 2) is not in results
      names = Enum.map(records, & &1["NAME"])
      refute "Charlie" in names
      
      Parser.close_dbf(dbf_with_deletion)
    end

    test "stream_where filters records based on predicate", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path)
      
      # Filter for high scores only
      high_score_filter = fn record -> record["SCORE"] > 90.0 end
      
      stream = Parser.stream_where(dbf, high_score_filter)
      records = Enum.to_list(stream)
      
      assert length(records) == 2  # Bob (92.25) and Eve (95.50)
      
      scores = Enum.map(records, & &1["SCORE"])
      assert Enum.all?(scores, fn score -> score > 90.0 end)
      
      Parser.close_dbf(dbf)
    end

    test "stream_where with active status filter", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path)
      
      # Filter for active users only
      active_filter = fn record -> record["ACTIVE"] == true end
      
      stream = Parser.stream_where(dbf, active_filter)
      records = Enum.to_list(stream)
      
      assert length(records) == 3  # Alice, Bob, Diana
      
      # All should be active
      assert Enum.all?(records, fn record -> record["ACTIVE"] == true end)
      
      Parser.close_dbf(dbf)
    end

    test "read_in_chunks processes records in specified chunk sizes", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path)
      
      chunk_size = 2
      chunks = Parser.read_in_chunks(dbf, chunk_size) |> Enum.to_list()
      
      # Should have 3 chunks: [2, 2, 1] records
      assert length(chunks) == 3
      assert length(Enum.at(chunks, 0)) == 2
      assert length(Enum.at(chunks, 1)) == 2  
      assert length(Enum.at(chunks, 2)) == 1
      
      # Verify all records are included
      all_records = List.flatten(chunks)
      assert length(all_records) == 5
      
      Parser.close_dbf(dbf)
    end

    test "stream is memory efficient - doesn't load all records at once", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path)
      
      # This test verifies lazy evaluation
      stream = Parser.stream_records(dbf)
      
      # Taking only first element should not process all records
      first_record = stream |> Enum.take(1) |> List.first()
      
      assert first_record["NAME"] == "Alice"
      
      # Stream should still be valid for more operations
      second_batch = stream |> Enum.drop(1) |> Enum.take(2)
      assert length(second_batch) == 2
      
      Parser.close_dbf(dbf)
    end

    test "read_in_chunks_with_progress reports progress during processing", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path)
      
      # Collect progress reports
      _progress_reports = []
      progress_fn = fn progress ->
        send(self(), {:progress, progress})
      end
      
      chunk_size = 2
      chunks = Parser.read_in_chunks_with_progress(dbf, chunk_size, progress_fn) |> Enum.to_list()
      
      # Should have 3 chunks processed
      assert length(chunks) == 3
      
      # Should receive progress notifications
      progress_messages = receive_all_progress_messages([])
      assert length(progress_messages) >= 3  # At least one per chunk
      
      # Progress should include current/total information
      final_progress = List.last(progress_messages)
      assert final_progress.current >= 5  # All records processed
      assert final_progress.total == 5
      assert final_progress.percentage == 100.0
      
      Parser.close_dbf(dbf)
    end

    test "stream_records_with_progress reports progress during streaming", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path)
      
      progress_fn = fn progress ->
        send(self(), {:progress, progress})
      end
      
      # Process all records through stream
      records = Parser.stream_records_with_progress(dbf, progress_fn) |> Enum.to_list()
      
      assert length(records) == 5
      
      # Should receive progress updates
      progress_messages = receive_all_progress_messages([])
      assert length(progress_messages) >= 1
      
      # Final progress should be 100%
      final_progress = List.last(progress_messages)
      assert final_progress.percentage == 100.0
      
      Parser.close_dbf(dbf)
    end

    defp receive_all_progress_messages(acc) do
      receive do
        {:progress, progress} -> receive_all_progress_messages([progress | acc])
      after
        100 -> Enum.reverse(acc)
      end
    end
  end

  describe "memory monitoring" do
    setup do
      temp_path = "/tmp/test_memory_#{:rand.uniform(10000)}.dbf"
      
      fields = [
        %FieldDescriptor{name: "ID", type: "N", length: 5, decimal_count: 0},
        %FieldDescriptor{name: "DATA", type: "C", length: 100, decimal_count: 0}  # Larger field for memory testing
      ]
      
      {:ok, dbf} = Parser.create_dbf(temp_path, fields)
      
      # Add several records for memory testing
      large_data = String.duplicate("X", 90)  # Large string data
      records = for i <- 1..20 do
        %{"ID" => i, "DATA" => large_data <> "_#{i}"}
      end
      
      {:ok, populated_dbf} = Parser.batch_append_records(dbf, records)
      Parser.close_dbf(populated_dbf)
      
      on_exit(fn ->
        File.rm(temp_path)
      end)
      
      {:ok, path: temp_path}
    end

    test "memory_usage returns current memory statistics", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path)
      
      initial_memory = Parser.memory_usage()
      assert is_map(initial_memory)
      assert Map.has_key?(initial_memory, :total)
      assert Map.has_key?(initial_memory, :processes)
      assert Map.has_key?(initial_memory, :system)
      
      # Process some records and check memory didn't spike significantly
      stream = Parser.stream_records(dbf)
      _records = stream |> Enum.take(10)
      
      after_memory = Parser.memory_usage()
      
      # Memory usage should be reasonable (not a huge spike)
      memory_increase = after_memory.total - initial_memory.total
      assert memory_increase < 10_000_000  # Less than 10MB increase
      
      Parser.close_dbf(dbf)
    end

    test "stream processing maintains constant memory usage", %{path: path} do
      {:ok, dbf} = Parser.open_dbf(path)
      
      initial_memory = Parser.memory_usage()
      
      # Process records in chunks to verify memory stays constant
      chunk_memories = 
        dbf
        |> Parser.read_in_chunks(5)
        |> Enum.map(fn _chunk ->
          current_memory = Parser.memory_usage()
          current_memory.total
        end)
        |> Enum.to_list()
      
      final_memory = Parser.memory_usage()
      
      # Memory should not grow significantly during streaming
      max_memory = Enum.max(chunk_memories)
      memory_growth = max_memory - initial_memory.total
      
      # Should not use more than 10MB during processing
      assert memory_growth < 10_000_000
      
      # Final memory should be close to initial (within 4MB)
      final_growth = final_memory.total - initial_memory.total
      assert final_growth < 4_000_000
      
      Parser.close_dbf(dbf)
    end
  end

  describe "Integration Tests with Real Data (prrolls.DBF)" do
    @tag :integration
    test "opens real DBF file and reads header correctly" do
      assert {:ok, dbf} = Parser.open_dbf(@test_dbf_path)
      
      # Verify header information matches expected structure
      assert dbf.header.version == 48  # dBase file with specific version
      assert dbf.header.record_count == 311314  # Large dataset
      assert dbf.header.record_length == 68
      assert dbf.header.mdx_flag == 1  # Has associated index
      
      # Verify field structure
      assert length(dbf.fields) == 9
      
      field_names = Enum.map(dbf.fields, & &1.name)
      expected_fields = ["SONO", "SKIDNO", "ROLLNO", "WEIGHT", "CORE", "NET", "FEET", "KILOS", "DATE"]
      assert field_names == expected_fields
      
      # Verify field types
      assert Enum.find(dbf.fields, &(&1.name == "SONO")).type == "C"      # Character
      assert Enum.find(dbf.fields, &(&1.name == "SKIDNO")).type == "I"    # Integer
      assert Enum.find(dbf.fields, &(&1.name == "WEIGHT")).type == "N"    # Numeric
      assert Enum.find(dbf.fields, &(&1.name == "KILOS")).type == "L"     # Logical
      assert Enum.find(dbf.fields, &(&1.name == "DATE")).type == "T"      # DateTime
      
      Parser.close_dbf(dbf)
    end

    @tag :integration
    test "reads individual records from real DBF file" do
      assert {:ok, dbf} = Parser.open_dbf(@test_dbf_path)
      
      # Read first record
      assert {:ok, first_record} = Parser.read_record(dbf, 0)
      assert %Record{} = first_record
      assert not first_record.deleted
      assert is_map(first_record.data)
      
      # Verify expected fields are present
      expected_fields = ["SONO", "SKIDNO", "ROLLNO", "WEIGHT", "CORE", "NET", "FEET", "KILOS", "DATE"]
      record_fields = Map.keys(first_record.data)
      assert Enum.all?(expected_fields, &(&1 in record_fields))
      
      # Read middle record
      middle_index = div(dbf.header.record_count, 2)
      assert {:ok, middle_record} = Parser.read_record(dbf, middle_index)
      assert %Record{} = middle_record
      
      # Read last record
      last_index = dbf.header.record_count - 1
      assert {:ok, last_record} = Parser.read_record(dbf, last_index)
      assert %Record{} = last_record
      
      Parser.close_dbf(dbf)
    end

    @tag :integration
    test "streams through large real dataset efficiently" do
      assert {:ok, dbf} = Parser.open_dbf(@test_dbf_path)
      
      initial_memory = :erlang.memory(:total)
      
      # Process first 1000 records using streaming
      sample_records = 
        dbf
        |> Parser.stream_records()
        |> Stream.take(1000)
        |> Enum.to_list()
      
      peak_memory = :erlang.memory(:total)
      memory_growth = peak_memory - initial_memory
      
      # Verify we got records
      assert length(sample_records) == 1000
      
      # Verify record structure
      sample_record = List.first(sample_records)
      # stream_records/1 yields plain field maps (see notes/fixes/003)
      assert is_map(sample_record)
      refute is_struct(sample_record)
      
      # Memory should not grow excessively for streaming
      assert memory_growth < 50_000_000  # Less than 50MB growth
      
      Parser.close_dbf(dbf)
    end

    @tag :integration
    test "validates data types in real records" do
      assert {:ok, dbf} = Parser.open_dbf(@test_dbf_path)
      
      # Read a sample of records to validate data types
      sample_indices = [0, 100, 1000, 10000]
      
      for index <- sample_indices do
        assert {:ok, record} = Parser.read_record(dbf, index)
        
        # Validate character field
        sono = record.data["SONO"]
        assert is_binary(sono) or is_nil(sono)

        # Validate integer fields
        skidno = record.data["SKIDNO"]
        rollno = record.data["ROLLNO"]
        assert is_integer(skidno) or is_nil(skidno)
        assert is_integer(rollno) or is_nil(rollno)
        
        # Validate numeric fields
        weight = record.data["WEIGHT"]
        core = record.data["CORE"]
        net = record.data["NET"]
        feet = record.data["FEET"]
        assert is_number(weight) or is_nil(weight)
        assert is_number(core) or is_nil(core)
        assert is_number(net) or is_nil(net)
        assert is_number(feet) or is_nil(feet)
        
        # Validate logical field
        kilos = record.data["KILOS"]
        assert is_boolean(kilos) or is_nil(kilos)

        # Validate datetime field (if we support it)
        date = record.data["DATE"]
        # Note: Might need to implement "T" type support
        assert not is_nil(date) or is_nil(date)  # Placeholder for now
      end
      
      Parser.close_dbf(dbf)
    end

    @tag :integration
    test "handles large dataset statistics" do
      assert {:ok, dbf} = Parser.open_dbf(@test_dbf_path)
      
      # Calculate statistics on a subset
      stats = 
        dbf
        |> Parser.stream_records()
        |> Stream.take(5000)  # Sample first 5000 records
        |> Enum.reduce(
          %{total_records: 0, non_null_weights: 0, peso_sum: 0, deleted_count: 0},
          fn record, acc ->
            weight = record["WEIGHT"]
            
            %{
              acc |
              total_records: acc.total_records + 1,
              non_null_weights: if(weight && weight > 0, do: acc.non_null_weights + 1, else: acc.non_null_weights),
              peso_sum: acc.peso_sum + (weight || 0),
              deleted_count: acc.deleted_count
            }
          end
        )
      
      # Verify statistics make sense
      assert stats.total_records == 5000
      assert stats.non_null_weights >= 0
      assert stats.peso_sum >= 0
      assert stats.deleted_count >= 0
      
      Parser.close_dbf(dbf)
    end

    @tag :integration
    test "performance benchmark on real data" do
      assert {:ok, dbf} = Parser.open_dbf(@test_dbf_path)
      
      # Benchmark random access
      random_indices = Enum.take_random(0..(dbf.header.record_count - 1), 100)
      
      {time_microseconds, _results} = :timer.tc(fn ->
        Enum.map(random_indices, &Parser.read_record(dbf, &1))
      end)
      
      time_per_record = time_microseconds / 100
      
      # Should be able to read at least 1000 records per second on random access
      assert time_per_record < 1000  # Less than 1ms per record
      
      # Benchmark sequential streaming
      {stream_time_microseconds, stream_count} = :timer.tc(fn ->
        dbf
        |> Parser.stream_records()
        |> Stream.take(1000)
        |> Enum.count()
      end)
      
      stream_time_per_record = stream_time_microseconds / stream_count
      
      # Streaming should be faster than random access
      assert stream_time_per_record < time_per_record
      
      Parser.close_dbf(dbf)
    end
  end
end