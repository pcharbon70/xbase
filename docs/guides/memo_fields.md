# Working with Memo Fields

Memo fields allow storing variable-length text content in dBase files. Unlike fixed-width character fields, memo fields can contain large amounts of text stored in a separate DBT (memo) file.

## Understanding Memo Fields

### What are Memo Fields?

Memo fields are designed for storing:
- Long text content (articles, descriptions, comments)
- Variable-length data that doesn't fit in fixed character fields
- Rich text or formatted content
- Any text content longer than 254 characters

### File Structure

When you use memo fields, two files are involved:
- **DBF file**: Contains the main records with memo field references
- **DBT file**: Contains the actual memo content in blocks

The DBF file stores memo references (block numbers) while the DBT file stores the actual content.

## Basic Memo Operations

### Creating Files with Memo Fields

```elixir
# Define fields including memo fields
fields = [
  %Xbase.Types.FieldDescriptor{name: "ID", type: "N", length: 10},
  %Xbase.Types.FieldDescriptor{name: "TITLE", type: "C", length: 50},
  %Xbase.Types.FieldDescriptor{name: "CONTENT", type: "M", length: 10},    # Memo field
  %Xbase.Types.FieldDescriptor{name: "NOTES", type: "M", length: 10}       # Another memo field
]

# Create coordinated DBF+DBT files
{:ok, handler} = Xbase.MemoHandler.create_dbf_with_memo("articles.dbf", fields)
```

### Adding Records with Memo Content

```elixir
# Add record with memo content
{:ok, handler} = Xbase.MemoHandler.append_record_with_memo(handler, %{
  "ID" => 1,
  "TITLE" => "Getting Started with Elixir",
  "CONTENT" => """
  Elixir is a dynamic, functional language designed for building maintainable and scalable applications.
  
  It leverages the Erlang Virtual Machine (BEAM), which gives it access to a battle-tested,
  distributed, and fault-tolerant system. This makes Elixir particularly well-suited for
  applications that require high availability and low latency.
  
  Key features of Elixir include:
  - Pattern matching
  - Actor model via lightweight processes
  - Fault tolerance through supervision trees
  - Functional programming paradigms
  - Immutable data structures
  """,
  "NOTES" => "This is an introductory article suitable for beginners."
})
```

### Reading Records with Memo Content

```elixir
# Read record with resolved memo content
{:ok, record} = Xbase.MemoHandler.read_record_with_memo(handler, 0)

IO.puts("Title: #{record["TITLE"]}")
IO.puts("Content: #{record["CONTENT"]}")
IO.puts("Notes: #{record["NOTES"]}")
```

### Updating Memo Content

```elixir
# Update memo content
{:ok, handler} = Xbase.MemoHandler.update_record_with_memo(handler, 0, %{
  "CONTENT" => """
  [UPDATED] Elixir is a dynamic, functional language designed for building 
  maintainable and scalable applications...
  """,
  "NOTES" => "Updated with additional examples and clarifications."
})
```

## Advanced Memo Operations

### Working with Large Memo Content

```elixir
# Reading large content from file
large_content = File.read!("large_document.txt")

{:ok, handler} = Xbase.MemoHandler.append_record_with_memo(handler, %{
  "ID" => 2,
  "TITLE" => "Large Document",
  "CONTENT" => large_content
})
```

### Batch Operations with Memos

```elixir
# Prepare multiple records with memo content
articles = [
  %{
    "ID" => 1,
    "TITLE" => "Article 1",
    "CONTENT" => "Content for article 1...",
    "NOTES" => "Notes for article 1"
  },
  %{
    "ID" => 2,
    "TITLE" => "Article 2", 
    "CONTENT" => "Content for article 2...",
    "NOTES" => "Notes for article 2"
  }
]

# Add them one by one (batch support would be a future enhancement)
final_handler = Enum.reduce(articles, handler, fn article, acc_handler ->
  {:ok, updated_handler} = Xbase.MemoHandler.append_record_with_memo(acc_handler, article)
  updated_handler
end)
```

### Mixed Memo References and Content

You can work with both memo content (strings) and memo references (tuples) in the same operation:

```elixir
# Use existing memo reference for one field, new content for another
{:ok, handler} = Xbase.MemoHandler.append_record_with_memo(handler, %{
  "ID" => 3,
  "TITLE" => "Mixed Content",
  "CONTENT" => "This is new content that will be stored in the DBT file",
  "NOTES" => {:memo_ref, 1}  # Reuse memo content from block 1
})
```

## Transaction Safety

### Memo Transactions

