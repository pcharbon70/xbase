defmodule Xbase.CdxParser do
  @moduledoc """
  Parser for CDX (compound index) files used in dBase for fast data access.
  
  CDX files implement a B-tree structure with 512-byte pages containing root,
  branch, and leaf nodes. The file begins with a header containing metadata
  about the index structure and key expressions.
  """

  alias Xbase.Types.{CdxHeader, CdxNode, CdxFile}

  @page_size 512

  @doc """
  Parses a CDX file header from binary data.
  
  ## Parameters
  - `header_binary` - 512 bytes of header data
  
  ## Returns
  - `{:ok, CdxHeader.t()}` - Successfully parsed header
  - `{:error, reason}` - Error parsing header
  """
  def parse_header(header_binary) when byte_size(header_binary) != @page_size do
    {:error, :invalid_header_size}
  end

  def parse_header(header_binary) do
    case header_binary do
      <<root_node::little-32, free_list::little-signed-32, version::little-32,
        key_length::little-16, index_options, signature,
        _reserved::16*8, sort_order::little-16, total_expr_len::little-16,
        for_expr_len::little-16, _reserved2::16, key_expr_len::little-16,
        rest::binary>> ->
        
        # Extract expressions from the remaining data
        expressions_binary = rest
        
        {key_expression, for_expression} = extract_expressions(
          expressions_binary, key_expr_len, for_expr_len
        )

        if key_length > 0 and key_length <= 240 do
          {:ok, %CdxHeader{
            root_node: root_node,
            free_list: free_list,
            version: version,
            key_length: key_length,
            index_options: index_options,
            signature: signature,
            sort_order: sort_order,
            total_expr_len: total_expr_len,
            for_expr_len: for_expr_len,
            key_expr_len: key_expr_len,
            key_expression: key_expression,
            for_expression: for_expression
          }}
        else
          {:error, :invalid_key_length}
        end
      _ ->
        {:error, :invalid_header_format}
    end
  end

  @doc """
  Opens a CDX file and parses its header.
  
  ## Parameters
  - `file_path` - Path to the CDX file
  
  ## Returns
  - `{:ok, CdxFile.t()}` - Successfully opened CDX file
  - `{:error, reason}` - Error opening or parsing file
  """
  def open_cdx(file_path) do
    case File.exists?(file_path) do
      false ->
        {:error, :file_not_found}
      true ->
        case :file.open(file_path, [:read, :binary, :random]) do
          {:ok, file} ->
            case :file.read(file, @page_size) do
              {:ok, header_binary} ->
                case parse_header(header_binary) do
                  {:ok, header} ->
                    # Create ETS table for page caching
                    cache_table = :ets.new(:cdx_page_cache, [:set, :private])
                    
                    cdx_file = %CdxFile{
                      header: header,
                      file: file,
                      file_path: file_path,
                      page_cache: cache_table
                    }
                    {:ok, cdx_file}
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
  end

  @doc """
  Reads a B-tree node from a specific page number.
  
  ## Parameters
  - `cdx_file` - CdxFile structure from open_cdx/1
  - `page_number` - Page number to read (0-based)
  
  ## Returns
  - `{:ok, CdxNode.t()}` - Successfully read node
  - `{:error, reason}` - Error reading node
  """
  def read_node(%CdxFile{file: file, page_cache: cache, header: header} = _cdx_file, page_number) do
    # Check cache first
    case :ets.lookup(cache, page_number) do
      [{^page_number, cached_node}] ->
        {:ok, cached_node}
      [] ->
        # Read from file
        offset = page_number * @page_size
        case :file.pread(file, offset, @page_size) do
          {:ok, page_data} ->
            case parse_node(page_data, header.key_length) do
              {:ok, node} ->
                # Cache the node
                :ets.insert(cache, {page_number, node})
                {:ok, node}
              {:error, reason} ->
                {:error, reason}
            end
          :eof ->
            {:error, :invalid_page_number}
          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Parses a CDX B-tree node from binary page data.
  
  ## Parameters
  - `page_data` - 512 bytes of page data
  - `key_length` - Length of keys in this index
  
  ## Returns
  - `{:ok, CdxNode.t()}` - Successfully parsed node
  - `{:error, reason}` - Error parsing node
  """
  def parse_node(page_data, key_length \\ 10)
  
  def parse_node(page_data, _key_length) when byte_size(page_data) != @page_size do
    {:error, :invalid_page_size}
  end

  def parse_node(page_data, key_length) do
    case page_data do
      <<attributes::little-16, key_count::little-16, left_brother::little-signed-32,
        _reserved::binary-size(16), keys_and_pointers::binary>> ->
        
        node_type = determine_node_type(attributes)
        
        case extract_keys_and_pointers(keys_and_pointers, key_count, node_type, key_length) do
          {:ok, {keys, pointers}} ->
            {:ok, %CdxNode{
              attributes: attributes,
              key_count: key_count,
              left_brother: left_brother,
              keys: keys,
              pointers: pointers,
              node_type: node_type
            }}
          {:error, reason} ->
            {:error, reason}
        end
      _ ->
        {:error, :invalid_node_format}
    end
  end

  @doc """
  Searches for a key in the B-tree starting from the root node.
  
  ## Parameters
  - `cdx_file` - CdxFile structure
  - `search_key` - Key to search for
  
  ## Returns
  - `{:ok, record_number}` - Found key, returns record number
  - `{:error, :not_found}` - Key not found
  - `{:error, reason}` - Error during search
  """
  def search_key(%CdxFile{header: header} = cdx_file, search_key) do
    search_recursive(cdx_file, header.root_node, search_key)
  end

  @doc """
  Closes a CDX file handle and cleans up resources.
  
  ## Parameters
  - `cdx_file` - CdxFile structure from open_cdx/1
  
  ## Returns
  - `:ok` - File closed successfully
  """
  def close_cdx(%CdxFile{file: file, page_cache: cache}) do
    :ets.delete(cache)
    :file.close(file)
  end

  # Private helper functions

  defp extract_expressions(expressions_binary, key_expr_len, for_expr_len) do
    if byte_size(expressions_binary) >= key_expr_len do
      key_expression = binary_part(expressions_binary, 0, key_expr_len)
      |> String.trim_trailing(<<0>>)
      
      for_expression = if for_expr_len > 0 and byte_size(expressions_binary) >= key_expr_len + for_expr_len do
        binary_part(expressions_binary, key_expr_len, for_expr_len)
        |> String.trim_trailing(<<0>>)
      else
        nil
      end
      
      {key_expression, for_expression}
    else
      {"", nil}
    end
  end

  defp determine_node_type(attributes) do
    import Bitwise
    cond do
      # Check for root + leaf combination first (root node that is also a leaf)
      (attributes &&& 0x0003) == 0x0003 -> :leaf  # Root leaf nodes behave as leaf nodes
      (attributes &&& 0x0001) != 0 -> :root
      (attributes &&& 0x0002) != 0 -> :leaf
      true -> :branch
    end
  end

  defp extract_keys_and_pointers(data, key_count, node_type, key_length) do
    try do
      {keys, pointers} = parse_keys_and_pointers(data, key_count, node_type, key_length, [], [])
      {:ok, {keys, pointers}}
    catch
      {:error, reason} -> {:error, reason}
      :error, reason -> {:error, reason}
    end
  end

  defp parse_keys_and_pointers(_data, 0, _node_type, _key_length, keys, pointers) do
    {Enum.reverse(keys), Enum.reverse(pointers)}
  end

  defp parse_keys_and_pointers(data, remaining_keys, node_type, key_length, keys, pointers) when remaining_keys > 0 do
    case node_type do
      :leaf ->
        # Leaf nodes: key_length + record_number(4 bytes)
        if byte_size(data) >= key_length + 4 do
          <<key_data::binary-size(^key_length), record_num::little-32, rest::binary>> = data
          parse_keys_and_pointers(rest, remaining_keys - 1, node_type, key_length,
                                 [key_data | keys], [record_num | pointers])
        else
          throw({:error, :insufficient_data})
        end
      :root ->
        # Root nodes can be leaf or branch - check if it's a leaf root
        if byte_size(data) >= key_length + 4 do
          <<key_data::binary-size(^key_length), ptr::little-32, rest::binary>> = data
          parse_keys_and_pointers(rest, remaining_keys - 1, node_type, key_length,
                                 [key_data | keys], [ptr | pointers])
        else
          throw({:error, :insufficient_data})
        end
      _ ->
        # Branch nodes: key_length + child_pointer(4 bytes)
        if byte_size(data) >= key_length + 4 do
          <<key_data::binary-size(^key_length), child_ptr::little-32, rest::binary>> = data
          parse_keys_and_pointers(rest, remaining_keys - 1, node_type, key_length,
                                 [key_data | keys], [child_ptr | pointers])
        else
          throw({:error, :insufficient_data})
        end
    end
  end

  defp search_recursive(cdx_file, node_page, search_key) do
    case read_node(cdx_file, node_page) do
      {:ok, node} ->
        case node.node_type do
          :leaf ->
            # Search in leaf node
            find_key_in_leaf(node, search_key)
          _ ->
            # Search in branch/root node
            case find_child_pointer(node, search_key) do
              {:ok, child_page} ->
                search_recursive(cdx_file, child_page, search_key)
              {:error, reason} ->
                {:error, reason}
            end
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_key_in_leaf(node, search_key) do
    # Simple linear search for now - could be optimized with binary search
    keys_with_pointers = Enum.zip(node.keys, node.pointers)
    
    case Enum.find(keys_with_pointers, fn {key, _ptr} -> 
      String.trim_trailing(key, <<0>>) == search_key 
    end) do
      {_key, record_number} -> {:ok, record_number}
      nil -> {:error, :not_found}
    end
  end

  defp find_child_pointer(node, _search_key) do
    # Find appropriate child pointer based on key comparison
    # This is a simplified implementation
    keys_with_pointers = Enum.zip(node.keys, node.pointers)
    
    # For now, return first child pointer - should implement proper B-tree search
    case keys_with_pointers do
      [{_key, pointer} | _] -> {:ok, pointer}
      [] -> {:error, :empty_node}
    end
  end
end