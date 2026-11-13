defmodule Xbase.Types do
  @moduledoc """
  Data structures for DBF file format components.
  """

  defmodule Header do
    @moduledoc """
    DBF file header structure containing metadata about the database file.
    
    The header is a 32-byte structure at the beginning of every DBF file.
    """
    
    defstruct [
      :version,           # File type flag (dBase version)
      :last_update_year,  # Year of last update (0-99, add 1900)
      :last_update_month, # Month of last update (1-12)
      :last_update_day,   # Day of last update (1-31)
      :record_count,      # Number of records in file
      :header_length,     # Number of bytes in header
      :record_length,     # Number of bytes in record
      :transaction_flag,  # Transaction flag
      :encryption_flag,   # Encryption flag
      :mdx_flag,         # MDX flag
      :language_driver   # Language driver ID
    ]

    @type t :: %__MODULE__{
      version: integer(),
      last_update_year: integer(),
      last_update_month: integer(),
      last_update_day: integer(),
      record_count: non_neg_integer(),
      header_length: pos_integer(),
      record_length: pos_integer(),
      transaction_flag: integer(),
      encryption_flag: integer(),
      mdx_flag: integer(),
      language_driver: integer()
    }
  end

  defmodule FieldDescriptor do
    @moduledoc """
    DBF field descriptor structure defining individual field properties.
    
    Each field descriptor is a 32-byte structure describing one field in the database.
    """
    
    defstruct [
      :name,              # Field name (11 bytes, null-terminated)
      :type,              # Field type (C, N, D, L, M, etc.)
      :length,            # Field length in bytes
      :decimal_count,     # Number of decimal places for numeric fields
      :work_area_id,      # Work area ID
      :set_fields_flag,   # SET FIELDS flag
      :index_field_flag   # Index field flag
    ]

    @type t :: %__MODULE__{
      name: String.t(),
      type: String.t(),
      length: pos_integer(),
      decimal_count: non_neg_integer(),
      work_area_id: integer(),
      set_fields_flag: integer(),
      index_field_flag: integer()
    }
  end

  defmodule Record do
    @moduledoc """
    DBF record structure containing parsed field data and metadata.
    
    Represents a single record from a DBF file with parsed field values,
    deletion status, and raw binary data for debugging purposes.
    """
    
    defstruct [
      :data,      # Map of field_name => parsed_value
      :deleted,   # Boolean indicating if record is deleted
      :raw_data   # Original binary data for debugging
    ]

    @type t :: %__MODULE__{
      data: %{String.t() => any()},
      deleted: boolean(),
      raw_data: binary()
    }
  end

  defmodule DbtHeader do
    @moduledoc """
    DBT (memo) file header structure containing metadata about memo storage.
    
    The header is a 512-byte structure at the beginning of every DBT file,
    containing information about block allocation and format version.
    """
    
    defstruct [
      :next_block,    # Next available block number for allocation
      :block_size,    # Size of each memo block in bytes (typically 512)
      :version        # DBT format version (:dbase_iii or :dbase_iv)
    ]

    @type t :: %__MODULE__{
      next_block: non_neg_integer(),
      block_size: pos_integer(),
      version: :dbase_iii | :dbase_iv
    }
  end

  defmodule FptFile do
    @moduledoc """
    An opened Visual FoxPro FPT memo file (read-only).
    """

    defstruct [
      :file,       # File handle from :file.open
      :file_path,  # Path to the FPT file
      :next_block, # Next free block number from the header
      :block_size  # Block size in bytes from the header
    ]

    @type t :: %__MODULE__{
      file: :file.io_device(),
      file_path: String.t(),
      next_block: non_neg_integer(),
      block_size: pos_integer()
    }
  end

  defmodule DbtFile do
    @moduledoc """
    DBT file structure containing header information and file handle.
    
    Represents an opened DBT memo file with parsed header and file descriptor
    for reading memo content blocks.
    """
    
    defstruct [
      :header,    # DbtHeader structure
      :file,      # File handle from :file.open
      :file_path  # Path to the DBT file
    ]

    @type t :: %__MODULE__{
      header: DbtHeader.t(),
      file: :file.io_device(),
      file_path: String.t()
    }
  end

  defmodule CdxHeader do
    @moduledoc """
    CDX index file header structure containing metadata about the index file.
    
    The header is a 512-byte structure at the beginning of every CDX file,
    containing information about the B-tree root and index configuration.
    """
    
    defstruct [
      :root_node,         # Pointer to root node (page number)
      :free_list,         # Pointer to free list (-1 if empty)
      :version,           # Version number
      :key_length,        # Length of index key
      :index_options,     # Index options flags
      :signature,         # Index signature
      :sort_order,        # Sort order specification
      :total_expr_len,    # Total expression length
      :for_expr_len,      # FOR expression length
      :key_expr_len,      # Key expression length
      :key_expression,    # Key expression string
      :for_expression     # FOR expression string (optional)
    ]

    @type t :: %__MODULE__{
      root_node: non_neg_integer(),
      free_list: integer(),
      version: non_neg_integer(),
      key_length: pos_integer(),
      index_options: integer(),
      signature: integer(),
      sort_order: integer(),
      total_expr_len: non_neg_integer(),
      for_expr_len: non_neg_integer(),
      key_expr_len: non_neg_integer(),
      key_expression: String.t(),
      for_expression: String.t() | nil
    }
  end

  defmodule CdxNode do
    @moduledoc """
    CDX B-tree node structure representing a page in the index tree.
    
    Each node is 512 bytes and can be a root, branch, or leaf node
    containing keys and pointers for B-tree navigation.
    """
    
    defstruct [
      :attributes,        # Node attributes (root/branch/leaf flags)
      :key_count,         # Number of keys in this node
      :left_brother,      # Pointer to left brother node (-1 if none)
      :keys,              # List of keys in this node
      :pointers,          # List of pointers (to child nodes or records)
      :node_type          # :root, :branch, or :leaf
    ]

    @type t :: %__MODULE__{
      attributes: integer(),
      key_count: non_neg_integer(),
      left_brother: integer(),
      keys: [binary()],
      pointers: [integer()],
      node_type: :root | :branch | :leaf
    }
  end

  defmodule CdxFile do
    @moduledoc """
    CDX file structure containing header information and file handle.
    
    Represents an opened CDX index file with parsed header and file descriptor
    for reading B-tree nodes and performing index operations.
    """
    
    defstruct [
      :header,      # CdxHeader structure
      :file,        # File handle from :file.open
      :file_path,   # Path to the CDX file
      :page_cache   # ETS table for caching frequently accessed pages
    ]

    @type t :: %__MODULE__{
      header: CdxHeader.t(),
      file: :file.io_device(),
      file_path: String.t(),
      page_cache: :ets.tid() | nil
    }
  end

  defmodule IndexKey do
    @moduledoc """
    Index key structure representing a key-value pair in a CDX index.
    
    Contains the index key data and associated record pointer for
    B-tree operations and record lookups.
    """
    
    defstruct [
      :key_data,      # Binary key data
      :record_number, # Record number this key points to
      :key_type      # Type of key (:character, :numeric, :date, :logical)
    ]

    @type t :: %__MODULE__{
      key_data: binary(),
      record_number: non_neg_integer(),
      key_type: :character | :numeric | :date | :logical
    }
  end
end