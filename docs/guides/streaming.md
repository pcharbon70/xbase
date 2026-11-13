# Streaming Large Files

Xbase provides powerful streaming capabilities for processing large DBF files without loading everything into memory. This guide covers memory-efficient techniques for working with large datasets.

## Understanding Streaming

### Why Stream?

When working with large DBF files, loading all records into memory can cause:
- **Memory exhaustion** on systems with limited RAM
- **Poor performance** due to excessive memory allocation
- **Application crashes** when files exceed available memory
- **Slow startup times** for large datasets

### Benefits of Streaming

- **Constant Memory Usage**: Memory usage remains constant regardless of file size
- **Lazy Evaluation**: Records are processed only when needed
- **Early Termination**: Stop processing when conditions are met
- **Composable**: Chain multiple stream operations together

## Basic Streaming Operations

### Reading Records as a Stream

```elixir
# Open file and create stream
{:ok, dbf} = Xbase.Parser.open_dbf("large_dataset.dbf")

# Stream all records
record_stream = Xbase.Parser.stream_records(dbf)

# Process records one at a time
results = 
  record_stream
  |> Stream.map(fn record -> process_record(record) end)
  |> Enum.to_list()

Xbase.Parser.close_dbf(dbf)
```

### Filtering Large Datasets

```elixir
{:ok, dbf} = Xbase.Parser.open_dbf("customers.dbf")

# Find active customers in specific states
active_customers = 
  dbf
  |> Xbase.Parser.stream_records()
  |> Stream.filter(fn record -> 
    record["ACTIVE"] == true and
    record["STATE"] in ["CA", "NY", "TX"]
  end)
  |> Stream.map(fn record -> 
    %{
      name: record["NAME"],
      email: record["EMAIL"],
      state: record["STATE"]
    }
  end)
  |> Enum.to_list()

IO.puts("Found #{length(active_customers)} active customers")
Xbase.Parser.close_dbf(dbf)
```

### Counting and Aggregation

```elixir
{:ok, dbf} = Xbase.Parser.open_dbf("sales.dbf")

# Count records by category without loading all into memory
category_counts = 
  dbf
  |> Xbase.Parser.stream_records()
  |> Stream.map(fn record -> record["CATEGORY"] end)
  |> Enum.frequencies()

IO.inspect(category_counts)
Xbase.Parser.close_dbf(dbf)
```

## Advanced Streaming Patterns

### Chunked Processing

```elixir
defmodule ChunkedProcessor do
  def process_in_chunks(dbf, chunk_size \\ 1000) do
    dbf
    |> Xbase.Parser.stream_records()
    |> Stream.chunk_every(chunk_size)
    |> Stream.map(&process_chunk/1)
    |> Enum.to_list()
  end
  
  defp process_chunk(records) do
    # Process a chunk of records together
    # This is useful for batch operations or database inserts
    results = Enum.map(records, &transform_record/1)
    
    # Could insert batch into database here
    # MyRepo.insert_all(Customer, results)
    
    length(results)
  end
  
  defp transform_record(record) do
    %{
      name: String.upcase(record["NAME"]),
      email: String.downcase(record["EMAIL"]),
      processed_at: DateTime.utc_now()
    }
  end
end
```

### Streaming with Early Termination

```elixir
defmodule EarlyTermination do
  def find_first_match(dbf, condition_fn) do
    dbf
    |> Xbase.Parser.stream_records()
    |> Enum.find(condition_fn)
  end
  
  def take_sample(dbf, sample_size) do
    dbf
    |> Xbase.Parser.stream_records()
    |> Stream.take(sample_size)
    |> Enum.to_list()
  end
  
  def process_until_condition(dbf, stop_condition) do
    dbf
    |> Xbase.Parser.stream_records()
    |> Stream.take_while(fn record -> not stop_condition.(record) end)
    |> Stream.map(&process_record/1)
    |> Enum.to_list()
  end
  
  defp process_record(record) do
    # Your processing logic here
    record
  end
end
```

### Parallel Streaming

