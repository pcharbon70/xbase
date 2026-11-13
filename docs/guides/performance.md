# Performance Optimization

This guide covers advanced techniques for optimizing Xbase performance across different use cases, from small files to enterprise-scale datasets.

## Performance Fundamentals

### Understanding DBF Performance Characteristics

DBF file operations have different performance profiles:

| Operation | Time Complexity | Memory Usage | Disk I/O |
|-----------|----------------|--------------|----------|
| Open file | O(1) | Constant | Single read |
| Read record by index | O(1) | Constant | Single seek + read |
| Stream records | O(n) | Constant | Sequential reads |
| Search without index | O(n) | Constant | Full scan |
| Search with index | O(log n) | Constant | B-tree traversal |
| Append record | O(1) | Constant | Single write |
| Update record | O(1) | Constant | Seek + write |
| Pack file | O(n) | Variable | Full rewrite |

### Performance Bottlenecks

Common performance issues and their solutions:

1. **Excessive Memory Usage**: Use streaming instead of loading all records
2. **Slow Searches**: Implement indexes for frequently searched fields
3. **I/O Bottlenecks**: Use batch operations and optimize file access patterns
4. **CPU Intensive Processing**: Leverage parallel processing
5. **Memo File Fragmentation**: Regular compaction and maintenance

## File Access Optimization

### Efficient File Opening

```elixir
defmodule FileOptimization do
  def optimized_file_access(file_path, options \\ []) do
    # Configure optimal buffer sizes
    buffer_size = Keyword.get(options, :buffer_size, 64 * 1024)  # 64KB
    read_ahead = Keyword.get(options, :read_ahead, true)
    
    file_options = [
      :binary,
      :read,
      {:read_ahead, if(read_ahead, do: buffer_size, else: false)},
      {:buffer, buffer_size}
    ]
    
    case Xbase.Parser.open_dbf(file_path, file_options) do
      {:ok, dbf} ->
        # Prefetch header and field information
        {:ok, optimized_dbf} = prefetch_metadata(dbf)
        {:ok, optimized_dbf}
        
      error ->
        error
    end
  end
  
  defp prefetch_metadata(dbf) do
    # Pre-load frequently accessed metadata
    field_names = Enum.map(dbf.fields, & &1.name)
    record_size = dbf.header.record_length
    
    optimized_dbf = %{
      dbf |
      cached_field_names: field_names,
      cached_record_size: record_size,
      performance_hints: %{
        small_file: dbf.header.record_count < 10_000,
        has_memo_fields: Enum.any?(dbf.fields, &(&1.type == "M"))
      }
    }
    
    {:ok, optimized_dbf}
  end
end
```

### Batch File Operations

```elixir
defmodule BatchOperations do
  def batch_read_records(dbf, record_indices) when length(record_indices) > 100 do
    # For large batches, group by proximity to minimize seeks
    sorted_indices = Enum.sort(record_indices)
    
    sorted_indices
    |> group_consecutive_ranges()
    |> Enum.flat_map(&read_range/2, dbf)
  end
  
  def batch_read_records(dbf, record_indices) do
    # For small batches, read individually
    Enum.map(record_indices, &Xbase.Parser.read_record(dbf, &1))
  end
  
  defp group_consecutive_ranges(indices) do
    indices
    |> Enum.chunk_while(
      [],
      fn index, acc ->
        case acc do
          [] -> {:cont, [index]}
          [last | _] when index == last + 1 -> {:cont, [index | acc]}
          _ -> {:emit, Enum.reverse(acc), [index]}
        end
      end,
      fn acc -> {:emit, Enum.reverse(acc), []} end
    )
  end
  
  defp read_range(dbf, range) when length(range) > 10 do
    # Read contiguous ranges efficiently
    start_index = List.first(range)
    count = length(range)
    Xbase.Parser.read_record_range(dbf, start_index, count)
  end
  
  defp read_range(dbf, indices) do
    Enum.map(indices, &Xbase.Parser.read_record(dbf, &1))
  end
end
```

