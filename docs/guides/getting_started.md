# Getting Started with Xbase

This guide will help you get up and running with the Xbase library for reading and writing dBase database files.

## Installation

Add Xbase to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:xbase, "~> 0.2.0"}
  ]
end
```

Then run:
```bash
mix deps.get
```

## Basic Concepts

### DBF Files
DBF (dBase) files are database files that store structured data in a table format. Each file contains:
- **Header**: Metadata about the file structure
- **Field Descriptors**: Schema definition (field names, types, lengths)
- **Records**: The actual data rows

### File Types
- **DBF**: Main database file containing structured records
- **DBT**: Memo file for variable-length text fields (optional)
- **CDX**: Index file for fast data access (optional)

### Field Types
- **Character (C)**: Text fields with fixed width
- **Numeric (N)**: Integer or decimal numbers
- **Date (D)**: Date values in YYYYMMDD format
- **Logical (L)**: Boolean true/false values
- **Memo (M)**: Variable-length text stored in DBT file

## Your First DBF File

### Reading an Existing File

```elixir
# Open a DBF file
{:ok, dbf} = Xbase.Parser.open_dbf("customers.dbf")

# Read the first record
{:ok, record} = Xbase.Parser.read_record(dbf, 0)
IO.inspect(record.data)
# => %{"NAME" => "John Doe", "AGE" => 30, "CITY" => "New York"}

# Read all records
{:ok, records} = Xbase.Parser.read_records(dbf)
IO.puts("Total records: #{length(records)}")

# Don't forget to close the file
Xbase.Parser.close_dbf(dbf)
```

### Creating a New File

```elixir
# Define the field structure
fields = [
  %Xbase.Types.FieldDescriptor{name: "NAME", type: "C", length: 30},
  %Xbase.Types.FieldDescriptor{name: "AGE", type: "N", length: 3, decimal_count: 0},
  %Xbase.Types.FieldDescriptor{name: "EMAIL", type: "C", length: 50},
  %Xbase.Types.FieldDescriptor{name: "ACTIVE", type: "L", length: 1}
]

# Create the DBF file
{:ok, dbf} = Xbase.Parser.create_dbf("new_customers.dbf", fields)

# Add some records
{:ok, dbf} = Xbase.Parser.append_record(dbf, %{
  "NAME" => "Alice Johnson",
  "AGE" => 25,
  "EMAIL" => "alice@example.com",
  "ACTIVE" => true
})

{:ok, dbf} = Xbase.Parser.append_record(dbf, %{
  "NAME" => "Bob Smith",
  "AGE" => 35,
  "EMAIL" => "bob@example.com",
  "ACTIVE" => false
})

# Close the file
Xbase.Parser.close_dbf(dbf)
```

## Working with Large Files

For large files, use streaming to avoid loading everything into memory:

```elixir
{:ok, dbf} = Xbase.Parser.open_dbf("large_file.dbf")

# Process records in a memory-efficient way
active_customers = 
  dbf
  |> Xbase.Parser.stream_records()
  |> Stream.filter(fn record -> record["ACTIVE"] == true end)
  |> Stream.map(fn record -> record["NAME"] end)
  |> Enum.to_list()

IO.puts("Active customers: #{length(active_customers)}")

Xbase.Parser.close_dbf(dbf)
```

## Updating Records

```elixir
{:ok, dbf} = Xbase.Parser.open_dbf("customers.dbf", [:read, :write])

# Update a specific record
{:ok, dbf} = Xbase.Parser.update_record(dbf, 0, %{
  "AGE" => 31,
  "EMAIL" => "newemail@example.com"
})

# Mark a record as deleted
{:ok, dbf} = Xbase.Parser.mark_deleted(dbf, 1)

# Undelete a record
{:ok, dbf} = Xbase.Parser.undelete_record(dbf, 1)

Xbase.Parser.close_dbf(dbf)
```

## Working with Memo Fields

Memo fields allow storing variable-length text. Use `MemoHandler` for seamless integration:

```elixir
# Define fields including a memo field
fields = [
  %Xbase.Types.FieldDescriptor{name: "TITLE", type: "C", length: 50},
  %Xbase.Types.FieldDescriptor{name: "CONTENT", type: "M", length: 10}
]

# Create file with memo support
{:ok, handler} = Xbase.MemoHandler.create_dbf_with_memo("articles.dbf", fields)

# Add record with memo content
{:ok, handler} = Xbase.MemoHandler.append_record_with_memo(handler, %{
  "TITLE" => "My First Article",
  "CONTENT" => "This is a long article content that will be stored in the memo file..."
})

# Read back with resolved memo content
{:ok, record} = Xbase.MemoHandler.read_record_with_memo(handler, 0)
IO.puts("Article: #{record["TITLE"]}")
IO.puts("Content: #{record["CONTENT"]}")