```elixir
defmodule ParallelStreaming do
  def parallel_process(dbf, concurrency \\ System.schedulers_online()) do
    dbf
    |> Xbase.Parser.stream_records()
    |> Stream.chunk_every(100)  # Process in batches
    |> Task.async_stream(
      &process_batch/1,
      max_concurrency: concurrency,
      timeout: :infinity
    )
    |> Stream.map(fn {:ok, result} -> result end)
    |> Enum.to_list()
  end
  
  defp process_batch(records) do
    # CPU-intensive processing on a batch of records
    Enum.map(records, fn record ->
      # Simulate complex processing
      :timer.sleep(10)
      transform_record(record)
    end)
  end
  
  defp transform_record(record) do
    # Your transformation logic
    %{
      id: record["ID"],
      processed_data: process_field(record["DATA"])
    }
  end
  
  defp process_field(data) do
    # Simulate processing
    String.upcase(data || "")
  end
end
```

## Memory-Efficient File Processing

### Large File Analytics

```elixir
defmodule LargeFileAnalytics do
  def analyze_sales_data(file_path) do
    {:ok, dbf} = Xbase.Parser.open_dbf(file_path)
    
    analytics = 
      dbf
      |> Xbase.Parser.stream_records()
      |> Stream.map(&extract_sales_data/1)
      |> Enum.reduce(initial_analytics(), &update_analytics/2)
    
    Xbase.Parser.close_dbf(dbf)
    finalize_analytics(analytics)
  end
  
  defp extract_sales_data(record) do
    %{
      amount: record["AMOUNT"] || 0,
      date: record["SALE_DATE"],
      region: record["REGION"],
      product: record["PRODUCT"]
    }
  end
  
  defp initial_analytics do
    %{
      total_sales: 0,
      total_amount: 0.0,
      region_totals: %{},
      product_counts: %{},
      monthly_sales: %{},
      min_amount: :infinity,
      max_amount: 0
    }
  end
  
  defp update_analytics(sale, analytics) do
    month_key = format_month(sale.date)
    
    %{
      analytics |
      total_sales: analytics.total_sales + 1,
      total_amount: analytics.total_amount + sale.amount,
      region_totals: update_region_total(analytics.region_totals, sale.region, sale.amount),
      product_counts: Map.update(analytics.product_counts, sale.product, 1, &(&1 + 1)),
      monthly_sales: Map.update(analytics.monthly_sales, month_key, sale.amount, &(&1 + sale.amount)),
      min_amount: min(analytics.min_amount, sale.amount),
      max_amount: max(analytics.max_amount, sale.amount)
    }
  end
  
  defp update_region_total(region_totals, region, amount) do
    Map.update(region_totals, region, amount, &(&1 + amount))
  end
  
  defp format_month(date) when is_nil(date), do: "unknown"
  defp format_month(%Date{} = date), do: "#{date.year}-#{String.pad_leading("#{date.month}", 2, "0")}"
  defp format_month(_), do: "invalid"
  
  defp finalize_analytics(analytics) do
    %{
      analytics |
      average_amount: analytics.total_amount / max(analytics.total_sales, 1),
      min_amount: if(analytics.min_amount == :infinity, do: 0, else: analytics.min_amount)
    }
  end
end
```

### Data Migration Streaming

```elixir
defmodule DataMigration do
  def migrate_to_database(source_path, destination_repo) do
    {:ok, dbf} = Xbase.Parser.open_dbf(source_path)
    
    migration_stats = 
      dbf
      |> Xbase.Parser.stream_records()
      |> Stream.map(&transform_for_database/1)
      |> Stream.chunk_every(500)  # Insert in batches
      |> Stream.with_index()
      |> Enum.reduce(%{processed: 0, errors: 0}, fn {batch, index}, stats ->
        case insert_batch(destination_repo, batch) do
          {:ok, count} ->
            IO.puts("Processed batch #{index + 1}: #{count} records")
            %{stats | processed: stats.processed + count}
            
          {:error, reason} ->
            IO.puts("Error in batch #{index + 1}: #{inspect(reason)}")
            %{stats | errors: stats.errors + 1}
        end
      end)
    
    Xbase.Parser.close_dbf(dbf)
    migration_stats
  end
  
  defp transform_for_database(record) do
    %{
      external_id: record["ID"],
      name: record["NAME"],
      email: record["EMAIL"],
      phone: record["PHONE"],
      address: record["ADDRESS"],
      city: record["CITY"],
      state: record["STATE"],
      zip: record["ZIP"],
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
  end
  
  defp insert_batch(repo, batch) do
    try do
      {count, _} = repo.insert_all("customers", batch)
      {:ok, count}
    rescue
      error ->
        {:error, error}
    end
  end
end
```