## Memory Management

### Stream-Based Processing

```elixir
defmodule MemoryEfficientProcessing do
  def process_large_file(file_path, processor_fn) do
    {:ok, dbf} = Xbase.Parser.open_dbf(file_path)
    
    # Use lazy streams to maintain constant memory usage
    result = 
      dbf
      |> Xbase.Parser.stream_records()
      |> Stream.map(processor_fn)
      |> Stream.chunk_every(1000)  # Process in chunks
      |> Stream.map(&consolidate_chunk/1)
      |> Enum.reduce(%{}, &merge_results/2)
    
    Xbase.Parser.close_dbf(dbf)
    result
  end
  
  defp consolidate_chunk(records) do
    # Consolidate a chunk of processed records
    records
    |> Enum.group_by(& &1.category)
    |> Map.new(fn {category, items} ->
      {category, %{
        count: length(items),
        total_value: Enum.sum(Enum.map(items, & &1.value))
      }}
    end)
  end
  
  defp merge_results(chunk_result, accumulator) do
    Map.merge(accumulator, chunk_result, fn _key, acc_stats, chunk_stats ->
      %{
        count: acc_stats.count + chunk_stats.count,
        total_value: acc_stats.total_value + chunk_stats.total_value
      }
    end)
  end
end
```

### Memory Pool Management

```elixir
defmodule MemoryPool do
  use GenServer
  
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def get_buffer(size) do
    GenServer.call(__MODULE__, {:get_buffer, size})
  end
  
  def return_buffer(buffer) do
    GenServer.cast(__MODULE__, {:return_buffer, buffer})
  end
  
  def init(opts) do
    max_pool_size = Keyword.get(opts, :max_pool_size, 100)
    default_buffer_size = Keyword.get(opts, :default_buffer_size, 8192)
    
    state = %{
      pools: %{},
      max_pool_size: max_pool_size,
      default_buffer_size: default_buffer_size
    }
    
    {:ok, state}
  end
  
  def handle_call({:get_buffer, size}, _from, state) do
    case Map.get(state.pools, size, []) do
      [buffer | rest] ->
        new_pools = Map.put(state.pools, size, rest)
        {:reply, buffer, %{state | pools: new_pools}}
        
      [] ->
        buffer = :binary.copy(<<0>>, size)
        {:reply, buffer, state}
    end
  end
  
  def handle_cast({:return_buffer, buffer}, state) do
    size = byte_size(buffer)
    current_pool = Map.get(state.pools, size, [])
    
    new_pool = 
      if length(current_pool) < state.max_pool_size do
        [buffer | current_pool]
      else
        current_pool  # Pool is full, discard buffer
      end
    
    new_pools = Map.put(state.pools, size, new_pool)
    {:noreply, %{state | pools: new_pools}}
  end
end
```

## Indexing for Performance

### Strategic Index Creation

```elixir
defmodule IndexStrategy do
  def analyze_query_patterns(dbf, query_log) do
    field_access_frequency = 
      query_log
      |> Enum.flat_map(& &1.accessed_fields)
      |> Enum.frequencies()
    
    # Identify high-value index candidates
    index_candidates = 
      field_access_frequency
      |> Enum.filter(fn {_field, frequency} -> frequency > 100 end)
      |> Enum.sort_by(fn {_field, frequency} -> frequency end, :desc)
      |> Enum.take(5)  # Top 5 most accessed fields
    
    # Create indexes for high-traffic fields
    Enum.each(index_candidates, fn {field_name, _frequency} ->
      create_field_index(dbf, field_name)
    end)
    
    index_candidates
  end
  
  defp create_field_index(dbf, field_name) do
    field = Enum.find(dbf.fields, &(&1.name == field_name))
    cdx_path = String.replace(dbf.file_path, ".dbf", ".cdx")
    
    index_spec = %{
      key_expression: field_name,
      key_length: field.length,
      index_name: "IDX_#{field_name}"
    }
    
    case Xbase.CdxParser.add_index(cdx_path, index_spec) do
      {:ok, _cdx} ->
        IO.puts("Created index for #{field_name}")
      {:error, reason} ->
        IO.puts("Failed to create index for #{field_name}: #{inspect(reason)}")
    end
  end
end
```

