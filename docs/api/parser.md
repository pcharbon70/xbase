# Xbase.Parser

The main module for DBF file operations, providing complete read/write functionality for dBase database files.

## Core Functions

### File Operations

#### `open_dbf(path, modes \\ [:read])`

Opens a DBF file for reading or writing.

**Parameters:**
- `path` - String path to the DBF file
- `modes` - List of file access modes (`:read`, `:write`)

**Returns:**
- `{:ok, dbf}` - Successfully opened file handle
- `{:error, reason}` - Error opening file

**Example:**
```elixir
{:ok, dbf} = Xbase.Parser.open_dbf("data.dbf")
{:ok, dbf} = Xbase.Parser.open_dbf("data.dbf", [:read, :write])
```

#### `create_dbf(path, fields, opts \\ [])`

Creates a new DBF file with specified field structure.

**Parameters:**
- `path` - String path for the new DBF file
- `fields` - List of `%FieldDescriptor{}` structs defining the schema
- `opts` - Options including `:version`, `:overwrite`

**Returns:**
- `{:ok, dbf}` - Successfully created file handle
- `{:error, reason}` - Error creating file

**Example:**
```elixir
fields = [
  %Xbase.Types.FieldDescriptor{name: "NAME", type: "C", length: 30},
  %Xbase.Types.FieldDescriptor{name: "AGE", type: "N", length: 3, decimal_count: 0}
]
{:ok, dbf} = Xbase.Parser.create_dbf("new.dbf", fields)
```

#### `close_dbf(dbf)`

Closes a DBF file handle and releases resources.

**Parameters:**
- `dbf` - DBF file handle from `open_dbf/2` or `create_dbf/3`

**Returns:**
- `:ok` - File closed successfully

### Record Reading

#### `read_record(dbf, index)`

Reads a single record by zero-based index.

**Parameters:**
- `dbf` - DBF file handle
- `index` - Zero-based record index

**Returns:**
- `{:ok, %Record{}}` - Successfully read record
- `{:error, reason}` - Error reading record

**Example:**
```elixir
{:ok, record} = Xbase.Parser.read_record(dbf, 0)
# => %Xbase.Types.Record{
#      data: %{"NAME" => "John Doe", "AGE" => 30}, 
#      deleted: false,
#      raw_data: "..."
#    }
```

#### `read_records(dbf)`

Reads all active (non-deleted) records from the DBF file.

**Parameters:**
- `dbf` - DBF file handle

**Returns:**
- `{:ok, [map()]}` - One field map per active record (not `%Record{}` structs)
- `{:error, reason}` - Error reading records

**Example:**
```elixir
{:ok, records} = Xbase.Parser.read_records(dbf)
# => [%{"NAME" => "John Doe", "AGE" => 30}, ...]
```

Use `read_record/2` when you need the deletion flag or raw data of a record.

#### `stream_records(dbf)`

Creates a lazy stream of active (non-deleted) records for memory-efficient
processing.

**Parameters:**
- `dbf` - DBF file handle

**Returns:**
- `Stream.t()` - Lazy stream of field maps (not `%Record{}` structs)

**Example:**
```elixir
dbf
|> Xbase.Parser.stream_records()
|> Stream.filter(fn record -> record["AGE"] > 25 end)
|> Stream.map(fn record -> record["NAME"] end)
|> Enum.take(10)
```

### Record Writing

#### `append_record(dbf, data)`

Appends a new record to the end of the DBF file.

**Parameters:**
- `dbf` - DBF file handle (opened with write access)
- `data` - Map of field names to values

**Returns:**
- `{:ok, updated_dbf}` - Updated file handle
- `{:error, reason}` - Error appending record

**Example:**
```elixir
{:ok, dbf} = Xbase.Parser.append_record(dbf, %{
  "NAME" => "Jane Smith",
  "AGE" => 28
})
```

#### `update_record(dbf, index, data)`

Updates an existing record at the specified index.

**Parameters:**
- `dbf` - DBF file handle (opened with write access)
- `index` - Zero-based record index
- `data` - Map of field names to new values (partial updates supported)

**Returns:**
- `{:ok, updated_dbf}` - Updated file handle
- `{:error, reason}` - Error updating record

**Example:**
```elixir
{:ok, dbf} = Xbase.Parser.update_record(dbf, 0, %{"AGE" => 29})
```

### Record Deletion

#### `mark_deleted(dbf, index)`

Marks a record as deleted without removing it from the file.

**Parameters:**
- `dbf` - DBF file handle (opened with write access)
- `index` - Zero-based record index

**Returns:**
- `{:ok, updated_dbf}` - Updated file handle
- `{:error, reason}` - Error marking record

#### `undelete_record(dbf, index)`

Restores a previously deleted record.

**Parameters:**
- `dbf` - DBF file handle (opened with write access)  
- `index` - Zero-based record index

**Returns:**
- `{:ok, updated_dbf}` - Updated file handle
- `{:error, reason}` - Error undeleting record

#### `pack(dbf, output_path)`

Creates a compacted copy of the DBF file with deleted records removed.

**Parameters:**
- `dbf` - DBF file handle
- `output_path` - Path for the compacted file

**Returns:**
- `{:ok, new_dbf}` - Handle to the compacted file
- `{:error, reason}` - Error packing file

### Batch Operations

#### `batch_append_records(dbf, records)`

Efficiently appends multiple records in a single operation.

**Parameters:**
- `dbf` - DBF file handle (opened with write access)
- `records` - List of record data maps

**Returns:**
- `{:ok, updated_dbf}` - Updated file handle
- `{:error, reason}` - Error in batch operation

#### `batch_update_records(dbf, updates)`

Updates multiple records efficiently.

**Parameters:**
- `dbf` - DBF file handle (opened with write access)
- `updates` - List of `{index, data}` tuples

**Returns:**
- `{:ok, updated_dbf}` - Updated file handle
- `{:error, reason}` - Error in batch operation

#### `batch_delete(dbf, indices)`

Marks multiple records as deleted.

**Parameters:**
- `dbf` - DBF file handle (opened with write access)
- `indices` - List of zero-based record indices

**Returns:**
- `{:ok, updated_dbf}` - Updated file handle
- `{:error, reason}` - Error in batch operation

### Transactions

#### `with_transaction(dbf, transaction_fn)`

Executes a function within a transaction with automatic rollback on failure.

**Parameters:**
- `dbf` - DBF file handle (opened with write access)
- `transaction_fn` - Function that receives the DBF handle and returns `{:ok, result}` or `{:error, reason}`

**Returns:**
- `{:ok, result}` - Transaction succeeded
- `{:error, reason}` - Transaction failed and was rolled back

**Example:**
```elixir
{:ok, result} = Xbase.Parser.with_transaction(dbf, fn dbf ->
  {:ok, dbf} = Xbase.Parser.append_record(dbf, record1)
  {:ok, dbf} = Xbase.Parser.append_record(dbf, record2)
  {:ok, :success}
end)
```

### Utility Functions

#### `count_records(dbf)`

Returns the total number of records in the file.

#### `count_active_records(dbf)`

Returns the number of non-deleted records.

#### `count_deleted_records(dbf)`

Returns the number of deleted records.

#### `record_statistics(dbf)`

Returns comprehensive statistics about the file.

## Error Codes

- `:enoent` - File not found
- `:invalid_record_index` - Index out of bounds
- `:invalid_field_type` - Unsupported field type
- `:field_too_large` - Data too large for field
- `:invalid_header_size` - Corrupted file header
- `:file_not_writable` - File opened read-only