Memo operations can be wrapped in transactions for ACID compliance:

```elixir
{:ok, {result, final_handler}} = Xbase.MemoHandler.memo_transaction(handler, fn h ->
  # These operations are atomic across both DBF and DBT files
  {:ok, h1} = Xbase.MemoHandler.append_record_with_memo(h, article1)
  {:ok, h2} = Xbase.MemoHandler.append_record_with_memo(h1, article2)
  {:ok, h3} = Xbase.MemoHandler.update_record_with_memo(h2, 0, updates)
  
  {:ok, :batch_complete, h3}
end)

case result do
  :batch_complete ->
    IO.puts("All memo operations completed successfully")
  {:error, reason} ->
    IO.puts("Transaction failed and was rolled back: #{inspect(reason)}")
end
```

## Low-Level Memo Operations

For advanced use cases, you can work directly with DBT files:

### Direct DBT File Operations

```elixir
# Open DBT file directly
{:ok, dbt} = Xbase.DbtParser.open_dbt("articles.dbt")

# Read memo content by block number
{:ok, content} = Xbase.DbtParser.read_memo(dbt, 1)
IO.puts("Memo content: #{content}")

# Close DBT file
Xbase.DbtParser.close_dbt(dbt)
```

### Writing to DBT Files

```elixir
# Open DBT file for writing
{:ok, dbt} = Xbase.DbtWriter.open_dbt_for_writing("articles.dbt")

# Write new memo content
{:ok, {block_number, updated_dbt}} = Xbase.DbtWriter.write_memo(dbt, "New memo content")
IO.puts("Content stored in block: #{block_number}")

# Update existing memo
{:ok, updated_dbt} = Xbase.DbtWriter.update_memo(updated_dbt, block_number, "Updated content")

# Close file
Xbase.DbtWriter.close_dbt(updated_dbt)
```

## Performance Considerations

### Memo Caching

The library includes built-in caching for frequently accessed memo content:

```elixir
# First read - loads from file
{:ok, record1} = Xbase.MemoHandler.read_record_with_memo(handler, 0)

# Subsequent reads - served from cache if recently accessed
{:ok, record2} = Xbase.MemoHandler.read_record_with_memo(handler, 0)
```

### Memory Management

For large memo files, consider:

1. **Streaming access**: Process records one at a time
2. **Selective reading**: Only resolve memo content when needed
3. **Cache management**: Built-in LRU cache manages memory automatically

```elixir
# Memory-efficient processing of large memo files
{:ok, dbf} = Xbase.Parser.open_dbf("large_memo_file.dbf")

# Process records without resolving all memo content
summary = 
  dbf
  |> Xbase.Parser.stream_records()
  |> Stream.map(fn record -> 
    # Only extract non-memo fields for summary
    %{
      id: record["ID"],
      title: record["TITLE"],
      has_content: match?({:memo_ref, n} when n > 0, record["CONTENT"])
    }
  end)
  |> Enum.to_list()

Xbase.Parser.close_dbf(dbf)
```

## File Management

### DBT File Compaction

Over time, DBT files can become fragmented. Use compaction to optimize:

```elixir
# Open DBT file for analysis
{:ok, dbt} = Xbase.DbtWriter.open_dbt_for_writing("articles.dbt")

# Analyze fragmentation
{:ok, stats} = Xbase.DbtWriter.analyze_fragmentation(dbt)
IO.inspect(stats)
# => %{total_blocks: 100, used_blocks: 60, free_blocks: 40, fragmentation_ratio: 0.4}

# Compact if fragmentation is high
if stats.fragmentation_ratio > 0.3 do
  {:ok, compacted_dbt} = Xbase.DbtWriter.compact_dbt(dbt, "articles_compacted.dbt")
  # Replace original with compacted version
  File.rename("articles_compacted.dbt", "articles.dbt")
end
```

### File Coordination

When working with both DBF and DBT files manually, ensure proper coordination:

```elixir
# Always open both files together
{:ok, dbf} = Xbase.Parser.open_dbf("data.dbf", [:read, :write])
{:ok, dbt} = Xbase.DbtWriter.open_dbt_for_writing("data.dbt")

# Coordinate operations
{:ok, {memo_block, updated_dbt}} = Xbase.DbtWriter.write_memo(dbt, "New content")
{:ok, updated_dbf} = Xbase.Parser.append_record(dbf, %{
  "TITLE" => "New Record",
  "CONTENT" => {:memo_ref, memo_block}
})

# Close both files
Xbase.Parser.close_dbf(updated_dbf)
Xbase.DbtWriter.close_dbt(updated_dbt)
```