### Index-Optimized Queries

```elixir
defmodule OptimizedQueries do
  def smart_search(dbf, cdx, search_criteria) do
    case determine_best_index(cdx, search_criteria) do
      {:ok, best_index} ->
        index_based_search(best_index, search_criteria)
        
      :no_suitable_index ->
        fallback_to_scan(dbf, search_criteria)
    end
  end
  
  defp determine_best_index(cdx, search_criteria) do
    available_indexes = Xbase.CdxParser.list_indexes(cdx)
    
    # Score indexes based on search criteria
    scored_indexes = 
      available_indexes
      |> Enum.map(&score_index_for_criteria(&1, search_criteria))
      |> Enum.filter(fn {_index, score} -> score > 0 end)
      |> Enum.sort_by(fn {_index, score} -> score end, :desc)
    
    case scored_indexes do
      [{best_index, _score} | _] -> {:ok, best_index}
      [] -> :no_suitable_index
    end
  end
  
  defp score_index_for_criteria(index, criteria) do
    score = 
      case criteria do
        %{exact_match: field} when index.key_expression == field ->
          100  # Perfect match for exact search
          
        %{range_query: field} when index.key_expression == field ->
          90   # Excellent for range queries
          
        %{starts_with: field} when String.starts_with?(index.key_expression, field) ->
          70   # Good for prefix searches
          
        _ ->
          0    # Not suitable
      end
    
    {index, score}
  end
  
  defp index_based_search(index, criteria) do
    case criteria do
      %{exact_match: field, value: value} ->
        Xbase.CdxParser.search_key(index, value)
        
      %{range_query: field, min_value: min_val, max_value: max_val} ->
        Xbase.CdxParser.search_range(index, min_val, max_val)
        
      %{starts_with: field, prefix: prefix} ->
        Xbase.CdxParser.search_partial(index, prefix)
    end
  end
  
  defp fallback_to_scan(dbf, criteria) do
    IO.puts("Warning: No suitable index found, falling back to full table scan")
    
    dbf
    |> Xbase.Parser.stream_records()
    |> Stream.filter(&matches_criteria?(&1, criteria))
    |> Enum.to_list()
  end
  
  defp matches_criteria?(record, criteria) do
    case criteria do
      %{exact_match: field, value: value} ->
        record[field] == value
        
      %{range_query: field, min_value: min_val, max_value: max_val} ->
        field_value = record[field]
        field_value >= min_val and field_value <= max_val
        
      %{starts_with: field, prefix: prefix} ->
        field_value = record[field] || ""
        String.starts_with?(field_value, prefix)
    end
  end
end
```

## Parallel Processing

### Concurrent Record Processing