## Streaming with Memo Fields

### Memory-Efficient Memo Processing

```elixir
defmodule MemoStreaming do
  def stream_with_selective_memo_loading(file_path) do
    {:ok, handler} = Xbase.MemoHandler.open_dbf_with_memo(file_path)
    
    results = 
      handler.dbf
      |> Xbase.Parser.stream_records()
      |> Stream.map(fn record ->
        # Only load memo content when certain conditions are met
        if needs_memo_content?(record) do
          # Load full record with memo content
          {:ok, full_record} = Xbase.MemoHandler.read_record_with_memo(
            handler, 
            record["_record_index"] || 0
          )
          process_with_memo(full_record)
        else
          # Process without loading memo content
          process_without_memo(record)
        end
      end)
      |> Enum.to_list()
    
    Xbase.MemoHandler.close_memo_files(handler)
    results
  end
  
  defp needs_memo_content?(record) do
    # Only load memo content for high-priority records
    record["PRIORITY"] == "HIGH" or
    record["STATUS"] == "REVIEW_REQUIRED"
  end
  
  defp process_with_memo(record_data) do
    %{
      id: record_data["ID"],
      title: record_data["TITLE"],
      content_length: String.length(record_data["CONTENT"] || ""),
      has_memo: true
    }
  end
  
  defp process_without_memo(record_data) do
    %{
      id: record_data["ID"],
      title: record_data["TITLE"],
      has_memo: match?({:memo_ref, n} when n > 0, record_data["CONTENT"])
    }
  end
end
```

## Performance Optimization

### Stream Optimization Strategies

```elixir
defmodule StreamOptimization do
  def optimized_processing(file_path, options \\ []) do
    buffer_size = Keyword.get(options, :buffer_size, 8192)
    chunk_size = Keyword.get(options, :chunk_size, 1000)
    
    {:ok, dbf} = Xbase.Parser.open_dbf(file_path, buffer_size: buffer_size)
    
    result = 
      dbf
      |> Xbase.Parser.stream_records()
      |> Stream.chunk_every(chunk_size)
      |> Stream.map(&process_chunk_optimized/1)
      |> Enum.reduce([], &combine_results/2)
    
    Xbase.Parser.close_dbf(dbf)
    result
  end
  
  defp process_chunk_optimized(records) do
    # Use more efficient data structures for processing
    records
    |> Enum.map(&extract_key_data/1)
    |> Enum.group_by(& &1.category)
  end
  
  defp extract_key_data(record) do
    %{
      id: record["ID"],
      category: record["CATEGORY"],
      amount: record["AMOUNT"] || 0
    }
  end
  
  defp combine_results(chunk_result, accumulator) do
    Map.merge(accumulator, chunk_result, fn _key, acc_list, chunk_list ->
      acc_list ++ chunk_list
    end)
  end
end
```

### Memory Monitoring

```elixir
defmodule MemoryMonitor do
  def process_with_monitoring(file_path) do
    {:ok, dbf} = Xbase.Parser.open_dbf(file_path)
    
    initial_memory = get_memory_usage()
    IO.puts("Starting memory usage: #{format_memory(initial_memory)}")
    
    result = 
      dbf
      |> Xbase.Parser.stream_records()
      |> Stream.with_index()
      |> Stream.map(fn {record, index} ->
        if rem(index, 10000) == 0 do
          current_memory = get_memory_usage()
          IO.puts("Processed #{index} records, memory: #{format_memory(current_memory)}")
        end
        
        process_record(record)
      end)
      |> Enum.to_list()
    
    final_memory = get_memory_usage()
    IO.puts("Final memory usage: #{format_memory(final_memory)}")
    IO.puts("Memory difference: #{format_memory(final_memory - initial_memory)}")
    
    Xbase.Parser.close_dbf(dbf)
    result
  end
  
  defp get_memory_usage do
    :erlang.memory(:total)
  end
  
  defp format_memory(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} bytes"
    end
  end
  
  defp process_record(record) do
    # Your processing logic here
    record["ID"]
  end
end
```

## Error Handling in Streams

### Resilient Stream Processing