## Error Handling

### Common Memo Errors

```elixir
case Xbase.MemoHandler.append_record_with_memo(handler, record_data) do
  {:ok, updated_handler} ->
    # Success
    updated_handler
    
  {:error, {:memo_content_without_dbt, field_names}} ->
    IO.puts("Memo content provided but no DBT file available for fields: #{inspect(field_names)}")
    
  {:error, {:invalid_memo_value, field_name, value}} ->
    IO.puts("Invalid memo value for field #{field_name}: #{inspect(value)}")
    
  {:error, {:memo_write_failed, field_name, reason}} ->
    IO.puts("Failed to write memo content for #{field_name}: #{inspect(reason)}")
    
  {:error, reason} ->
    IO.puts("Memo operation failed: #{inspect(reason)}")
end
```

### Recovery Strategies

```elixir
defmodule MemoRecovery do
  def safe_memo_operation(handler, record_data) do
    case Xbase.MemoHandler.memo_transaction(handler, fn h ->
      Xbase.MemoHandler.append_record_with_memo(h, record_data)
    end) do
      {:ok, {updated_handler, _result}} ->
        {:ok, updated_handler}
        
      {:error, reason} ->
        # Transaction automatically rolled back
        IO.puts("Memo operation failed, rolling back: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  def repair_memo_references(dbf_path, dbt_path) do
    # Custom recovery logic for corrupted memo references
    # This is a simplified example
    with {:ok, dbf} <- Xbase.Parser.open_dbf(dbf_path),
         {:ok, dbt} <- Xbase.DbtParser.open_dbt(dbt_path) do
      
      # Validate all memo references
      {:ok, records} = Xbase.Parser.read_records(dbf)
      
      invalid_refs = 
        records
        |> Enum.with_index()
        |> Enum.flat_map(fn {record, index} ->
          validate_memo_refs(record, index, dbt)
        end)
      
      Xbase.Parser.close_dbf(dbf)
      Xbase.DbtParser.close_dbt(dbt)
      
      if Enum.empty?(invalid_refs) do
        {:ok, "All memo references are valid"}
      else
        {:error, "Invalid memo references found: #{inspect(invalid_refs)}"}
      end
    end
  end
  
  defp validate_memo_refs(record, index, dbt) do
    record
    |> Enum.flat_map(fn {field_name, value} ->
      case value do
        {:memo_ref, block_num} when block_num > 0 ->
          case Xbase.DbtParser.read_memo(dbt, block_num) do
            {:ok, _content} -> []
            {:error, _reason} -> [{index, field_name, block_num}]
          end
        _ -> []
      end
    end)
  end
end
```

## Best Practices

### 1. Use MemoHandler for Simplicity
```elixir
# Preferred approach
{:ok, handler} = Xbase.MemoHandler.open_dbf_with_memo("data.dbf", [:read, :write])
# Work with memo content as strings
```

### 2. Handle Large Content Appropriately
```elixir
# For very large content, consider chunking or streaming
def process_large_memo_file(file_path) do
  {:ok, handler} = Xbase.MemoHandler.open_dbf_with_memo(file_path)
  
  # Process one record at a time to manage memory
  record_count = handler.dbf.header.record_count
  
  Enum.each(0..(record_count - 1), fn index ->
    {:ok, record} = Xbase.MemoHandler.read_record_with_memo(handler, index)
    process_record(record)
  end)
  
  Xbase.MemoHandler.close_memo_files(handler)
end
```

### 3. Use Transactions for Data Integrity
```elixir
# Always use transactions for critical operations
Xbase.MemoHandler.memo_transaction(handler, fn h ->
  # Multiple related operations
  {:ok, h1} = Xbase.MemoHandler.append_record_with_memo(h, record1)
  {:ok, h2} = Xbase.MemoHandler.update_record_with_memo(h1, 0, updates)
  {:ok, :success, h2}
end)
```

### 4. Monitor DBT File Health
```elixir
def check_memo_file_health(dbt_path) do
  {:ok, dbt} = Xbase.DbtWriter.open_dbt_for_writing(dbt_path)
  {:ok, stats} = Xbase.DbtWriter.analyze_fragmentation(dbt)
  
  cond do
    stats.fragmentation_ratio > 0.5 ->
      {:warning, "High fragmentation, consider compacting"}
    stats.fragmentation_ratio > 0.3 ->
      {:info, "Moderate fragmentation"}
    true ->
      {:ok, "File is well-optimized"}
  end
end
```