```elixir
defmodule ParallelProcessing do
  def parallel_transform(dbf, transform_fn, opts \\ []) do
    concurrency = Keyword.get(opts, :concurrency, System.schedulers_online())
    chunk_size = Keyword.get(opts, :chunk_size, 1000)
    
    dbf
    |> Xbase.Parser.stream_records()
    |> Stream.chunk_every(chunk_size)
    |> Task.async_stream(
      fn chunk -> parallel_process_chunk(chunk, transform_fn) end,
      max_concurrency: concurrency,
      timeout: :infinity,
      ordered: false  # Allow out-of-order completion for better performance
    )
    |> Stream.map(fn {:ok, result} -> result end)
    |> Enum.to_list()
    |> List.flatten()
  end
  
  defp parallel_process_chunk(chunk, transform_fn) do
    chunk
    |> Enum.map(transform_fn)
  end
  
  def parallel_aggregation(dbf, aggregation_fns, opts \\ []) do
    concurrency = Keyword.get(opts, :concurrency, System.schedulers_online())
    
    # Split work across multiple processes
    task_results = 
      1..concurrency
      |> Enum.map(fn worker_id ->
        Task.async(fn ->
          process_partition(dbf, worker_id, concurrency, aggregation_fns)
        end)
      end)
      |> Task.await_many(:infinity)
    
    # Combine results from all workers
    Enum.reduce(task_results, &merge_aggregation_results/2)
  end
  
  defp process_partition(dbf, worker_id, total_workers, aggregation_fns) do
    record_count = dbf.header.record_count
    partition_size = div(record_count, total_workers)
    start_index = (worker_id - 1) * partition_size
    
    end_index = 
      if worker_id == total_workers do
        record_count - 1  # Last worker takes remaining records
      else
        start_index + partition_size - 1
      end
    
    # Process assigned partition
    start_index..end_index
    |> Enum.reduce(initialize_aggregation(), fn index, acc ->
      case Xbase.Parser.read_record(dbf, index) do
        {:ok, record} when not record.deleted ->
          apply_aggregation_fns(acc, record, aggregation_fns)
        _ ->
          acc
      end
    end)
  end
  
  defp initialize_aggregation do
    %{count: 0, sum: 0, min: :infinity, max: :neg_infinity}
  end
  
  defp apply_aggregation_fns(acc, record, aggregation_fns) do
    Enum.reduce(aggregation_fns, acc, fn {field, agg_type}, acc ->
      value = record.data[field] || 0
      apply_aggregation(acc, agg_type, value)
    end)
  end
  
  defp apply_aggregation(acc, :count, _value) do
    %{acc | count: acc.count + 1}
  end
  
  defp apply_aggregation(acc, :sum, value) when is_number(value) do
    %{acc | sum: acc.sum + value}
  end
  
  defp apply_aggregation(acc, :min, value) when is_number(value) do
    %{acc | min: min(acc.min, value)}
  end
  
  defp apply_aggregation(acc, :max, value) when is_number(value) do
    %{acc | max: max(acc.max, value)}
  end
  
  defp apply_aggregation(acc, _type, _value), do: acc
  
  defp merge_aggregation_results(result1, result2) do
    %{
      count: result1.count + result2.count,
      sum: result1.sum + result2.sum,
      min: min(result1.min, result2.min),
      max: max(result1.max, result2.max)
    }
  end
end
```

### Load Balancing

```elixir
defmodule LoadBalancer do
  use GenServer
  
  def start_link(worker_count \\ System.schedulers_online()) do
    GenServer.start_link(__MODULE__, worker_count, name: __MODULE__)
  end
  
  def submit_work(work_item) do
    GenServer.call(__MODULE__, {:submit_work, work_item})
  end
  
  def init(worker_count) do
    workers = 
      1..worker_count
      |> Enum.map(fn id ->
        {:ok, pid} = Worker.start_link(id)
        %{id: id, pid: pid, current_load: 0}
      end)
    
    {:ok, %{workers: workers, work_queue: :queue.new()}}
  end
  
  def handle_call({:submit_work, work_item}, _from, state) do
    case find_least_loaded_worker(state.workers) do
      {:ok, worker} ->
        Worker.assign_work(worker.pid, work_item)
        updated_workers = update_worker_load(state.workers, worker.id, +1)
        {:reply, {:ok, worker.id}, %{state | workers: updated_workers}}
        
      :all_busy ->
        updated_queue = :queue.in(work_item, state.work_queue)
        {:reply, {:queued, :queue.len(updated_queue)}, %{state | work_queue: updated_queue}}
    end
  end
  
  def handle_info({:work_completed, worker_id}, state) do
    updated_workers = update_worker_load(state.workers, worker_id, -1)
    
    # Try to assign queued work to newly available worker
    case :queue.out(state.work_queue) do
      {{:value, work_item}, updated_queue} ->
        worker = Enum.find(updated_workers, &(&1.id == worker_id))
        Worker.assign_work(worker.pid, work_item)
        final_workers = update_worker_load(updated_workers, worker_id, +1)
        {:noreply, %{state | workers: final_workers, work_queue: updated_queue}}
        
      {:empty, _queue} ->
        {:noreply, %{state | workers: updated_workers}}
    end
  end
  
  defp find_least_loaded_worker(workers) do
    case Enum.min_by(workers, & &1.current_load) do
      %{current_load: load} = worker when load < 5 -> {:ok, worker}
      _ -> :all_busy
    end
  end
  
  defp update_worker_load(workers, worker_id, load_delta) do
    Enum.map(workers, fn worker ->
      if worker.id == worker_id do
        %{worker | current_load: worker.current_load + load_delta}
      else
        worker
      end
    end)
  end
end
```

