defmodule Xbase.Parser do
  @moduledoc """
  Binary parser for DBF file format components.
  
  This module provides functions to parse DBF file headers and field descriptors
  from binary data using Elixir's efficient binary pattern matching.
  """

  alias Xbase.CodePage
  alias Xbase.Types.{Header, FieldDescriptor, Record}

  @doc """
  Parses a 32-byte DBF header from binary data.
  
  ## Parameters  
  - `binary` - The binary data containing the DBF header
  
  ## Returns
  - `{:ok, %Header{}}` - Successfully parsed header
  - `{:error, reason}` - Parse error with reason
  
  ## Examples
      iex> header_data = <<0x03, 124, 12, 17, 100::little-32, 161::little-16, 50::little-16, 0::16, 0, 0, 0::12*8, 0, 0, 0::16>>
      iex> Xbase.Parser.parse_header(header_data)
      {:ok, %Xbase.Types.Header{version: 3, record_count: 100, ...}}
  """
  def parse_header(binary) when byte_size(binary) != 32 do
    {:error, :invalid_header_size}
  end

  def parse_header(binary) do
    case binary do
      <<version, yy, mm, dd, record_count::little-32, 
        header_length::little-16, record_length::little-16,
        _reserved1::16, transaction_flag, encryption_flag,
        _reserved2::12*8, mdx_flag, language_driver, _reserved3::16>> ->
        
        case validate_version(version) do
          :ok ->
            {:ok, %Header{
              version: version,
              last_update_year: yy,
              last_update_month: mm,
              last_update_day: dd,
              record_count: record_count,
              header_length: header_length,
              record_length: record_length,
              transaction_flag: transaction_flag,
              encryption_flag: encryption_flag,
              mdx_flag: mdx_flag,
              language_driver: language_driver
            }}
          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Parses field descriptors from binary data until field terminator (0x0D).
  
  ## Parameters
  - `binary` - The binary data containing field descriptors
  - `offset` - Starting offset in the binary data
  
  ## Returns
  - `{:ok, [%FieldDescriptor{}]}` - List of parsed field descriptors
  - `{:error, reason}` - Parse error with reason
  """
  def parse_fields(binary, offset \\ 0) do
    parse_fields_recursive(binary, offset, [])
  end

  @doc """
  Opens a DBF file and parses its header and field descriptors.
  
  ## Parameters
  - `path` - Path to the DBF file
  
  ## Returns
  - `{:ok, %{header: header, fields: fields, file: file}}` - Successfully opened DBF
  - `{:error, reason}` - Error opening or parsing file
  
  ## Examples
      iex> Xbase.Parser.open_dbf("data.dbf")
      {:ok, %{header: %Header{...}, fields: [...], file: #Port<...>}}
  """
  def open_dbf(path) do
    open_dbf(path, [:read])
  end

  @doc """
  Opens a DBF file and parses its header and field descriptors with specified file modes.

  Character and memo text is converted between the table's code page and
  UTF-8. The code page comes from the header's language driver byte (see
  `Xbase.CodePage`); pass `encoding: :raw | :cp1252 | :cp437 | :cp850` to
  override it, where `:raw` leaves bytes untouched.
  
  ## Parameters
  - `path` - Path to the DBF file
  - `modes` - List of file open modes (e.g., [:read], [:read, :write])
  
  ## Returns
  - `{:ok, %{header: header, fields: fields, file: file}}` - Successfully opened DBF
  - `{:error, reason}` - Error opening or parsing file
  """
  def open_dbf(path, modes, opts \\ []) do
    case Keyword.get(opts, :encoding) do
      nil -> do_open_dbf(path, modes, nil)
      encoding when encoding in [:raw, :cp1252, :cp437, :cp850] -> do_open_dbf(path, modes, encoding)
      other -> {:error, {:invalid_encoding, other}}
    end
  end

  defp do_open_dbf(path, modes, encoding_override) do
    file_modes = modes ++ [:binary, :random]
    
    # Capture initial file modification time for conflict detection
    initial_mtime = case File.stat(path) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      {:error, _} -> nil
    end
    
    case :file.open(path, file_modes) do
      {:ok, file} ->
        case read_and_parse_header(file) do
          {:ok, header} ->
            case read_and_parse_fields(file, header) do
              {:ok, fields} ->
                encoding = encoding_override || CodePage.from_language_driver(header.language_driver)
                {:ok, %{header: header, fields: fields, file: file, file_path: path, initial_mtime: initial_mtime, encoding: encoding}}
              {:error, reason} ->
                :file.close(file)
                {:error, reason}
            end
          {:error, reason} ->
            :file.close(file)
            {:error, reason}
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Closes a DBF file handle.
  
  ## Parameters
  - `dbf` - DBF structure returned from open_dbf/1
  
  ## Returns
  - `:ok` - File closed successfully
  """
  def close_dbf(%{file: file}) do
    :file.close(file)
  end

  @doc """
  Calculates the byte offset for a specific record in the file.
  
  ## Parameters
  - `header` - The DBF header containing file structure information
  - `record_index` - Zero-based record index
  
  ## Returns
  - The byte offset where the record starts
  
  ## Examples
      iex> header = %Header{header_length: 97, record_length: 25}
      iex> Xbase.Parser.calculate_record_offset(header, 0)
      97
      iex> Xbase.Parser.calculate_record_offset(header, 1)
      122
  """
  def calculate_record_offset(%Header{header_length: header_length, record_length: record_length}, record_index) do
    header_length + (record_index * record_length)
  end

  @doc """
  Validates if a record index is within the valid range for the file.
  
  ## Parameters
  - `header` - The DBF header containing record count
  - `record_index` - Zero-based record index to validate
  
  ## Returns
  - `true` if the index is valid, `false` otherwise
  """
  def is_valid_record_index?(%Header{record_count: record_count}, record_index) 
      when record_index >= 0 and record_index < record_count do
    true
  end

  def is_valid_record_index?(_header, _record_index) do
    false
  end

  @doc """
  Extracts the deletion flag from record data.
  
  ## Parameters
  - `record_binary` - The raw record binary data
  
  ## Returns
  - `{:ok, boolean}` - true if deleted (0x2A), false if active (0x20)
  - `{:error, reason}` - Error for invalid data
  """
  def get_deletion_flag(<<>>) do
    {:error, :invalid_record_data}
  end

  def get_deletion_flag(<<deletion_flag, _rest::binary>>) do
    case deletion_flag do
      0x20 -> {:ok, false}  # Active record
      0x2A -> {:ok, true}   # Deleted record
      _ -> {:ok, false}     # Treat other values as active (defensive)
    end
  end

  @doc """
  Parses record field data according to field descriptors.
  
  ## Parameters
  - `record_data` - Binary data for the record fields (without deletion flag)
  - `fields` - List of field descriptors
  
  ## Returns
  - `{:ok, %{field_name => parsed_value}}` - Parsed field data
  - `{:error, reason}` - Parse error
  """
  def parse_record_data(record_data, fields) do
    expected_length = Enum.sum(Enum.map(fields, & &1.length))
    
    if byte_size(record_data) != expected_length do
      {:error, :invalid_record_length}
    else
      parse_fields_from_record(record_data, fields, 0, %{})
    end
  end

  @doc """
  Reads a complete record from the DBF file at the specified index.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  - `record_index` - Zero-based record index
  
  ## Returns
  - `{:ok, %Record{}}` - Successfully parsed record
  - `{:error, reason}` - Error reading or parsing record
  
  ## Examples
      iex> {:ok, dbf} = Xbase.Parser.open_dbf("data.dbf")
      iex> {:ok, record} = Xbase.Parser.read_record(dbf, 0)
      iex> record.data["NAME"]
      "John Doe"
  """
  def read_record(%{header: header, fields: fields, file: file} = dbf, record_index) do
    # Validate record index
    case is_valid_record_index?(header, record_index) do
      false ->
        {:error, :invalid_record_index}
      true ->
        # Calculate offset and read record
        offset = calculate_record_offset(header, record_index)
        
        case :file.pread(file, offset, header.record_length) do
          {:ok, record_binary} ->
            # Extract deletion flag
            case get_deletion_flag(record_binary) do
              {:ok, deleted} ->
                # Parse field data (skip deletion flag)
                <<_deletion_flag, field_data::binary>> = record_binary
                
                case parse_record_data(field_data, fields) do
                  {:ok, parsed_data} ->
                    record = %Record{
                      data: decode_text_fields(parsed_data, fields, encoding(dbf)),
                      deleted: deleted,
                      raw_data: record_binary
                    }
                    {:ok, record}
                  {:error, reason} ->
                    {:error, reason}
                end
              {:error, reason} ->
                {:error, reason}
            end
          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Creates a new DBF file with the specified field structure.
  
  ## Parameters
  - `path` - Path for the new DBF file
  - `fields` - List of field descriptors defining the schema
  - `opts` - Options (version, overwrite)
  
  ## Returns
  - `{:ok, dbf}` - Successfully created DBF file structure
  - `{:error, reason}` - Error creating file
  
  ## Examples
      iex> fields = [%FieldDescriptor{name: "NAME", type: "C", length: 20}]
      iex> {:ok, dbf} = Xbase.Parser.create_dbf("new.dbf", fields)
  """
  def create_dbf(path, fields, opts \\ []) do
    # Validate inputs
    case validate_create_inputs(path, fields, opts) do
      :ok ->
        case build_and_write_dbf(path, fields, opts) do
          {:ok, file} ->
            # Create DBF structure similar to open_dbf
            header = build_header(fields, opts)
            
            # Get initial file modification time
            initial_mtime = case File.stat(path) do
              {:ok, %{mtime: mtime}} -> mtime
              _ -> nil
            end
            
            {:ok, %{header: header, fields: fields, file: file, file_path: path, initial_mtime: initial_mtime, encoding: CodePage.from_language_driver(header.language_driver)}}
          {:error, reason} ->
            {:error, reason}
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Appends a new record to the DBF file.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1 or create_dbf/2
  - `record_data` - Map of field name => value
  
  ## Returns
  - `{:ok, updated_dbf}` - Successfully appended with updated DBF structure
  - `{:error, reason}` - Error appending record
  
  ## Examples
      iex> {:ok, dbf} = Xbase.Parser.open_dbf("data.dbf")
      iex> {:ok, updated_dbf} = Xbase.Parser.append_record(dbf, %{"NAME" => "John", "AGE" => 30})
  """
  def append_record(%{header: header, fields: fields, file: file} = dbf, record_data) do
    # Encode the record data
    case encode_text_fields(fields, record_data, encoding(dbf))
         |> then(fn
           {:ok, record_data} -> encode_record(fields, record_data)
           error -> error
         end) do
      {:ok, encoded_record} ->
        # Calculate where to write the new record
        offset = calculate_record_offset(header, header.record_count)
        
        # Write the record
        case :file.pwrite(file, offset, encoded_record) do
          :ok ->
            # Update header with new record count and timestamp
            updated_header = update_header_for_append(header)
            
            # Write updated header to file with validation
            case write_header_with_validation(file, updated_header, fields) do
              :ok ->
                updated_dbf = %{dbf | header: updated_header}
                # Ensure EOF marker is written
                case write_eof_marker(file, updated_header) do
                  :ok -> {:ok, updated_dbf}
                  {:error, reason} -> {:error, reason}
                end
              {:error, reason} ->
                {:error, reason}
            end
          {:error, reason} ->
            {:error, reason}
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Reads all records from a DBF file.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  
  ## Returns
  - `{:ok, [record_data]}` - List of record data maps
  - `{:error, reason}` - Error reading records
  
  ## Examples
      iex> {:ok, dbf} = Xbase.Parser.open_dbf("data.dbf")
      iex> {:ok, records} = Xbase.Parser.read_records(dbf)
      iex> length(records)
      10
  """
  def read_records(%{header: header} = dbf) do
    read_records_recursive(dbf, 0, header.record_count, [])
  end

  @doc """
  Updates an existing record in the DBF file.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  - `record_index` - Zero-based index of the record to update
  - `update_data` - Map of field name => value for fields to update
  
  ## Returns
  - `{:ok, updated_dbf}` - Successfully updated with updated DBF structure
  - `{:error, reason}` - Error updating record
  
  ## Examples
      iex> {:ok, dbf} = Xbase.Parser.open_dbf("data.dbf")
      iex> {:ok, updated_dbf} = Xbase.Parser.update_record(dbf, 0, %{"NAME" => "Updated", "AGE" => 40})
  """
  def update_record(%{header: header, fields: fields, file: file} = dbf, record_index, update_data) do
    # Validate record index
    case is_valid_record_index?(header, record_index) do
      false ->
        {:error, :invalid_record_index}
      true ->
        # Read the existing record to preserve unmodified fields and deletion flag
        case read_record(dbf, record_index) do
          {:ok, existing_record} ->
            # Merge update data with existing data
            merged_data = Map.merge(existing_record.data, update_data)
            
            # Encode the updated record
            case encode_text_fields(fields, merged_data, encoding(dbf))
                 |> then(fn
                   {:ok, merged_data} -> encode_record_with_deletion_flag(fields, merged_data, existing_record.deleted)
                   error -> error
                 end) do
              {:ok, encoded_record} ->
                # Calculate where to write the updated record
                offset = calculate_record_offset(header, record_index)
                
                # Write the updated record
                case :file.pwrite(file, offset, encoded_record) do
                  :ok ->
                    # Update header timestamp and increment transaction flag for conflict detection
                    updated_header = header
                    |> update_header_timestamp()
                    |> increment_transaction_flag()
                    
                    # Write updated header to file
                    case write_header(file, updated_header) do
                      :ok ->
                        {:ok, %{dbf | header: updated_header}}
                      {:error, reason} ->
                        {:error, reason}
                    end
                  {:error, reason} ->
                    {:error, reason}
                end
              {:error, reason} ->
                {:error, reason}
            end
          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Marks a record as deleted in the DBF file.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  - `record_index` - Zero-based index of the record to mark as deleted
  
  ## Returns
  - `{:ok, updated_dbf}` - Successfully marked as deleted with updated DBF structure
  - `{:error, reason}` - Error marking record as deleted
  
  ## Examples
      iex> {:ok, dbf} = Xbase.Parser.open_dbf("data.dbf")
      iex> {:ok, updated_dbf} = Xbase.Parser.mark_deleted(dbf, 2)
  """
  def mark_deleted(%{header: header} = dbf, record_index) do
    case is_valid_record_index?(header, record_index) do
      false ->
        {:error, :invalid_record_index}
      true ->
        update_deletion_flag(dbf, record_index, true)
    end
  end

  @doc """
  Undeletes a previously deleted record in the DBF file.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  - `record_index` - Zero-based index of the record to undelete
  
  ## Returns
  - `{:ok, updated_dbf}` - Successfully undeleted with updated DBF structure
  - `{:error, reason}` - Error undeleting record
  
  ## Examples
      iex> {:ok, dbf} = Xbase.Parser.open_dbf("data.dbf")
      iex> {:ok, updated_dbf} = Xbase.Parser.undelete_record(dbf, 2)
  """
  def undelete_record(%{header: header} = dbf, record_index) do
    case is_valid_record_index?(header, record_index) do
      false ->
        {:error, :invalid_record_index}
      true ->
        update_deletion_flag(dbf, record_index, false)
    end
  end

  @doc """
  Packs a DBF file by removing all deleted records and creating a compacted file.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  - `output_path` - Path for the packed output file
  
  ## Returns
  - `{:ok, packed_dbf}` - Successfully packed DBF file structure
  - `{:error, reason}` - Error packing file
  
  ## Examples
      iex> {:ok, dbf} = Xbase.Parser.open_dbf("data.dbf")
      iex> {:ok, packed_dbf} = Xbase.Parser.pack(dbf, "data_packed.dbf")
  """
  def pack(%{header: header, fields: fields} = dbf, output_path) do
    # Collect all active (non-deleted) records
    case collect_active_records(dbf) do
      {:ok, active_records} ->
        # Create a new packed file with the active records
        case create_packed_file(output_path, fields, active_records, header, encoding(dbf)) do
          {:ok, packed_dbf} ->
            {:ok, packed_dbf}
          {:error, reason} ->
            {:error, reason}
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Counts the number of active (non-deleted) records in the DBF file.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  
  ## Returns
  - `{:ok, count}` - Number of active records
  - `{:error, reason}` - Error reading records
  
  ## Examples
      iex> {:ok, dbf} = Xbase.Parser.open_dbf("data.dbf")
      iex> Xbase.Parser.count_active_records(dbf)
      {:ok, 150}
  """
  def count_active_records(%{header: header} = dbf) do
    count_records_by_status(dbf, header.record_count, false)
  end

  @doc """
  Counts the number of deleted records in the DBF file.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  
  ## Returns
  - `{:ok, count}` - Number of deleted records
  - `{:error, reason}` - Error reading records
  
  ## Examples
      iex> {:ok, dbf} = Xbase.Parser.open_dbf("data.dbf")
      iex> Xbase.Parser.count_deleted_records(dbf)
      {:ok, 25}
  """
  def count_deleted_records(%{header: header} = dbf) do
    count_records_by_status(dbf, header.record_count, true)
  end

  @doc """
  Provides comprehensive statistics about records in the DBF file.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  
  ## Returns
  - `{:ok, %{total_records: int, active_records: int, deleted_records: int, deletion_percentage: float}}` - Statistics
  - `{:error, reason}` - Error reading records
  
  ## Examples
      iex> {:ok, dbf} = Xbase.Parser.open_dbf("data.dbf")
      iex> Xbase.Parser.record_statistics(dbf)
      {:ok, %{total_records: 100, active_records: 85, deleted_records: 15, deletion_percentage: 15.0}}
  """
  def record_statistics(%{header: header} = dbf) do
    total_records = header.record_count
    
    if total_records == 0 do
      {:ok, %{
        total_records: 0,
        active_records: 0,
        deleted_records: 0,
        deletion_percentage: 0.0
      }}
    else
      case count_active_records(dbf) do
        {:ok, active_count} ->
          deleted_count = total_records - active_count
          deletion_percentage = (deleted_count / total_records) * 100.0
          
          {:ok, %{
            total_records: total_records,
            active_records: active_count,
            deleted_records: deleted_count,
            deletion_percentage: deletion_percentage
          }}
        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Deletes multiple records by their indices in a single operation.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  - `indices` - List of record indices to delete
  
  ## Returns
  - `{:ok, updated_dbf}` - Successfully deleted records
  - `{:error, reason}` - Error during deletion
  
  ## Examples
      iex> {:ok, dbf} = Xbase.Parser.open_dbf("data.dbf", [:read, :write])
      iex> Xbase.Parser.batch_delete(dbf, [1, 5, 10])
      {:ok, updated_dbf}
  """
  def batch_delete(dbf, indices) when is_list(indices) do
    # Validate all indices first
    case validate_indices(dbf, indices) do
      :ok ->
        # Remove duplicates and sort for efficient processing
        unique_indices = indices |> Enum.uniq() |> Enum.sort()
        batch_delete_by_indices(dbf, unique_indices)
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Deletes records in a specified index range (inclusive).
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  - `start_index` - Starting index (inclusive)
  - `end_index` - Ending index (inclusive)
  
  ## Returns
  - `{:ok, updated_dbf}` - Successfully deleted records in range
  - `{:error, reason}` - Error during deletion
  
  ## Examples
      iex> {:ok, dbf} = Xbase.Parser.open_dbf("data.dbf", [:read, :write])
      iex> Xbase.Parser.batch_delete_range(dbf, 10, 20)
      {:ok, updated_dbf}
  """
  def batch_delete_range(%{header: header} = dbf, start_index, end_index) 
      when is_integer(start_index) and is_integer(end_index) do
    cond do
      start_index > end_index ->
        {:error, :invalid_range}
      start_index < 0 or end_index >= header.record_count ->
        {:error, :invalid_record_index}
      true ->
        indices = Enum.to_list(start_index..end_index)
        batch_delete_by_indices(dbf, indices)
    end
  end

  @doc """
  Deletes records that match a given condition function.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  - `condition_fn` - Function that takes record data and returns true to delete
  
  ## Returns
  - `{:ok, updated_dbf}` - Successfully deleted matching records
  - `{:error, reason}` - Error during deletion
  
  ## Examples
      iex> {:ok, dbf} = Xbase.Parser.open_dbf("data.dbf", [:read, :write])
      iex> condition = fn record -> record["STATUS"] == "inactive" end
      iex> Xbase.Parser.batch_delete_where(dbf, condition)
      {:ok, updated_dbf}
  """
  def batch_delete_where(%{header: header} = dbf, condition_fn) when is_function(condition_fn, 1) do
    case find_matching_indices(dbf, header.record_count, condition_fn) do
      {:ok, matching_indices} ->
        batch_delete_by_indices(dbf, matching_indices)
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Appends multiple records to the DBF file in a single batch operation.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  - `records` - List of record data maps to append
  
  ## Returns
  - `{:ok, updated_dbf}` - Successfully appended all records
  - `{:error, reason}` - Error during batch append
  
  ## Examples
      iex> {:ok, dbf} = Xbase.Parser.open_dbf("data.dbf", [:read, :write])
      iex> records = [%{"NAME" => "John"}, %{"NAME" => "Jane"}]
      iex> Xbase.Parser.batch_append_records(dbf, records)
      {:ok, updated_dbf}
  """
  def batch_append_records(dbf, []) do
    {:ok, dbf}
  end

  def batch_append_records(%{header: header, fields: fields, file: file} = dbf, records) when is_list(records) do
    # Encode all records first to validate them
    case encode_text_records(fields, records, encoding(dbf))
         |> then(fn
           {:ok, records} -> batch_encode_records(fields, records)
           error -> error
         end) do
      {:ok, encoded_records} ->
        # Calculate starting offset for new records
        start_offset = calculate_record_offset(header, header.record_count)
        
        # Write all records in batch
        case batch_write_records(file, start_offset, encoded_records) do
          :ok ->
            # Update header with new record count and timestamp
            new_record_count = header.record_count + length(records)
            updated_header = %{update_header_timestamp(header) | record_count: new_record_count}
            
            case write_header_with_validation(file, updated_header, fields) do
              :ok ->
                updated_dbf = %{dbf | header: updated_header}
                # Ensure EOF marker is written
                case write_eof_marker(file, updated_header) do
                  :ok -> {:ok, updated_dbf}
                  {:error, reason} -> {:error, reason}
                end
              {:error, reason} ->
                {:error, reason}
            end
          {:error, reason} ->
            {:error, reason}
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Updates multiple records by their indices in a single batch operation.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  - `updates` - List of {index, update_data} tuples
  
  ## Returns
  - `{:ok, updated_dbf}` - Successfully updated all records
  - `{:error, reason}` - Error during batch update
  
  ## Examples
      iex> {:ok, dbf} = Xbase.Parser.open_dbf("data.dbf", [:read, :write])
      iex> updates = [{0, %{"NAME" => "John"}}, {2, %{"STATUS" => "active"}}]
      iex> Xbase.Parser.batch_update_records(dbf, updates)
      {:ok, updated_dbf}
  """
  def batch_update_records(dbf, []) do
    {:ok, dbf}
  end

  def batch_update_records(%{header: header, fields: fields, file: file} = dbf, updates) when is_list(updates) do
    # Validate all indices first
    indices = Enum.map(updates, fn {index, _data} -> index end)
    case validate_indices(dbf, indices) do
      :ok ->
        # Process each update
        case batch_process_updates(dbf, fields, updates) do
          {:ok, encoded_updates} ->
            # Write all updates in batch
            case batch_write_record_updates(file, encoded_updates) do
              :ok ->
                # Update header timestamp and increment transaction flag for conflict detection
                updated_header = header
                |> update_header_timestamp()
                |> increment_transaction_flag()
                case write_header(file, updated_header) do
                  :ok ->
                    {:ok, %{dbf | header: updated_header}}
                  {:error, reason} ->
                    {:error, reason}
                end
              {:error, reason} ->
                {:error, reason}
            end
          {:error, reason} ->
            {:error, reason}
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Updates records that match a given condition function.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  - `condition_fn` - Function that takes record data and returns true to update
  - `update_data` - Map of field updates to apply
  
  ## Returns
  - `{:ok, updated_dbf}` - Successfully updated matching records
  - `{:error, reason}` - Error during batch update
  
  ## Examples
      iex> {:ok, dbf} = Xbase.Parser.open_dbf("data.dbf", [:read, :write])
      iex> condition = fn record -> record["STATUS"] == "pending" end
      iex> Xbase.Parser.batch_update_where(dbf, condition, %{"STATUS" => "active"})
      {:ok, updated_dbf}
  """
  def batch_update_where(%{header: header} = dbf, condition_fn, update_data) when is_function(condition_fn, 1) do
    case find_matching_indices(dbf, header.record_count, condition_fn) do
      {:ok, matching_indices} ->
        # Convert indices to update tuples
        updates = Enum.map(matching_indices, fn index -> {index, update_data} end)
        batch_update_records(dbf, updates)
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Refreshes the DBF structure by re-reading the header and fields from file.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  
  ## Returns
  - `{:ok, refreshed_dbf}` - DBF with updated header and fields
  - `{:error, reason}` - Error refreshing from file
  
  ## Examples
      iex> {:ok, dbf} = Xbase.Parser.open_dbf("data.dbf", [:read, :write])
      iex> Xbase.Parser.refresh_dbf_state(dbf)
      {:ok, refreshed_dbf}
  """
  def refresh_dbf_state(%{file: file, file_path: file_path} = dbf) do
    # Seek to beginning of file
    :file.position(file, 0)
    
    case read_and_parse_header(file) do
      {:ok, header} ->
        case read_and_parse_fields(file, header) do
          {:ok, fields} ->
            # Get the current file modification time
            initial_mtime = case File.stat(file_path) do
              {:ok, %{mtime: mtime}} -> mtime
              _ -> nil
            end
            
            {:ok, %{header: header, fields: fields, file: file, file_path: file_path, initial_mtime: initial_mtime, encoding: encoding(dbf)}}
          {:error, reason} ->
            {:error, reason}
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Updates a record with write conflict detection.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  - `record_index` - Index of record to update
  - `update_data` - Map of field updates
  
  ## Returns
  - `{:ok, updated_dbf}` - Successfully updated record
  - `{:error, :write_conflict}` - File was modified by another process
  - `{:error, reason}` - Other error during update
  
  ## Examples
      iex> {:ok, dbf} = Xbase.Parser.open_dbf("data.dbf", [:read, :write])
      iex> Xbase.Parser.update_record_with_conflict_check(dbf, 0, %{"NAME" => "John"})
      {:ok, updated_dbf}
  """
  def update_record_with_conflict_check(dbf, record_index, update_data) do
    case check_for_write_conflict(dbf) do
      :ok ->
        update_record(dbf, record_index, update_data)
      {:error, :write_conflict} ->
        {:error, :write_conflict}
    end
  end

  @doc """
  Updates multiple records with write conflict detection.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  - `updates` - List of {index, update_data} tuples
  
  ## Returns
  - `{:ok, updated_dbf}` - Successfully updated records
  - `{:error, :write_conflict}` - File was modified by another process
  - `{:error, reason}` - Other error during batch update
  """
  def batch_update_records_with_conflict_check(dbf, updates) do
    case check_for_write_conflict(dbf) do
      :ok ->
        batch_update_records(dbf, updates)
      {:error, :write_conflict} ->
        {:error, :write_conflict}
    end
  end

  @doc """
  Marks a record as deleted with write conflict detection.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  - `record_index` - Index of record to delete
  
  ## Returns
  - `{:ok, updated_dbf}` - Successfully marked record as deleted
  - `{:error, :write_conflict}` - File was modified by another process
  - `{:error, reason}` - Other error during deletion
  """
  def mark_deleted_with_conflict_check(dbf, record_index) do
    case check_for_write_conflict(dbf) do
      :ok ->
        mark_deleted(dbf, record_index)
      {:error, :write_conflict} ->
        {:error, :write_conflict}
    end
  end

  @doc """
  Packs a DBF file with write conflict detection.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  - `output_path` - Path for the packed file
  
  ## Returns
  - `{:ok, packed_dbf}` - Successfully packed file
  - `{:error, :write_conflict}` - File was modified by another process
  - `{:error, reason}` - Other error during packing
  """
  def pack_with_conflict_check(dbf, output_path) do
    case check_for_write_conflict(dbf) do
      :ok ->
        pack(dbf, output_path)
      {:error, :write_conflict} ->
        {:error, :write_conflict}
    end
  end

  @doc """
  Updates a record with automatic retry on conflict detection.
  
  This function automatically refreshes the DBF state if a write conflict
  is detected and retries the operation once.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  - `record_index` - Index of record to update
  - `update_data` - Map of field updates
  
  ## Returns
  - `{:ok, updated_dbf}` - Successfully updated record
  - `{:error, reason}` - Error during update (after retry if conflict occurred)
  """
  def update_record_with_retry(dbf, record_index, update_data) do
    case update_record_with_conflict_check(dbf, record_index, update_data) do
      {:ok, updated_dbf} ->
        {:ok, updated_dbf}
      {:error, :write_conflict} ->
        # Refresh and retry once
        case refresh_dbf_state(dbf) do
          {:ok, refreshed_dbf} ->
            update_record(refreshed_dbf, record_index, update_data)
          {:error, reason} ->
            {:error, reason}
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Executes a transaction function with rollback capability.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  - `transaction_fn` - Function that takes a DBF and returns {:ok, updated_dbf} or {:error, reason}
  
  ## Returns
  - `{:ok, final_dbf}` - Successfully committed transaction
  - `{:error, reason}` - Transaction failed and was rolled back
  
  ## Examples
      iex> {:ok, dbf} = Xbase.Parser.open_dbf("data.dbf")
      iex> {:ok, final_dbf} = Xbase.Parser.transaction(dbf, fn dbf ->
      ...>   {:ok, dbf1} = Xbase.Parser.append_record(dbf, %{"NAME" => "John"})
      ...>   {:ok, dbf2} = Xbase.Parser.update_record(dbf1, 0, %{"STATUS" => "active"})
      ...>   {:ok, dbf2}
      ...> end)
  """
  def transaction(dbf, transaction_fn) when is_function(transaction_fn, 1) do
    # Get the file path from the DBF structure
    file_path = get_file_path(dbf)
    backup_path = file_path <> ".backup"
    
    # Close the current file to avoid descriptor conflicts
    close_dbf(dbf)
    
    # Create backup of the original file
    case create_backup(file_path, backup_path) do
      :ok ->
        # Reopen the file for the transaction with read-write access
        case open_dbf(file_path, [:read, :write]) do
          {:ok, reopened_dbf} ->
            try do
              # Execute the transaction function with the reopened DBF
              result = transaction_fn.(reopened_dbf)
              
              case result do
                {:ok, updated_dbf} ->
                  # Transaction succeeded - close file and clean up backup
                  close_dbf(updated_dbf)
                  cleanup_backup(backup_path)
                  # Return the final state by reopening the file
                  open_dbf(file_path, [:read, :write])
                
                {:error, reason} ->
                  # Transaction failed - close file and restore from backup
                  close_dbf(reopened_dbf)
                  restore_from_backup(file_path, backup_path)
                  {:error, reason}
                
                _invalid_return ->
                  # Invalid return value - close file and restore from backup
                  close_dbf(reopened_dbf)
                  restore_from_backup(file_path, backup_path)
                  {:error, :invalid_transaction_return}
              end
            rescue
              exception ->
                # Exception occurred - close file and restore from backup
                close_dbf(reopened_dbf)
                restore_from_backup(file_path, backup_path)
                {:error, exception}
            end
          
          {:error, reason} ->
            # Failed to reopen file - restore from backup
            restore_from_backup(file_path, backup_path)
            {:error, {:reopen_failed, reason}}
        end
      
      {:error, reason} ->
        {:error, {:backup_failed, reason}}
    end
  end

  # Private functions

  defp validate_create_inputs(path, fields, opts) do
    cond do
      length(fields) == 0 ->
        {:error, :no_fields}
      
      not valid_field_names?(fields) ->
        {:error, :invalid_field_name}
      
      File.exists?(path) and not Keyword.get(opts, :overwrite, false) ->
        {:error, :file_exists}
      
      true ->
        :ok
    end
  end

  defp valid_field_names?(fields) do
    Enum.all?(fields, fn field ->
      byte_size(field.name) <= 10 and byte_size(field.name) > 0
    end)
  end

  defp build_and_write_dbf(path, fields, opts) do
    version = Keyword.get(opts, :version, 0x03)
    
    # Calculate sizes
    field_count = length(fields)
    header_length = 32 + (field_count * 32) + 1  # header + fields + terminator
    record_length = 1 + Enum.sum(Enum.map(fields, & &1.length))  # deletion flag + field data
    
    # Get current date
    {{year, month, day}, _time} = :calendar.local_time()
    
    # Build header
    header_binary = <<
      version,
      year - 1900, month, day,   # last update date
      0::little-32,              # record count (initially 0)
      header_length::little-16,
      record_length::little-16,
      0::16,                     # reserved
      0, 0,                      # transaction, encryption flags
      0::12*8,                   # reserved (12 bytes)
      0, 0,                      # MDX flag, language driver
      0::16                      # reserved
    >>
    
    # Build field descriptors
    field_binaries = Enum.map(fields, &build_field_descriptor/1)
    fields_binary = Enum.join(field_binaries) <> <<0x0D>>  # Add terminator
    
    # Write complete file with EOF marker
    complete_binary = header_binary <> fields_binary <> <<0x1A>>
    
    case :file.open(path, [:write, :read, :binary, :random]) do
      {:ok, file} ->
        case :file.write(file, complete_binary) do
          :ok -> {:ok, file}
          {:error, reason} ->
            :file.close(file)
            {:error, reason}
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_header(fields, opts) do
    version = Keyword.get(opts, :version, 0x03)
    field_count = length(fields)
    header_length = 32 + (field_count * 32) + 1
    record_length = 1 + Enum.sum(Enum.map(fields, & &1.length))
    
    {{year, month, day}, _time} = :calendar.local_time()
    
    %Header{
      version: version,
      last_update_year: year - 1900,
      last_update_month: month,
      last_update_day: day,
      record_count: 0,
      header_length: header_length,
      record_length: record_length,
      transaction_flag: 0,
      encryption_flag: 0,
      mdx_flag: 0,
      language_driver: 0
    }
  end

  defp build_field_descriptor(field) do
    # Pad name to 11 bytes with null bytes
    padded_name = String.pad_trailing(field.name, 11, <<0>>)
    
    <<
      padded_name::binary-size(11),
      field.type::binary-size(1),
      0::32,                    # data address (unused)
      field.length,
      field.decimal_count,
      0::16,                    # reserved
      0,                        # work area ID
      0::16,                    # reserved
      0,                        # set fields flag
      0::7*8,                   # reserved (7 bytes)
      0                         # index field flag
    >>
  end

  defp parse_fields_from_record(_data, [], _offset, acc) do
    {:ok, acc}
  end

  defp parse_fields_from_record(data, [field | rest_fields], offset, acc) do
    field_length = field.length
    
    case data do
      <<_::binary-size(^offset), field_data::binary-size(^field_length), _::binary>> ->
        case Xbase.FieldParser.parse(field, field_data) do
          {:ok, parsed_value} ->
            updated_acc = Map.put(acc, field.name, parsed_value)
            parse_fields_from_record(data, rest_fields, offset + field_length, updated_acc)
          {:error, reason} ->
            {:error, reason}
        end
      _ ->
        {:error, :invalid_record_length}
    end
  end

  defp read_and_parse_header(file) do
    case :file.read(file, 32) do
      {:ok, header_binary} ->
        parse_header(header_binary)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_and_parse_fields(file, header) do
    # Calculate how many bytes to read for fields
    # header_length - 32 (header size) = field descriptors + terminator
    fields_size = header.header_length - 32
    
    case :file.read(file, fields_size) do
      {:ok, fields_binary} ->
        parse_fields(fields_binary, 0)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_version(version) do
    case version do
      0x02 -> :ok  # FoxBASE
      0x03 -> :ok  # dBase III without memo
      0x04 -> :ok  # dBase IV without memo
      0x05 -> :ok  # dBase V without memo
      0x07 -> :ok  # Visual Objects
      0x30 -> :ok  # Visual FoxPro
      0x31 -> :ok  # Visual FoxPro with AutoIncrement
      0x83 -> :ok  # dBase III with memo
      0x8B -> :ok  # dBase IV with memo
      0x8E -> :ok  # dBase IV with SQL table
      0xF5 -> :ok  # FoxPro with memo
      _ -> {:error, :invalid_version}
    end
  end

  defp parse_fields_recursive(binary, offset, acc) do
    if offset >= byte_size(binary) do
      {:error, :missing_field_terminator}
    else
      case binary do
        <<_::binary-size(^offset), 0x0D, _::binary>> ->
          {:ok, Enum.reverse(acc)}
        
        _ when offset + 32 <= byte_size(binary) ->
          <<_::binary-size(^offset), field_data::binary-size(32), _rest::binary>> = binary
          case parse_single_field(field_data) do
            {:ok, field} ->
              parse_fields_recursive(binary, offset + 32, [field | acc])
          end
        
        _ ->
          {:error, :missing_field_terminator}
      end
    end
  end

  defp parse_single_field(field_binary) do
    case field_binary do
      <<name::binary-size(11), type::binary-size(1), _data_address::32,
        length, decimal_count, _reserved1::16, work_area_id, _reserved2::16,
        set_fields_flag, _reserved3::7*8, index_field_flag>> ->
        
        # Clean field name (remove null bytes and trim)
        clean_name = name 
          |> :binary.replace(<<0>>, "", [:global]) 
          |> String.trim()
        
        {:ok, %FieldDescriptor{
          name: clean_name,
          type: type,
          length: length,
          decimal_count: decimal_count,
          work_area_id: work_area_id,
          set_fields_flag: set_fields_flag,
          index_field_flag: index_field_flag
        }}
    end
  end

  defp encoding(dbf), do: Map.get(dbf, :encoding, :raw)

  # Character fields are stored in the table's code page and exposed as UTF-8.
  defp decode_text_fields(data, _fields, :raw), do: data

  defp decode_text_fields(data, fields, encoding) do
    Enum.reduce(fields, data, fn
      %FieldDescriptor{type: "C", name: name}, acc ->
        case acc do
          %{^name => value} when is_binary(value) -> %{acc | name => CodePage.decode(value, encoding)}
          _ -> acc
        end

      _field, acc ->
        acc
    end)
  end

  defp encode_text_fields(_fields, data, :raw), do: {:ok, data}

  defp encode_text_fields(fields, data, encoding) do
    Enum.reduce_while(fields, {:ok, data}, fn
      %FieldDescriptor{type: "C", name: name}, {:ok, acc} ->
        case acc do
          %{^name => value} when is_binary(value) ->
            case CodePage.encode(value, encoding) do
              {:ok, encoded} -> {:cont, {:ok, %{acc | name => encoded}}}
              {:error, {:unencodable, char}} -> {:halt, {:error, {:unencodable, name, char}}}
            end

          _ ->
            {:cont, {:ok, acc}}
        end

      _field, ok ->
        {:cont, ok}
    end)
  end

  defp encode_text_records(fields, records, encoding) do
    records
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, acc} ->
      case encode_text_fields(fields, record, encoding) do
        {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, encoded} -> {:ok, Enum.reverse(encoded)}
      error -> error
    end
  end

  defp encode_record(fields, record_data) do
    # Start with deletion flag (0x20 = active record)
    initial_binary = <<0x20>>
    
    # Encode each field
    encode_fields_recursive(fields, record_data, initial_binary)
  end

  defp encode_record_with_deletion_flag(fields, record_data, deleted) do
    # Use appropriate deletion flag
    deletion_flag = if deleted, do: <<0x2A>>, else: <<0x20>>
    
    # Encode each field
    encode_fields_recursive(fields, record_data, deletion_flag)
  end

  defp encode_fields_recursive([], _record_data, acc) do
    {:ok, acc}
  end

  defp encode_fields_recursive([field | rest], record_data, acc) do
    # Get value for field, using default if not provided
    value = Map.get(record_data, field.name, get_default_value(field.type))
    
    # Encode the field value
    case Xbase.FieldEncoder.encode(field, value) do
      {:ok, encoded_value} ->
        encode_fields_recursive(rest, record_data, acc <> encoded_value)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_default_value(type) do
    case type do
      "C" -> ""          # Character - empty string
      "N" -> 0           # Numeric - zero
      "L" -> false       # Logical - false
      "D" -> nil         # Date - nil (will be encoded as spaces)
      "M" -> {:memo_ref, 0}  # Memo - zero block reference as tuple
      _ -> ""            # Default to empty string
    end
  end

  defp update_header_for_append(header) do
    {{year, month, day}, _time} = :calendar.local_time()
    
    %{header |
      record_count: header.record_count + 1,
      last_update_year: year - 1900,
      last_update_month: month,
      last_update_day: day
    }
  end

  defp update_header_timestamp(header) do
    {{year, month, day}, _time} = :calendar.local_time()
    
    %{header |
      last_update_year: year - 1900,
      last_update_month: month,
      last_update_day: day
    }
  end

  defp increment_transaction_flag(header) do
    # Use transaction_flag as a write counter for conflict detection
    # Wrap around at 255 to stay within byte range
    new_flag = rem(header.transaction_flag + 1, 256)
    %{header | transaction_flag: new_flag}
  end

  def write_header(file, header) do
    header_binary = <<
      header.version,
      header.last_update_year,
      header.last_update_month,
      header.last_update_day,
      header.record_count::little-32,
      header.header_length::little-16,
      header.record_length::little-16,
      0::16,                              # reserved
      header.transaction_flag,
      header.encryption_flag,
      0::12*8,                            # reserved (12 bytes)
      header.mdx_flag,
      header.language_driver,
      0::16                               # reserved
    >>
    
    case :file.pwrite(file, 0, header_binary) do
      :ok ->
        # Sync to ensure changes are written to disk for conflict detection
        :file.sync(file)
      error ->
        error
    end
  end

  defp read_records_recursive(_dbf, index, max, acc) when index >= max do
    {:ok, Enum.reverse(acc)}
  end

  defp read_records_recursive(dbf, index, max, acc) do
    case read_record(dbf, index) do
      {:ok, record} ->
        # Only include non-deleted records
        if record.deleted do
          read_records_recursive(dbf, index + 1, max, acc)
        else
          read_records_recursive(dbf, index + 1, max, [record.data | acc])
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_deletion_flag(%{header: header, file: file} = dbf, record_index, deleted) do
    # Calculate the offset to the deletion flag (first byte of the record)
    offset = calculate_record_offset(header, record_index)
    
    # Set the appropriate deletion flag
    deletion_flag = if deleted, do: <<0x2A>>, else: <<0x20>>
    
    # Write just the deletion flag
    case :file.pwrite(file, offset, deletion_flag) do
      :ok ->
        # Update header timestamp and increment transaction flag for conflict detection
        updated_header = header
        |> update_header_timestamp()
        |> increment_transaction_flag()
        
        # Write updated header to file
        case write_header(file, updated_header) do
          :ok ->
            {:ok, %{dbf | header: updated_header}}
          {:error, reason} ->
            {:error, reason}
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_active_records(%{header: header} = dbf) do
    collect_active_records_recursive(dbf, 0, header.record_count, [])
  end

  defp collect_active_records_recursive(_dbf, index, max, acc) when index >= max do
    {:ok, Enum.reverse(acc)}
  end

  defp collect_active_records_recursive(dbf, index, max, acc) do
    case read_record(dbf, index) do
      {:ok, record} ->
        # Only collect non-deleted records
        if record.deleted do
          collect_active_records_recursive(dbf, index + 1, max, acc)
        else
          collect_active_records_recursive(dbf, index + 1, max, [record.data | acc])
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_packed_file(output_path, fields, active_records, original_header, encoding) do
    # Calculate new record count
    active_count = length(active_records)
    
    # Build header for packed file
    field_count = length(fields)
    header_length = 32 + (field_count * 32) + 1
    record_length = 1 + Enum.sum(Enum.map(fields, & &1.length))
    
    {{year, month, day}, _time} = :calendar.local_time()
    
    # Create new header with updated record count and timestamp
    packed_header = %{original_header |
      record_count: active_count,
      header_length: header_length,
      record_length: record_length,
      last_update_year: year - 1900,
      last_update_month: month,
      last_update_day: day
    }
    
    # Build complete file binary
    header_binary = build_header_binary(packed_header)
    field_binaries = Enum.map(fields, &build_field_descriptor/1)
    fields_binary = Enum.join(field_binaries) <> <<0x0D>>
    
    # Encode all active records
    case encode_text_records(fields, active_records, encoding)
         |> then(fn
           {:ok, active_records} -> encode_all_records(fields, active_records)
           error -> error
         end) do
      {:ok, records_binary} ->
        complete_binary = header_binary <> fields_binary <> records_binary
        
        # Write the packed file
        case :file.open(output_path, [:write, :read, :binary, :random]) do
          {:ok, file} ->
            case :file.write(file, complete_binary) do
              :ok ->
                {:ok, %{header: packed_header, fields: fields, file: file, file_path: output_path, encoding: encoding}}
              {:error, reason} ->
                :file.close(file)
                {:error, reason}
            end
          {:error, reason} ->
            {:error, reason}
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_header_binary(header) do
    <<
      header.version,
      header.last_update_year,
      header.last_update_month,
      header.last_update_day,
      header.record_count::little-32,
      header.header_length::little-16,
      header.record_length::little-16,
      0::16,                              # reserved
      header.transaction_flag,
      header.encryption_flag,
      0::12*8,                            # reserved (12 bytes)
      header.mdx_flag,
      header.language_driver,
      0::16                               # reserved
    >>
  end

  defp encode_all_records(fields, records) do
    encode_all_records_recursive(fields, records, <<>>)
  end

  defp encode_all_records_recursive(_fields, [], acc) do
    {:ok, acc}
  end

  defp encode_all_records_recursive(fields, [record | rest], acc) do
    case encode_record(fields, record) do
      {:ok, encoded_record} ->
        encode_all_records_recursive(fields, rest, acc <> encoded_record)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_for_write_conflict(%{file_path: path, initial_mtime: initial_mtime} = dbf) do
    # First check file modification time
    case File.stat(path) do
      {:ok, %{mtime: current_mtime}} ->
        if current_mtime != initial_mtime do
          {:error, :write_conflict}
        else
          # Also check header for changes
          check_header_for_conflict(dbf)
        end
      {:error, _reason} ->
        {:error, :write_conflict}
    end
  end
  
  defp check_header_for_conflict(%{header: cached_header, file: file} = _dbf) do
    # Save current file position
    {:ok, current_pos} = :file.position(file, :cur)
    
    # Re-read header from file to check for changes
    :file.position(file, 0)  # Go to start of file
    
    result = case :file.read(file, 32) do
      {:ok, header_binary} ->
        case parse_header(header_binary) do
          {:ok, current_header} ->
            # Check if header has changed (record count, update date, transaction flag)
            if cached_header.record_count != current_header.record_count or
               cached_header.last_update_year != current_header.last_update_year or
               cached_header.last_update_month != current_header.last_update_month or
               cached_header.last_update_day != current_header.last_update_day or
               cached_header.transaction_flag != current_header.transaction_flag do
              {:error, :write_conflict}
            else
              :ok
            end
          {:error, _reason} ->
            # If we can't parse the header, assume a write conflict occurred
            {:error, :write_conflict}
        end
      {:error, _reason} ->
        # If we can't read the header, assume a write conflict occurred
        {:error, :write_conflict}
    end
    
    # Restore file position
    :file.position(file, current_pos)
    result
  end


  defp batch_encode_records(fields, records) do
    batch_encode_records_recursive(fields, records, [])
  end

  defp batch_encode_records_recursive(_fields, [], acc) do
    {:ok, Enum.reverse(acc)}
  end

  defp batch_encode_records_recursive(fields, [record | rest], acc) do
    case encode_record(fields, record) do
      {:ok, encoded_record} ->
        batch_encode_records_recursive(fields, rest, [encoded_record | acc])
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp batch_write_records(file, start_offset, encoded_records) do
    # Concatenate all encoded records into one binary
    all_records_binary = Enum.join(encoded_records)
    
    # Write all records in one operation
    :file.pwrite(file, start_offset, all_records_binary)
  end

  defp batch_process_updates(dbf, fields, updates) do
    batch_process_updates_recursive(dbf, fields, updates, [])
  end

  defp batch_process_updates_recursive(_dbf, _fields, [], acc) do
    {:ok, Enum.reverse(acc)}
  end

  defp batch_process_updates_recursive(dbf, fields, [{index, update_data} | rest], acc) do
    # Read current record to merge with update
    case read_record(dbf, index) do
      {:ok, current_record} ->
        # Merge update data with existing record data
        merged_data = Map.merge(current_record.data, update_data)
        
        # Encode the merged record
        case encode_text_fields(fields, merged_data, encoding(dbf))
             |> then(fn
               {:ok, merged_data} -> encode_record(fields, merged_data)
               error -> error
             end) do
          {:ok, encoded_record} ->
            # Calculate offset for this record
            offset = calculate_record_offset(dbf.header, index)
            
            # Add to accumulator as {offset, encoded_data}
            update_entry = {offset, encoded_record}
            batch_process_updates_recursive(dbf, fields, rest, [update_entry | acc])
          {:error, reason} ->
            {:error, reason}
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp batch_write_record_updates(file, encoded_updates) do
    batch_write_record_updates_recursive(file, encoded_updates)
  end

  defp batch_write_record_updates_recursive(_file, []) do
    :ok
  end

  defp batch_write_record_updates_recursive(file, [{offset, data} | rest]) do
    case :file.pwrite(file, offset, data) do
      :ok ->
        batch_write_record_updates_recursive(file, rest)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_indices(%{header: header}, indices) do
    invalid_indices = Enum.filter(indices, fn index ->
      index < 0 or index >= header.record_count
    end)
    
    if Enum.empty?(invalid_indices) do
      :ok
    else
      {:error, :invalid_record_index}
    end
  end

  defp batch_delete_by_indices(dbf, []) do
    {:ok, dbf}
  end

  defp batch_delete_by_indices(%{header: header, file: file} = dbf, indices) do
    # Process deletions efficiently by batching file writes
    case batch_write_deletion_flags(file, header, indices) do
      :ok ->
        # Update header timestamp and increment transaction flag for conflict detection
        updated_header = header
        |> update_header_timestamp()
        |> increment_transaction_flag()
        case write_header(file, updated_header) do
          :ok ->
            {:ok, %{dbf | header: updated_header}}
          {:error, reason} ->
            {:error, reason}
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp batch_write_deletion_flags(file, header, indices) do
    deletion_flag = <<0x2A>>  # Deleted record flag
    
    # Create list of {offset, data} tuples for batch writing
    write_operations = Enum.map(indices, fn index ->
      offset = calculate_record_offset(header, index)
      {offset, deletion_flag}
    end)
    
    # Execute all writes
    batch_write_operations(file, write_operations)
  end

  defp batch_write_operations(_file, []) do
    :ok
  end

  defp batch_write_operations(file, [{offset, data} | rest]) do
    case :file.pwrite(file, offset, data) do
      :ok ->
        batch_write_operations(file, rest)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_matching_indices(dbf, total_records, condition_fn) do
    find_matching_indices_recursive(dbf, 0, total_records, condition_fn, [])
  end

  defp find_matching_indices_recursive(_dbf, index, max, _condition_fn, acc) when index >= max do
    {:ok, Enum.reverse(acc)}
  end

  defp find_matching_indices_recursive(dbf, index, max, condition_fn, acc) do
    case read_record(dbf, index) do
      {:ok, record} ->
        # Only check condition for non-deleted records
        if not record.deleted and condition_fn.(record.data) do
          find_matching_indices_recursive(dbf, index + 1, max, condition_fn, [index | acc])
        else
          find_matching_indices_recursive(dbf, index + 1, max, condition_fn, acc)
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp count_records_by_status(dbf, total_records, target_deleted_status) do
    count_records_by_status_recursive(dbf, 0, total_records, target_deleted_status, 0)
  end

  defp count_records_by_status_recursive(_dbf, index, max, _target_deleted_status, acc) when index >= max do
    {:ok, acc}
  end

  defp count_records_by_status_recursive(dbf, index, max, target_deleted_status, acc) do
    case read_record(dbf, index) do
      {:ok, record} ->
        new_acc = if record.deleted == target_deleted_status, do: acc + 1, else: acc
        count_records_by_status_recursive(dbf, index + 1, max, target_deleted_status, new_acc)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_file_path(%{file_path: path}) do
    path
  end

  defp create_backup(source_path, backup_path) do
    case File.cp(source_path, backup_path) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_backup(backup_path) do
    File.rm(backup_path)
    :ok
  end

  defp restore_from_backup(original_path, backup_path) do
    case File.cp(backup_path, original_path) do
      :ok -> 
        File.rm(backup_path)
        :ok
      {:error, reason} -> 
        {:error, reason}
    end
  end

  @doc """
  Validates header consistency after write operations.
  
  ## Parameters
  - `dbf` - DBF file structure
  
  ## Returns
  - `:ok` - Header is consistent
  - `{:error, reason}` - Header inconsistency detected
  """
  def validate_header_consistency(%{header: header, fields: fields, file: file} = _dbf) do
    # Calculate expected header values
    field_count = length(fields)
    # Visual FoxPro tables carry a 263-byte database container backlink after
    # the field terminator.
    vfp_backlink = if header.version in [0x30, 0x31, 0x32], do: 263, else: 0
    expected_header_length = 32 + (field_count * 32) + 1 + vfp_backlink
    expected_record_length = 1 + Enum.sum(Enum.map(fields, & &1.length))

    # Verify header calculations match
    cond do
      header.header_length != expected_header_length ->
        {:error, {:header_length_mismatch, expected_header_length, header.header_length}}
        
      header.record_length != expected_record_length ->
        {:error, {:record_length_mismatch, expected_record_length, header.record_length}}
        
      true ->
        # Verify file size matches expected size based on header
        case :file.position(file, :eof) do
          {:ok, file_size} ->
            expected_size = header.header_length + (header.record_count * header.record_length) + 1  # +1 for EOF marker
            
            if file_size == expected_size or file_size == expected_size - 1 do  # Allow missing EOF marker
              :ok
            else
              {:error, {:file_size_mismatch, expected: expected_size, actual: file_size}}
            end
            
          {:error, reason} ->
            {:error, {:file_position_error, reason}}
        end
    end
  end

  # Enhanced write_header with validation
  defp write_header_with_validation(file, header, fields) do
    case write_header(file, header) do
      :ok ->
        # Validate the header after writing
        case validate_header_consistency(%{header: header, fields: fields, file: file}) do
          :ok -> :ok
          {:error, reason} -> {:error, {:header_validation_failed, reason}}
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  # Write EOF marker (0x1A) at the end of the file
  defp write_eof_marker(file, header) do
    # Calculate where EOF marker should be
    eof_position = header.header_length + (header.record_count * header.record_length)
    
    case :file.pwrite(file, eof_position, <<0x1A>>) do
      :ok -> :ok
      {:error, reason} -> {:error, {:eof_marker_write_failed, reason}}
    end
  end

  @doc """
  Ensures header consistency for all write operations.
  Call this after any operation that modifies the DBF structure.
  
  ## Parameters
  - `dbf` - DBF file structure
  
  ## Returns
  - `{:ok, dbf}` - Header is consistent
  - `{:error, reason}` - Header inconsistency detected
  """
  def ensure_header_consistency(%{header: header, fields: _fields, file: file} = dbf) do
    case validate_header_consistency(dbf) do
      :ok -> 
        # Also ensure EOF marker is present
        case write_eof_marker(file, header) do
          :ok -> {:ok, dbf}
          {:error, reason} -> {:error, reason}
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Creates a lazy stream of records from the DBF file.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  
  ## Returns
  - `Stream.t()` - Stream of record data maps (excludes deleted records)
  
  ## Examples
      iex> {:ok, dbf} = Xbase.Parser.open_dbf("data.dbf")
      iex> stream = Xbase.Parser.stream_records(dbf)
      iex> stream |> Enum.take(10) |> length()
      10
  """
  def stream_records(%{header: header} = dbf) do
    Stream.resource(
      fn -> 0 end,
      fn index ->
        if index >= header.record_count do
          {:halt, index}
        else
          case read_record(dbf, index) do
            {:ok, record} ->
              if record.deleted do
                # Skip deleted records, continue with next index
                {[], index + 1}
              else
                # Return record data and next index
                {[record.data], index + 1}
              end
            {:error, _reason} ->
              # Stop on error
              {:halt, index}
          end
        end
      end,
      fn _index -> :ok end
    )
  end

  @doc """
  Creates a filtered stream of records from the DBF file.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  - `filter_fn` - Function that takes record data and returns true/false
  
  ## Returns
  - `Stream.t()` - Stream of filtered record data maps
  
  ## Examples
      iex> {:ok, dbf} = Xbase.Parser.open_dbf("data.dbf")
      iex> high_scores = fn record -> record["SCORE"] > 90 end
      iex> stream = Xbase.Parser.stream_where(dbf, high_scores)
      iex> Enum.to_list(stream)
      [%{"SCORE" => 95, ...}, ...]
  """
  def stream_where(dbf, filter_fn) when is_function(filter_fn, 1) do
    dbf
    |> stream_records()
    |> Stream.filter(filter_fn)
  end

  @doc """
  Reads records in chunks of specified size.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  - `chunk_size` - Number of records per chunk
  
  ## Returns
  - `Stream.t()` - Stream of record lists (chunks)
  
  ## Examples
      iex> {:ok, dbf} = Xbase.Parser.open_dbf("data.dbf")
      iex> chunks = Xbase.Parser.read_in_chunks(dbf, 100)
      iex> Enum.each(chunks, fn chunk -> process_chunk(chunk) end)
      :ok
  """
  def read_in_chunks(dbf, chunk_size) when is_integer(chunk_size) and chunk_size > 0 do
    dbf
    |> stream_records()
    |> Stream.chunk_every(chunk_size)
  end

  @doc """
  Reads records in chunks with progress reporting.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  - `chunk_size` - Number of records per chunk
  - `progress_fn` - Function called with progress info: `fn %{current: int, total: int, percentage: float} -> any end`
  
  ## Returns
  - `Stream.t()` - Stream of record lists (chunks) with progress reporting
  
  ## Examples
      progress_fn = fn prog -> IO.puts("Progress: " <> to_string(prog.percentage) <> "%") end
      chunks = Xbase.Parser.read_in_chunks_with_progress(dbf, 100, progress_fn)
      Enum.each(chunks, fn chunk -> process_chunk(chunk) end)
  """
  def read_in_chunks_with_progress(%{header: header} = dbf, chunk_size, progress_fn) 
      when is_integer(chunk_size) and chunk_size > 0 and is_function(progress_fn, 1) do
    
    total_records = header.record_count
    
    dbf
    |> stream_records()
    |> Stream.chunk_every(chunk_size)
    |> Stream.with_index()
    |> Stream.map(fn {chunk, chunk_index} ->
      # Calculate progress
      records_processed = (chunk_index + 1) * chunk_size
      # Don't exceed total for last chunk
      actual_processed = min(records_processed, total_records)
      
      progress = %{
        current: actual_processed,
        total: total_records,
        percentage: Float.round(actual_processed / total_records * 100, 1)
      }
      
      # Report progress
      progress_fn.(progress)
      
      # Return the chunk
      chunk
    end)
  end

  @doc """
  Creates a stream with progress reporting.
  
  ## Parameters
  - `dbf` - DBF file structure from open_dbf/1
  - `progress_fn` - Function called with progress info
  
  ## Returns
  - `Stream.t()` - Stream of records with progress reporting
  
  ## Examples
      progress_fn = fn prog -> send(self(), {:progress, prog}) end
      records = Xbase.Parser.stream_records_with_progress(dbf, progress_fn) |> Enum.to_list()
  """
  def stream_records_with_progress(%{header: header} = dbf, progress_fn) 
      when is_function(progress_fn, 1) do
    
    total_records = header.record_count
    
    dbf
    |> stream_records()
    |> Stream.with_index()
    |> Stream.map(fn {record, index} ->
      # Calculate progress (index is 0-based)
      records_processed = index + 1
      
      progress = %{
        current: records_processed,
        total: total_records,
        percentage: Float.round(records_processed / total_records * 100, 1)
      }
      
      # Report progress occasionally (every 10% or on last record)
      if rem(records_processed, max(1, div(total_records, 10))) == 0 or records_processed == total_records do
        progress_fn.(progress)
      end
      
      # Return the record
      record
    end)
  end

  @doc """
  Returns current memory usage statistics.
  
  ## Returns
  - `%{total: integer, processes: integer, system: integer}` - Memory usage in bytes
  
  ## Examples
      memory = Xbase.Parser.memory_usage()
      # => %{total: 52428800, processes: 12345, system: 9876, ...}
  """
  def memory_usage do
    memory_info = :erlang.memory()
    
    %{
      total: Keyword.get(memory_info, :total, 0),
      processes: Keyword.get(memory_info, :processes, 0),
      system: Keyword.get(memory_info, :system, 0),
      atom: Keyword.get(memory_info, :atom, 0),
      binary: Keyword.get(memory_info, :binary, 0),
      ets: Keyword.get(memory_info, :ets, 0)
    }
  end

end