Xbase.MemoHandler.close_memo_files(handler)
```

## Error Handling

Always handle errors appropriately:

```elixir
case Xbase.Parser.open_dbf("data.dbf") do
  {:ok, dbf} ->
    # Work with the file
    {:ok, records} = Xbase.Parser.read_records(dbf)
    Xbase.Parser.close_dbf(dbf)
    {:ok, records}
    
  {:error, :enoent} ->
    {:error, "File not found"}
    
  {:error, reason} ->
    {:error, "Failed to open file: #{inspect(reason)}"}
end
```

## Batch Operations for Performance

When working with many records, use batch operations:

```elixir
{:ok, dbf} = Xbase.Parser.open_dbf("data.dbf", [:read, :write])

# Batch append multiple records
records = [
  %{"NAME" => "User 1", "AGE" => 25},
  %{"NAME" => "User 2", "AGE" => 30},
  %{"NAME" => "User 3", "AGE" => 35}
]

{:ok, dbf} = Xbase.Parser.batch_append_records(dbf, records)

# Batch update multiple records
updates = [
  {0, %{"AGE" => 26}},
  {1, %{"AGE" => 31}},
  {2, %{"AGE" => 36}}
]

{:ok, dbf} = Xbase.Parser.batch_update_records(dbf, updates)

Xbase.Parser.close_dbf(dbf)
```

## Using Transactions

Protect your data with transactions:

```elixir
{:ok, dbf} = Xbase.Parser.open_dbf("data.dbf", [:read, :write])

result = Xbase.Parser.with_transaction(dbf, fn dbf ->
  # These operations will be rolled back if any fail
  {:ok, dbf} = Xbase.Parser.append_record(dbf, record1)
  {:ok, dbf} = Xbase.Parser.append_record(dbf, record2)
  {:ok, dbf} = Xbase.Parser.update_record(dbf, 0, updates)
  
  # Return success
  {:ok, :transaction_complete}
end)

case result do
  {:ok, :transaction_complete} ->
    IO.puts("All operations completed successfully")
  {:error, reason} ->
    IO.puts("Transaction failed and was rolled back: #{inspect(reason)}")
end

Xbase.Parser.close_dbf(dbf)
```

## Next Steps

Now that you've learned the basics, explore these advanced topics:

1. **[Working with Indexes](indexes.md)** - Use CDX files for fast data access
2. **[Streaming Large Files](streaming.md)** - Memory-efficient processing
3. **[Advanced Memo Operations](memo_fields.md)** - Complex memo field handling
4. **[Performance Optimization](performance.md)** - Tips for high-performance applications

## Common Patterns

### Reading and Processing Data
```elixir
defmodule DataProcessor do
  def process_customers(file_path) do
    with {:ok, dbf} <- Xbase.Parser.open_dbf(file_path) do
      results = 
        dbf
        |> Xbase.Parser.stream_records()
        |> Stream.map(fn record -> process_customer(record) end)
        |> Enum.to_list()
      
      Xbase.Parser.close_dbf(dbf)
      {:ok, results}
    end
  end
  
  defp process_customer(customer_data) do
    # Your processing logic here
    customer_data
  end
end
```

### Creating Reports
```elixir
defmodule ReportGenerator do
  def age_distribution(file_path) do
    with {:ok, dbf} <- Xbase.Parser.open_dbf(file_path) do
      distribution = 
        dbf
        |> Xbase.Parser.stream_records()
        |> Stream.map(fn record -> record["AGE"] end)
        |> Enum.frequencies()
      
      Xbase.Parser.close_dbf(dbf)
      {:ok, distribution}
    end
  end
end
```

### Data Migration
```elixir
defmodule DataMigration do
  def migrate_to_new_format(source_path, target_path) do
    # Define new field structure
    new_fields = [
      %Xbase.Types.FieldDescriptor{name: "ID", type: "N", length: 10},
      %Xbase.Types.FieldDescriptor{name: "FULL_NAME", type: "C", length: 50},
      %Xbase.Types.FieldDescriptor{name: "AGE_GROUP", type: "C", length: 10}
    ]
    
    with {:ok, source_dbf} <- Xbase.Parser.open_dbf(source_path),
         {:ok, target_dbf} <- Xbase.Parser.create_dbf(target_path, new_fields) do
      
      # Migrate data with transformation
      final_dbf = 
        source_dbf
        |> Xbase.Parser.stream_records()
        |> Enum.reduce(target_dbf, fn record, acc_dbf ->
          transformed = transform_record(record)
          {:ok, new_dbf} = Xbase.Parser.append_record(acc_dbf, transformed)
          new_dbf
        end)
      
      Xbase.Parser.close_dbf(source_dbf)
      Xbase.Parser.close_dbf(final_dbf)
      :ok
    end
  end
  
  defp transform_record(old_data) do
    %{
      "ID" => old_data["CUSTOMER_ID"],
      "FULL_NAME" => "#{old_data["FIRST_NAME"]} #{old_data["LAST_NAME"]}",
      "AGE_GROUP" => age_group(old_data["AGE"])
    }
  end
  
  defp age_group(age) when age < 30, do: "Young"
  defp age_group(age) when age < 60, do: "Middle"
  defp age_group(_age), do: "Senior"
end
```