## Memo Field Optimization

### Efficient Memo Caching

```elixir
defmodule MemoCache do
  use GenServer
  
  @cache_size 1000  # Maximum number of cached memo blocks
  @ttl_ms 300_000   # 5 minutes TTL
  
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end
  
  def get_memo(dbt_file, block_number) do
    case GenServer.call(__MODULE__, {:get_memo, dbt_file.file_path, block_number}) do
      {:hit, content} ->
        {:ok, content}
      :miss ->
        case Xbase.DbtParser.read_memo(dbt_file, block_number) do
          {:ok, content} ->
            GenServer.cast(__MODULE__, {:cache_memo, dbt_file.file_path, block_number, content})
            {:ok, content}
          error ->
            error
        end
    end
  end
  
  def init(_) do
    # Start cleanup timer
    :timer.send_interval(60_000, self(), :cleanup)  # Cleanup every minute
    
    state = %{
      cache: %{},
      access_times: %{},
      size: 0
    }
    
    {:ok, state}
  end
  
  def handle_call({:get_memo, file_path, block_number}, _from, state) do
    key = {file_path, block_number}
    
    case Map.get(state.cache, key) do
      nil ->
        {:reply, :miss, state}
      content ->
        # Update access time
        updated_access_times = Map.put(state.access_times, key, System.monotonic_time(:millisecond))
        {:reply, {:hit, content}, %{state | access_times: updated_access_times}}
    end
  end
  
  def handle_cast({:cache_memo, file_path, block_number, content}, state) do
    key = {file_path, block_number}
    now = System.monotonic_time(:millisecond)
    
    # Evict if cache is full
    state = 
      if state.size >= @cache_size do
        evict_lru_item(state)
      else
        state
      end
    
    # Add new item
    updated_cache = Map.put(state.cache, key, content)
    updated_access_times = Map.put(state.access_times, key, now)
    
    new_state = %{
      state |
      cache: updated_cache,
      access_times: updated_access_times,
      size: state.size + 1
    }
    
    {:noreply, new_state}
  end
  
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - @ttl_ms
    
    # Remove expired entries
    expired_keys = 
      state.access_times
      |> Enum.filter(fn {_key, access_time} -> access_time < cutoff end)
      |> Enum.map(fn {key, _time} -> key end)
    
    updated_cache = Map.drop(state.cache, expired_keys)
    updated_access_times = Map.drop(state.access_times, expired_keys)
    
    new_state = %{
      state |
      cache: updated_cache,
      access_times: updated_access_times,
      size: state.size - length(expired_keys)
    }
    
    {:noreply, new_state}
  end
  
  defp evict_lru_item(state) do
    # Find least recently used item
    {lru_key, _time} = Enum.min_by(state.access_times, fn {_key, time} -> time end)
    
    %{
      state |
      cache: Map.delete(state.cache, lru_key),
      access_times: Map.delete(state.access_times, lru_key),
      size: state.size - 1
    }
  end
end
```

### Memo Prefetching