```elixir
defmodule ResilientStreaming do
  def process_with_error_handling(file_path) do
    {:ok, dbf} = Xbase.Parser.open_dbf(file_path)
    
    {successes, errors} = 
      dbf
      |> Xbase.Parser.stream_records()
      |> Stream.with_index()
      |> Stream.map(&safe_process_record/1)
      |> Enum.split_with(fn {status, _} -> status == :ok end)
    
    Xbase.Parser.close_dbf(dbf)
    
    success_count = length(successes)
    error_count = length(errors)
    
    IO.puts("Successfully processed: #{success_count} records")
    IO.puts("Errors encountered: #{error_count} records")
    
    if error_count > 0 do
      IO.puts("First few errors:")
      errors
      |> Enum.take(5)
      |> Enum.each(fn {:error, {index, reason}} ->
        IO.puts("  Record #{index}: #{inspect(reason)}")
      end)
    end
    
    %{
      successes: Enum.map(successes, fn {:ok, {_index, result}} -> result end),
      errors: Enum.map(errors, fn {:error, {index, reason}} -> {index, reason} end)
    }
  end
  
  defp safe_process_record({record, index}) do
    try do
      result = process_record_with_validation(record)
      {:ok, {index, result}}
    rescue
      error ->
        {:error, {index, error}}
    catch
      :throw, reason ->
        {:error, {index, reason}}
    end
  end
  
  defp process_record_with_validation(record) do
    # Validate required fields
    required_fields = ["ID", "NAME", "EMAIL"]
    
    missing_fields = 
      required_fields
      |> Enum.filter(fn field -> is_nil(record[field]) or record[field] == "" end)
    
    if length(missing_fields) > 0 do
      throw("Missing required fields: #{Enum.join(missing_fields, ", ")}")
    end
    
    # Validate email format
    if not valid_email?(record["EMAIL"]) do
      throw("Invalid email format: #{record["EMAIL"]}")
    end
    
    # Process the record
    %{
      id: record["ID"],
      name: String.trim(record["NAME"]),
      email: String.downcase(record["EMAIL"])
    }
  end
  
  defp valid_email?(email) do
    Regex.match?(~r/^[^\s]+@[^\s]+\.[^\s]+$/, email)
  end
end
```

## Best Practices

### 1. Choose the Right Streaming Strategy

```elixir
defmodule StreamingStrategy do
  def choose_strategy(file_size, available_memory, processing_complexity) do
    cond do
      file_size < available_memory * 0.1 ->
        :load_all  # Small file, load everything
        
      processing_complexity == :simple ->
        :simple_stream  # Use basic streaming
        
      processing_complexity == :complex ->
        :chunked_stream  # Process in chunks
        
      true ->
        :parallel_stream  # Use parallel processing
    end
  end
end
```

### 2. Monitor Resource Usage

```elixir
defmodule ResourceMonitoring do
  def monitor_stream_processing(stream_fn) do
    start_time = System.monotonic_time(:millisecond)
    start_memory = :erlang.memory(:total)
    
    result = stream_fn.()
    
    end_time = System.monotonic_time(:millisecond)
    end_memory = :erlang.memory(:total)
    
    stats = %{
      execution_time_ms: end_time - start_time,
      memory_used: end_memory - start_memory,
      peak_memory: :erlang.memory(:total)
    }
    
    IO.puts("Stream processing completed:")
    IO.puts("  Time: #{stats.execution_time_ms}ms")
    IO.puts("  Memory used: #{format_bytes(stats.memory_used)}")
    
    {result, stats}
  end
  
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end
```

### 3. Handle Backpressure

```elixir
defmodule BackpressureHandling do
  def controlled_processing(file_path, max_concurrent_operations \\ 10) do
    {:ok, dbf} = Xbase.Parser.open_dbf(file_path)
    
    dbf
    |> Xbase.Parser.stream_records()
    |> Stream.chunk_every(100)
    |> Task.async_stream(
      &process_batch/1,
      max_concurrency: max_concurrent_operations,
      timeout: 30_000,
      on_timeout: :kill_task
    )
    |> Stream.map(fn 
      {:ok, result} -> result
      {:exit, :timeout} -> {:error, :timeout}
    end)
    |> Enum.to_list()
  end
  
  defp process_batch(records) do
    # Simulate processing with potential delays
    records
    |> Enum.map(&process_single_record/1)
    |> Enum.count()
  end
  
  defp process_single_record(record) do
    # Your processing logic here
    :timer.sleep(:rand.uniform(10))  # Simulate variable processing time
    record["ID"]
  end
end
```

This comprehensive guide provides the tools and patterns needed to efficiently process large DBF files using streaming techniques in Xbase.