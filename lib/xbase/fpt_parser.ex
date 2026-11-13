defmodule Xbase.FptParser do
  @moduledoc """
  Read-only parser for Visual FoxPro FPT memo files.

  An FPT file starts with a 512-byte header holding the next free block number
  and the block size, both big-endian. Each memo starts at
  `block_number * block_size` with an 8-byte block header
  `<<type::32-big, length::32-big>>` followed by `length` bytes of data.
  Type 1 is text; type 0 is picture or binary data (general fields).
  """

  alias Xbase.Types.FptFile

  @header_size 512

  @doc """
  Opens an FPT file for reading and parses its header.

  ## Returns
  - `{:ok, %FptFile{}}` - File opened and header parsed
  - `{:error, reason}` - File missing, unreadable or with an invalid header
  """
  def open_fpt(file_path) do
    with {:ok, file} <- :file.open(file_path, [:read, :binary, :random]) do
      case read_header(file) do
        {:ok, next_block, block_size} ->
          {:ok,
           %FptFile{
             file: file,
             file_path: file_path,
             next_block: next_block,
             block_size: block_size
           }}

        {:error, reason} ->
          :file.close(file)
          {:error, reason}
      end
    end
  end

  @doc """
  Reads the memo stored at `block_number`.

  ## Returns
  - `{:ok, binary}` - The memo data (text memos are returned as stored, in the
    table's code page)
  - `{:error, reason}` - Invalid block number or unreadable block
  """
  def read_memo(%FptFile{} = fpt, block_number) when block_number > 0 do
    offset = block_number * fpt.block_size

    with {:ok, <<_type::big-32, length::big-32>>} <- :file.pread(fpt.file, offset, 8),
         {:ok, data} <- read_data(fpt.file, offset + 8, length) do
      {:ok, data}
    else
      :eof -> {:error, :block_beyond_file_end}
      {:ok, _short} -> {:error, :block_beyond_file_end}
      {:error, reason} -> {:error, reason}
    end
  end

  def read_memo(%FptFile{}, _block_number), do: {:error, :invalid_block_number}

  @doc "Closes an FPT file handle."
  def close_fpt(%FptFile{file: file}), do: :file.close(file)

  defp read_header(file) do
    case :file.pread(file, 0, @header_size) do
      {:ok, <<next_block::big-32, _unused::16, block_size::big-16, _rest::binary>>}
      when block_size > 0 ->
        {:ok, next_block, block_size}

      {:ok, _} ->
        {:error, :invalid_fpt_header}

      :eof ->
        {:error, :invalid_fpt_header}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_data(_file, _offset, 0), do: {:ok, ""}

  defp read_data(file, offset, length) do
    case :file.pread(file, offset, length) do
      {:ok, data} when byte_size(data) == length -> {:ok, data}
      {:ok, _short} -> {:error, :block_beyond_file_end}
      other -> other
    end
  end
end