```elixir
defmodule MemoPrefetcher do
  def prefetch_memo_blocks(dbt_file, record_stream) do
    # Analyze upcoming memo references
    memo_refs = 
      record_stream
      |> Stream.take(100)  # Look ahead 100 records
      |> Stream.flat_map(&extract_memo_refs/1)
      |> Stream.uniq()
      |> Enum.to_list()
    
    # Prefetch memo blocks in background
    Task.start(fn -> 
      batch_read_memo_blocks(dbt_file, memo_refs)
    end)
    
    record_stream
  end
  
  defp extract_memo_refs(record) do
    record
    |> Enum.filter(fn {_field, value} -> match?({:memo_ref, _}, value) end)
    |> Enum.map(fn {_field, {:memo_ref, block_num}} -> block_num end)
    |> Enum.filter(&(&1 > 0))
  end
  
  defp batch_read_memo_blocks(dbt_file, block_numbers) do
    # Group consecutive blocks for efficient reading
    block_numbers
    |> Enum.sort()
    |> group_consecutive_blocks()
    |> Enum.each(&read_block_range(dbt_file, &1))
  end
  
  defp group_consecutive_blocks(blocks) do
    blocks
    |> Enum.chunk_while(
      [],
      fn block, acc ->
        case acc do
          [] -> {:cont, [block]}
          [last | _] when block == last + 1 -> {:cont, [block | acc]}
          _ -> {:emit, Enum.reverse(acc), [block]}
        end
      end,
      fn acc -> {:emit, Enum.reverse(acc), []} end
    )
  end
  
  defp read_block_range(dbt_file, block_range) when length(block_range) > 1 do
    # Read multiple consecutive blocks in one operation
    first_block = List.first(block_range)
    block_count = length(block_range)
    
    case Xbase.DbtParser.read_memo_range(dbt_file, first_block, block_count) do
      {:ok, memo_contents} ->
        # Cache the prefetched content
        block_range
        |> Enum.zip(memo_contents)
        |> Enum.each(fn {block_num, content} ->
          MemoCache.cache_memo(dbt_file.file_path, block_num, content)
        end)
        
      {:error, reason} ->
        IO.puts("Prefetch failed: #{inspect(reason)}")
    end
  end
  
  defp read_block_range(dbt_file, [block_num]) do
    # Single block read
    case Xbase.DbtParser.read_memo(dbt_file, block_num) do
      {:ok, content} ->
        MemoCache.cache_memo(dbt_file.file_path, block_num, content)
      {:error, _reason} ->
        :ok  # Ignore prefetch failures
    end
  end
end
```

## Benchmarking and Profiling

### Performance Measurement

```elixir
defmodule PerformanceBenchmark do
  def benchmark_operations(file_path, operations \\ [:read, :search, :update]) do
    {:ok, dbf} = Xbase.Parser.open_dbf(file_path)
    
    results = 
      operations
      |> Enum.map(&benchmark_operation(dbf, &1))
      |> Map.new()
    
    Xbase.Parser.close_dbf(dbf)
    results
  end
  
  defp benchmark_operation(dbf, :read) do
    record_count = min(1000, dbf.header.record_count)
    indices = Enum.take_random(0..(dbf.header.record_count - 1), record_count)
    
    {time_micro, _results} = :timer.tc(fn ->
      Enum.map(indices, &Xbase.Parser.read_record(dbf, &1))
    end)
    
    {:read_performance, %{
      records_read: record_count,
      total_time_ms: time_micro / 1000,
      avg_time_per_record_ms: time_micro / 1000 / record_count,
      records_per_second: record_count * 1_000_000 / time_micro
    }}
  end
  
  defp benchmark_operation(dbf, :search) do
    # Benchmark linear search (stream_records/1 already skips deleted records)
    search_fn = fn record ->
      record["ID"] != nil
    end
    
    {time_micro, results} = :timer.tc(fn ->
      dbf
      |> Xbase.Parser.stream_records()
      |> Stream.filter(search_fn)
      |> Enum.count()
    end)
    
    {:search_performance, %{
      records_scanned: dbf.header.record_count,
      matches_found: results,
      total_time_ms: time_micro / 1000,
      records_per_second: dbf.header.record_count * 1_000_000 / time_micro
    }}
  end
  
  defp benchmark_operation(dbf, :update) do
    # Benchmark record updates
    update_count = min(100, dbf.header.record_count)
    indices = Enum.take_random(0..(dbf.header.record_count - 1), update_count)
    
    {time_micro, _results} = :timer.tc(fn ->
      Enum.map(indices, fn index ->
        Xbase.Parser.update_record(dbf, index, %{"UPDATED" => true})
      end)
    end)
    
    {:update_performance, %{
      records_updated: update_count,
      total_time_ms: time_micro / 1000,
      avg_time_per_update_ms: time_micro / 1000 / update_count,
      updates_per_second: update_count * 1_000_000 / time_micro
    }}
  end
end
```

