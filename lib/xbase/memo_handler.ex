defmodule Xbase.MemoHandler do
  @moduledoc """
  Handles coordinated operations between DBF and DBT files for memo field support.
  
  Provides high-level API for seamless memo content handling in record operations,
  automatic file discovery, and transaction safety across both file types.
  """

  alias Xbase.Parser
  alias Xbase.DbtParser
  alias Xbase.DbtWriter
  alias Xbase.Types.DbtFile
  alias Xbase.CodePage
  alias Xbase.FptParser
  alias Xbase.Types.FptFile

  defstruct [:dbf, :dbt, :dbf_path, :dbt_path, :memo_mode]

  @type t :: %__MODULE__{
    dbf: map(),
    dbt: DbtFile.t() | nil,
    dbf_path: String.t(),
    dbt_path: String.t() | nil,
    memo_mode: :auto | :required | :disabled
  }

  @doc """
  Opens a DBF file with automatic memo file discovery and coordination.
  
  ## Parameters
  - `dbf_path` - Path to the DBF file
  - `modes` - File access modes (default: [:read])
  - `opts` - Options for memo handling
    - `:memo` - Memo mode (:auto, :required, :disabled)
    - `:dbt_path` - Explicit DBT file path (overrides auto-discovery)
  
  ## Returns
  - `{:ok, MemoHandler.t()}` - Successfully opened coordinated files
  - `{:error, reason}` - Error opening files
  
  ## Examples
      # Automatic memo file discovery
      {:ok, handler} = MemoHandler.open_dbf_with_memo("data.dbf")
      
      # Read-write mode with required memo support
      {:ok, handler} = MemoHandler.open_dbf_with_memo("data.dbf", [:read, :write], memo: :required)
      
      # Explicit DBT file path
      {:ok, handler} = MemoHandler.open_dbf_with_memo("data.dbf", [], dbt_path: "memos.dbt")
  """
  def open_dbf_with_memo(dbf_path, modes \\ [:read], opts \\ []) do
    memo_mode = Keyword.get(opts, :memo, :auto)
    explicit_dbt_path = Keyword.get(opts, :dbt_path)
    
    # Open DBF file first
    case Parser.open_dbf(dbf_path, modes) do
      {:ok, dbf} ->
        # Check if DBF supports memo fields
        if has_memo_support?(dbf) do
          dbt_path = explicit_dbt_path || discover_dbt_path(dbf_path)
          open_memo_file(dbf, dbf_path, dbt_path, modes, memo_mode)
        else
          case memo_mode do
            :required ->
              Parser.close_dbf(dbf)
              {:error, :dbf_no_memo_support}
            _ ->
              # DBF without memo support, return handler without DBT
              {:ok, %__MODULE__{
                dbf: dbf,
                dbt: nil,
                dbf_path: dbf_path,
                dbt_path: nil,
                memo_mode: :disabled
              }}
          end
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Creates a new DBF file with memo support and coordinated DBT file.
  
  ## Parameters
  - `dbf_path` - Path for the new DBF file
  - `fields` - Field definitions for the DBF file
  - `opts` - Options for file creation
    - `:version` - DBF version (automatically set to memo-capable if memo fields present)
    - `:dbt_path` - Explicit DBT file path (defaults to replacing .dbf with .dbt)
    - `:block_size` - DBT block size (default: 512)
  
  ## Returns
  - `{:ok, MemoHandler.t()}` - Successfully created coordinated files
  - `{:error, reason}` - Error creating files
  """
  def create_dbf_with_memo(dbf_path, fields, opts \\ []) do
    has_memo_fields = Enum.any?(fields, fn field -> field.type == "M" end)
    
    if has_memo_fields do
      # Force memo-capable version
      version = Keyword.get(opts, :version, 0x8B)  # dBase IV with memo
      dbt_path = Keyword.get(opts, :dbt_path, replace_extension(dbf_path, ".dbt"))
      block_size = Keyword.get(opts, :block_size, 512)
      
      # Create DBF file first
      case Parser.create_dbf(dbf_path, fields, Keyword.put(opts, :version, version)) do
        {:ok, dbf} ->
          # Create coordinated DBT file
          case DbtWriter.create_dbt(dbt_path, version: :dbase_iii, block_size: block_size) do
            {:ok, dbt} ->
              {:ok, %__MODULE__{
                dbf: dbf,
                dbt: dbt,
                dbf_path: dbf_path,
                dbt_path: dbt_path,
                memo_mode: :auto
              }}
            {:error, reason} ->
              Parser.close_dbf(dbf)
              File.rm(dbf_path)  # Clean up DBF file
              {:error, {:dbt_creation_failed, reason}}
          end
        {:error, reason} ->
          {:error, reason}
      end
    else
      # No memo fields, create regular DBF file
      case Parser.create_dbf(dbf_path, fields, opts) do
        {:ok, dbf} ->
          {:ok, %__MODULE__{
            dbf: dbf,
            dbt: nil,
            dbf_path: dbf_path,
            dbt_path: nil,
            memo_mode: :disabled
          }}
        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Appends a record with automatic memo content handling.
  
  ## Parameters
  - `handler` - MemoHandler structure
  - `record_data` - Map of field names to values, where memo fields contain content strings
  
  ## Returns
  - `{:ok, updated_handler}` - Successfully appended record with memo content
  - `{:error, reason}` - Error appending record
  
  ## Example
      record_data = %{
        "NAME" => "John Doe",
        "NOTES" => "This memo content will be automatically stored in the DBT file"
      }
      {:ok, updated_handler} = MemoHandler.append_record_with_memo(handler, record_data)
  """
  def append_record_with_memo(%__MODULE__{memo_mode: :disabled} = handler, record_data) do
    # No memo support, use regular record append
    case Parser.append_record(handler.dbf, record_data) do
      {:ok, updated_dbf} ->
        {:ok, %{handler | dbf: updated_dbf}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  def append_record_with_memo(%__MODULE__{} = handler, record_data) do
    # Process memo fields and convert content to references
    case process_memo_fields(handler, record_data) do
      {:ok, {processed_data, updated_handler}} ->
        # Append record with memo references
        case Parser.append_record(updated_handler.dbf, processed_data) do
          {:ok, updated_dbf} ->
            {:ok, %{updated_handler | dbf: updated_dbf}}
          {:error, reason} ->
            {:error, reason}
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Updates a record with automatic memo content handling.
  
  ## Parameters
  - `handler` - MemoHandler structure
  - `record_index` - Zero-based record index to update
  - `record_data` - Map of field names to values for update
  
  ## Returns
  - `{:ok, updated_handler}` - Successfully updated record with memo content
  - `{:error, reason}` - Error updating record
  """
  def update_record_with_memo(%__MODULE__{memo_mode: :disabled} = handler, record_index, record_data) do
    # No memo support, use regular record update
    case Parser.update_record(handler.dbf, record_index, record_data) do
      {:ok, updated_dbf} ->
        {:ok, %{handler | dbf: updated_dbf}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  def update_record_with_memo(%__MODULE__{} = handler, record_index, record_data) do
    # For updates, we need to handle memo field updates carefully
    # Read existing record to preserve non-updated memo references
    case Parser.read_record(handler.dbf, record_index) do
      {:ok, existing_record} ->
        # Extract data from Record struct
        existing_data = existing_record.data
        
        # Merge update data with existing record
        _merged_data = Map.merge(existing_data, record_data)
        
        # Process memo fields in the merged data
        case process_memo_fields_for_update(handler, existing_data, record_data) do
          {:ok, {processed_data, updated_handler}} ->
            # Update record with processed memo references
            case Parser.update_record(updated_handler.dbf, record_index, processed_data) do
              {:ok, updated_dbf} ->
                {:ok, %{updated_handler | dbf: updated_dbf}}
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
  Reads a record with automatic memo content resolution.
  
  ## Parameters
  - `handler` - MemoHandler structure
  - `record_index` - Zero-based record index to read
  
  ## Returns
  - `{:ok, record_data}` - Record data with memo content resolved
  - `{:error, reason}` - Error reading record
  """
  def read_record_with_memo(%__MODULE__{} = handler, record_index) do
    case Parser.read_record(handler.dbf, record_index) do
      {:ok, record_struct} ->
        # Extract data from Record struct and resolve memo content
        resolve_memo_content(handler, record_struct.data)
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Closes both DBF and DBT files properly.
  
  ## Parameters
  - `handler` - MemoHandler structure
  
  ## Returns
  - `:ok` - Files closed successfully
  """
  def close_memo_files(%__MODULE__{} = handler) do
    # Close DBF file
    Parser.close_dbf(handler.dbf)
    
    # Close the memo file if present
    case handler.dbt do
      nil -> :ok
      %FptFile{} = fpt -> FptParser.close_fpt(fpt)
      dbt -> DbtWriter.close_dbt(dbt)
    end
    
    :ok
  end

  @doc """
  Executes a function with transaction safety across both DBF and DBT files.
  
  ## Parameters
  - `handler` - MemoHandler structure
  - `transaction_fn` - Function to execute with the handler
  
  ## Returns
  - `{:ok, {result, updated_handler}}` - Transaction successful
  - `{:error, reason}` - Transaction failed, changes rolled back
  """
  def memo_transaction(%__MODULE__{} = handler, transaction_fn) do
    # Create backups of both files
    dbf_backup = handler.dbf_path <> ".bak"
    dbt_backup = if handler.dbt_path, do: handler.dbt_path <> ".bak", else: nil
    
    try do
      # Backup DBF file
      File.cp!(handler.dbf_path, dbf_backup)
      
      # Backup DBT file if it exists
      if dbt_backup && File.exists?(handler.dbt_path) do
        File.cp!(handler.dbt_path, dbt_backup)
      end
      
      # Execute transaction
      case transaction_fn.(handler) do
        {:ok, result, updated_handler} ->
          # Transaction succeeded, clean up backups
          File.rm(dbf_backup)
          if dbt_backup, do: File.rm(dbt_backup)
          {:ok, {result, updated_handler}}
        {:error, reason} ->
          # Transaction failed, restore from backups
          restore_from_backup(handler, dbf_backup, dbt_backup)
          {:error, reason}
      end
    rescue
      e ->
        # Exception occurred, restore from backups
        restore_from_backup(handler, dbf_backup, dbt_backup)
        {:error, {:exception, e}}
    end
  end

  # Private helper functions

  defp has_memo_support?(%{header: header}) do
    # dBase/FoxPro versions with memo, or a Visual FoxPro table whose table
    # flags byte (parsed as mdx_flag) has the "has memo" bit 0x02 set.
    header.version in [0x83, 0x8B, 0xF5] or
      (header.version in [0x30, 0x31, 0x32] and Bitwise.band(header.mdx_flag || 0, 0x02) != 0)
  end

  defp discover_dbt_path(dbf_path) do
    # Visual FoxPro memo files use the .fpt extension; prefer one that exists.
    Enum.find(
      [replace_extension(dbf_path, ".fpt"), replace_extension(dbf_path, ".FPT")],
      replace_extension(dbf_path, ".dbt"),
      &File.exists?/1
    )
  end

  defp fpt_path?(path), do: String.downcase(Path.extname(path)) == ".fpt"

  defp replace_extension(path, new_ext) do
    Path.rootname(path) <> new_ext
  end

  defp open_memo_file(dbf, dbf_path, dbt_path, modes, memo_mode) do
    write_mode = :write in modes

    cond do
      fpt_path?(dbt_path) and write_mode ->
        Parser.close_dbf(dbf)
        {:error, :fpt_write_not_supported}

      fpt_path?(dbt_path) ->
        case FptParser.open_fpt(dbt_path) do
          {:ok, fpt} ->
            {:ok, %__MODULE__{
              dbf: dbf,
              dbt: fpt,
              dbf_path: dbf_path,
              dbt_path: dbt_path,
              memo_mode: memo_mode
            }}

          {:error, reason} ->
            Parser.close_dbf(dbf)
            {:error, {:dbt_open_failed, reason}}
        end

      true ->
        open_dbt_memo_file(dbf, dbf_path, dbt_path, write_mode, memo_mode)
    end
  end

  defp open_dbt_memo_file(dbf, dbf_path, dbt_path, write_mode, memo_mode) do
    case File.exists?(dbt_path) do
      true ->
        # DBT file exists, open it
        open_function = if write_mode, do: &DbtWriter.open_dbt_for_writing/1, else: &DbtParser.open_dbt/1
        case open_function.(dbt_path) do
          {:ok, dbt} ->
            {:ok, %__MODULE__{
              dbf: dbf,
              dbt: dbt,
              dbf_path: dbf_path,
              dbt_path: dbt_path,
              memo_mode: memo_mode
            }}
          {:error, reason} ->
            Parser.close_dbf(dbf)
            {:error, {:dbt_open_failed, reason}}
        end
      false ->
        case memo_mode do
          :required ->
            Parser.close_dbf(dbf)
            {:error, :dbt_file_required}
          :auto when write_mode ->
            # Create new DBT file for writing
            case DbtWriter.create_dbt(dbt_path) do
              {:ok, dbt} ->
                {:ok, %__MODULE__{
                  dbf: dbf,
                  dbt: dbt,
                  dbf_path: dbf_path,
                  dbt_path: dbt_path,
                  memo_mode: memo_mode
                }}
              {:error, reason} ->
                Parser.close_dbf(dbf)
                {:error, {:dbt_creation_failed, reason}}
            end
          _ ->
            # Auto mode without write access, or disabled - no DBT file
            {:ok, %__MODULE__{
              dbf: dbf,
              dbt: nil,
              dbf_path: dbf_path,
              dbt_path: nil,
              memo_mode: memo_mode
            }}
        end
    end
  end

  defp process_memo_fields(%__MODULE__{dbt: nil}, record_data) do
    # No DBT file available, ensure no memo content is provided
    memo_fields = get_memo_fields_with_content(record_data)
    if Enum.empty?(memo_fields) do
      {:ok, {record_data, nil}}  # No handler update needed
    else
      {:error, {:memo_content_without_dbt, memo_fields}}
    end
  end

  defp process_memo_fields(%__MODULE__{} = handler, record_data) do
    # Process each memo field that contains string content
    memo_fields = get_memo_fields(handler.dbf)
    process_memo_fields_recursive(handler, record_data, memo_fields, %{})
  end

  defp process_memo_fields_recursive(handler, record_data, [], processed_data) do
    # All fields processed
    final_data = Map.merge(record_data, processed_data)
    {:ok, {final_data, handler}}
  end

  defp process_memo_fields_recursive(handler, record_data, [field_name | rest], processed_data) do
    case Map.get(record_data, field_name) do
      content when is_binary(content) ->
        # Write memo content and get block reference
        case encode_memo(handler, content)
             |> then(fn
               {:ok, stored} -> DbtWriter.write_memo(handler.dbt, stored)
               error -> error
             end) do
          {:ok, {block_number, updated_dbt}} ->
            updated_handler = %{handler | dbt: updated_dbt}
            updated_processed = Map.put(processed_data, field_name, {:memo_ref, block_number})
            process_memo_fields_recursive(updated_handler, record_data, rest, updated_processed)
          {:error, reason} ->
            {:error, {:memo_write_failed, field_name, reason}}
        end
      {:memo_ref, _block_number} = memo_ref ->
        # Already a memo reference, keep as-is
        updated_processed = Map.put(processed_data, field_name, memo_ref)
        process_memo_fields_recursive(handler, record_data, rest, updated_processed)
      nil ->
        # No value for this memo field, continue
        process_memo_fields_recursive(handler, record_data, rest, processed_data)
      other ->
        # Invalid value for memo field
        {:error, {:invalid_memo_value, field_name, other}}
    end
  end

  defp process_memo_fields_for_update(handler, existing_record, update_data) do
    # Only process memo fields that are being updated
    memo_fields = get_memo_fields(handler.dbf)
    updated_memo_fields = Enum.filter(memo_fields, fn field -> Map.has_key?(update_data, field) end)
    
    process_memo_update_fields_recursive(handler, existing_record, update_data, updated_memo_fields, %{})
  end

  defp process_memo_update_fields_recursive(handler, _existing_record, update_data, [], processed_data) do
    # All updated memo fields processed
    final_data = Map.merge(update_data, processed_data)
    {:ok, {final_data, handler}}
  end

  defp process_memo_update_fields_recursive(handler, existing_record, update_data, [field_name | rest], processed_data) do
    case Map.get(update_data, field_name) do
      content when is_binary(content) ->
        # Check if we can reuse existing block
        existing_ref = Map.get(existing_record, field_name)
        case encode_memo(handler, content)
             |> then(fn
               {:ok, stored} -> reuse_or_create_memo_block(handler, existing_ref, stored)
               error -> error
             end) do
          {:ok, {memo_ref, updated_handler}} ->
            updated_processed = Map.put(processed_data, field_name, memo_ref)
            process_memo_update_fields_recursive(updated_handler, existing_record, update_data, rest, updated_processed)
          {:error, reason} ->
            {:error, {:memo_update_failed, field_name, reason}}
        end
      {:memo_ref, _block_number} = memo_ref ->
        # New memo reference provided
        updated_processed = Map.put(processed_data, field_name, memo_ref)
        process_memo_update_fields_recursive(handler, existing_record, update_data, rest, updated_processed)
      other ->
        {:error, {:invalid_memo_update_value, field_name, other}}
    end
  end

  defp reuse_or_create_memo_block(handler, {:memo_ref, block_number}, content) do
    # Try to update existing block
    case DbtWriter.update_memo(handler.dbt, block_number, content) do
      {:ok, updated_dbt} ->
        {:ok, {{:memo_ref, block_number}, %{handler | dbt: updated_dbt}}}
      {:error, _reason} ->
        # Update failed, create new block
        create_new_memo_block(handler, content)
    end
  end

  defp reuse_or_create_memo_block(handler, _other, content) do
    # No existing reference, create new block
    create_new_memo_block(handler, content)
  end

  defp create_new_memo_block(handler, content) do
    case DbtWriter.write_memo(handler.dbt, content) do
      {:ok, {block_number, updated_dbt}} ->
        {:ok, {{:memo_ref, block_number}, %{handler | dbt: updated_dbt}}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_memo_content(%__MODULE__{dbt: nil}, record_data) do
    # No DBT file, return record as-is
    {:ok, record_data}
  end

  defp resolve_memo_content(%__MODULE__{} = handler, record_data) do
    memo_fields = get_memo_fields(handler.dbf)
    resolve_memo_content_recursive(handler, record_data, memo_fields, %{})
  end

  defp resolve_memo_content_recursive(_handler, record_data, [], resolved_data) do
    # All memo fields resolved
    final_data = Map.merge(record_data, resolved_data)
    {:ok, final_data}
  end

  defp resolve_memo_content_recursive(handler, record_data, [field_name | rest], resolved_data) do
    case Map.get(record_data, field_name) do
      {:memo_ref, block_number} when block_number > 0 ->
        # Resolve memo reference to content
        case read_memo(handler.dbt, block_number) do
          {:ok, content} ->
            content = CodePage.decode(content, memo_encoding(handler))
            updated_resolved = Map.put(resolved_data, field_name, content)
            resolve_memo_content_recursive(handler, record_data, rest, updated_resolved)
          {:error, reason} ->
            {:error, {:memo_read_failed, field_name, block_number, reason}}
        end
      {:memo_ref, 0} ->
        # Empty memo reference
        updated_resolved = Map.put(resolved_data, field_name, "")
        resolve_memo_content_recursive(handler, record_data, rest, updated_resolved)
      _other ->
        # Not a memo reference or already resolved
        resolve_memo_content_recursive(handler, record_data, rest, resolved_data)
    end
  end

  defp memo_encoding(%__MODULE__{dbf: dbf}), do: Map.get(dbf, :encoding, :raw)

  defp encode_memo(handler, content), do: CodePage.encode(content, memo_encoding(handler))

  defp read_memo(%FptFile{} = fpt, block_number), do: FptParser.read_memo(fpt, block_number)
  defp read_memo(dbt, block_number), do: DbtParser.read_memo(dbt, block_number)

  defp get_memo_fields(%{fields: fields}) do
    fields
    |> Enum.filter(fn field -> field.type == "M" end)
    |> Enum.map(fn field -> field.name end)
  end

  defp get_memo_fields_with_content(record_data) do
    record_data
    |> Enum.filter(fn {_key, value} -> is_binary(value) end)
    |> Enum.map(fn {key, _value} -> key end)
  end

  defp restore_from_backup(handler, dbf_backup, dbt_backup) do
    # Restore DBF file
    if File.exists?(dbf_backup) do
      File.cp!(dbf_backup, handler.dbf_path)
      File.rm(dbf_backup)
    end
    
    # Restore DBT file
    if dbt_backup && File.exists?(dbt_backup) do
      File.cp!(dbt_backup, handler.dbt_path)
      File.rm(dbt_backup)
    end
  end
end