### Profiling Tools

```elixir
defmodule ProfilerTools do
  def profile_memory_usage(operation_fn) do
    # Force garbage collection before measurement
    :erlang.garbage_collect()
    
    initial_memory = :erlang.memory()
    initial_processes = length(:erlang.processes())
    
    {time_micro, result} = :timer.tc(operation_fn)
    
    final_memory = :erlang.memory()
    final_processes = length(:erlang.processes())
    
    memory_diff = calculate_memory_difference(initial_memory, final_memory)
    
    profile = %{
      execution_time_ms: time_micro / 1000,
      memory_usage: memory_diff,
      process_count_change: final_processes - initial_processes,
      result: result
    }
    
    print_profile_report(profile)
    {result, profile}
  end
  
  defp calculate_memory_difference(initial, final) do
    %{
      total_change: final[:total] - initial[:total],
      processes_change: final[:processes] - initial[:processes],
      system_change: final[:system] - initial[:system],
      atom_change: final[:atom] - initial[:atom],
      binary_change: final[:binary] - initial[:binary],
      ets_change: final[:ets] - initial[:ets]
    }
  end
  
  defp print_profile_report(profile) do
    IO.puts("\n=== Performance Profile ===")
    IO.puts("Execution Time: #{Float.round(profile.execution_time_ms, 2)}ms")
    IO.puts("Total Memory Change: #{format_bytes(profile.memory_usage.total_change)}")
    IO.puts("Process Memory Change: #{format_bytes(profile.memory_usage.processes_change)}")
    IO.puts("System Memory Change: #{format_bytes(profile.memory_usage.system_change)}")
    IO.puts("Process Count Change: #{profile.process_count_change}")
    IO.puts("===========================\n")
  end
  
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes) when bytes < 1_073_741_824, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"
  
  def cpu_profile(operation_fn, duration_seconds \\ 10) do
    # Start CPU profiling
    :eprof.start()
    :eprof.start_profiling([self()])
    
    # Run the operation
    result = operation_fn.()
    
    # Stop profiling and analyze
    :eprof.stop_profiling()
    :eprof.analyze(:total)
    :eprof.stop()
    
    result
  end
end
```

## Production Optimization

### Configuration Tuning

```elixir
defmodule ProductionConfig do
  def optimize_for_environment(environment) do
    case environment do
      :development ->
        %{
          buffer_size: 8_192,          # 8KB - Small for quick testing
          cache_size: 100,             # Small cache
          parallel_workers: 2,         # Minimal parallelism
          prefetch_enabled: false      # Disable prefetching
        }
        
      :staging ->
        %{
          buffer_size: 32_768,         # 32KB
          cache_size: 500,             # Medium cache
          parallel_workers: 4,         # Moderate parallelism
          prefetch_enabled: true       # Enable prefetching
        }
        
      :production ->
        %{
          buffer_size: 65_536,         # 64KB - Optimal for most systems
          cache_size: 2000,            # Large cache
          parallel_workers: System.schedulers_online(),
          prefetch_enabled: true,
          compression_enabled: true,    # Enable compression for large files
          index_auto_creation: true     # Auto-create indexes for frequent queries
        }
    end
  end
  
  def apply_configuration(config) do
    # Configure application environment
    Application.put_env(:xbase, :buffer_size, config.buffer_size)
    Application.put_env(:xbase, :cache_size, config.cache_size)
    Application.put_env(:xbase, :parallel_workers, config.parallel_workers)
    Application.put_env(:xbase, :prefetch_enabled, config.prefetch_enabled)
    
    # Start performance-critical services
    {:ok, _} = MemoCache.start_link(cache_size: config.cache_size)
    {:ok, _} = LoadBalancer.start_link(config.parallel_workers)
    
    :ok
  end
end
```

### Monitoring and Alerting

```elixir
defmodule PerformanceMonitor do
  use GenServer
  
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end
  
  def record_operation(operation_type, duration_ms, metadata \\ %{}) do
    GenServer.cast(__MODULE__, {:record_operation, operation_type, duration_ms, metadata})
  end
  
  def get_performance_stats do
    GenServer.call(__MODULE__, :get_stats)
  end
  
  def init(_) do
    # Start metrics collection timer
    :timer.send_interval(60_000, self(), :collect_metrics)  # Every minute
    
    state = %{
      operations: %{},
      alerts: [],
      start_time: System.monotonic_time(:millisecond)
    }
    
    {:ok, state}
  end
  
  def handle_cast({:record_operation, operation_type, duration_ms, metadata}, state) do
    operations = Map.update(state.operations, operation_type, [], fn existing ->
      # Keep only last 1000 operations per type
      [%{duration: duration_ms, metadata: metadata, timestamp: System.monotonic_time(:millisecond)} | existing]
      |> Enum.take(1000)
    end)
    
    # Check for performance alerts
    alerts = check_performance_alerts(operation_type, duration_ms, state.alerts)
    
    {:noreply, %{state | operations: operations, alerts: alerts}}
  end
  
  def handle_call(:get_stats, _from, state) do
    stats = calculate_performance_stats(state.operations)
    {:reply, stats, state}
  end
  
  def handle_info(:collect_metrics, state) do
    # Collect system metrics
    memory_usage = :erlang.memory(:total)
    process_count = length(:erlang.processes())
    
    # Log performance metrics
    IO.puts("System Metrics - Memory: #{format_bytes(memory_usage)}, Processes: #{process_count}")
    
    {:noreply, state}
  end
  
  defp check_performance_alerts(operation_type, duration_ms, existing_alerts) do
    alert_thresholds = %{
      read_record: 100,      # Alert if read takes > 100ms
      search_records: 5000,  # Alert if search takes > 5s
      update_record: 200,    # Alert if update takes > 200ms
      append_record: 150     # Alert if append takes > 150ms
    }
    
    threshold = Map.get(alert_thresholds, operation_type, 1000)
    
    if duration_ms > threshold do
      alert = %{
        type: :performance_degradation,
        operation: operation_type,
        duration: duration_ms,
        threshold: threshold,
        timestamp: System.monotonic_time(:millisecond)
      }
      
      # Keep only recent alerts (last hour)
      cutoff = System.monotonic_time(:millisecond) - 3_600_000
      recent_alerts = Enum.filter(existing_alerts, fn alert -> alert.timestamp > cutoff end)
      
      [alert | recent_alerts]
    else
      existing_alerts
    end
  end
  
  defp calculate_performance_stats(operations) do
    operations
    |> Enum.map(fn {operation_type, operation_list} ->
      durations = Enum.map(operation_list, & &1.duration)
      
      stats = %{
        count: length(durations),
        avg_duration: average(durations),
        min_duration: Enum.min(durations, fn -> 0 end),
        max_duration: Enum.max(durations, fn -> 0 end),
        p95_duration: percentile(durations, 95),
        p99_duration: percentile(durations, 99)
      }
      
      {operation_type, stats}
    end)
    |> Map.new()
  end
  
  defp average([]), do: 0
  defp average(list), do: Enum.sum(list) / length(list)
  
  defp percentile([], _), do: 0
  defp percentile(list, percentile) do
    sorted = Enum.sort(list)
    index = trunc(length(sorted) * percentile / 100)
    Enum.at(sorted, index, 0)
  end
  
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end
```

This comprehensive performance guide provides the tools and techniques needed to optimize Xbase applications for any scale, from development environments to high-performance production systems.