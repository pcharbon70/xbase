defmodule Xbase.FieldParser do
  @moduledoc """
  Field parser for DBF data types.
  
  This module provides parsing functionality for different DBF field types,
  converting binary data to appropriate Elixir types based on field descriptors.
  """

  alias Xbase.Types.FieldDescriptor

  @doc """
  Parses field data based on the field descriptor.
  
  ## Parameters
  - `field_desc` - The field descriptor containing type and length information
  - `binary_data` - The raw binary data for this field
  
  ## Returns
  - `{:ok, parsed_value}` - Successfully parsed value
  - `{:error, reason}` - Parse error with reason
  
  ## Examples
      iex> field_desc = %FieldDescriptor{type: "C", length: 10}
      iex> Xbase.FieldParser.parse(field_desc, "John Doe  ")
      {:ok, "John Doe"}
  """
  def parse(%FieldDescriptor{type: "C"} = _field_desc, binary_data) do
    # Character field: trim trailing spaces
    trimmed = String.trim_trailing(binary_data)
    {:ok, trimmed}
  end

  def parse(%FieldDescriptor{type: "N", decimal_count: 0} = _field_desc, binary_data) do
    # Numeric field (integer)
    trimmed = String.trim(binary_data)
    
    case trimmed do
      "" -> {:ok, nil}  # Empty field
      "*" <> _ -> {:ok, nil}  # Overflow/invalid value represented as asterisks
      _ ->
        case Integer.parse(trimmed) do
          {value, ""} -> {:ok, value}
          _ -> {:error, :invalid_numeric}
        end
    end
  end

  def parse(%FieldDescriptor{type: "N", decimal_count: decimal_count} = _field_desc, binary_data) 
      when decimal_count > 0 do
    # Numeric field (decimal)
    trimmed = String.trim(binary_data)
    
    case trimmed do
      "" -> {:ok, nil}  # Empty field
      "*" <> _ -> {:ok, nil}  # Overflow/invalid value represented as asterisks
      _ ->
        case Float.parse(trimmed) do
          {value, ""} -> {:ok, value}
          _ -> {:error, :invalid_numeric}
        end
    end
  end

  def parse(%FieldDescriptor{type: "D"} = _field_desc, binary_data) do
    # Date field: YYYYMMDD format
    trimmed = String.trim(binary_data)
    
    case trimmed do
      "" -> {:ok, nil}  # Empty field
      <<year::binary-size(4), month::binary-size(2), day::binary-size(2)>> ->
        case {Integer.parse(year), Integer.parse(month), Integer.parse(day)} do
          {{y, ""}, {m, ""}, {d, ""}} ->
            case Date.new(y, m, d) do
              {:ok, date} -> {:ok, date}
              {:error, _} -> {:error, :invalid_date}
            end
          _ -> {:error, :invalid_date}
        end
      _ -> {:error, :invalid_date}
    end
  end

  def parse(%FieldDescriptor{type: "L"} = _field_desc, binary_data) do
    # Logical field: T/F, Y/N, or ?
    case String.upcase(String.trim(binary_data)) do
      "T" -> {:ok, true}
      "Y" -> {:ok, true}
      "F" -> {:ok, false}
      "N" -> {:ok, false}
      "?" -> {:ok, nil}
      "" -> {:ok, nil}  # Empty/space treated as unknown
      _ -> {:ok, nil}   # Any other value treated as unknown
    end
  end

  def parse(%FieldDescriptor{type: type, length: 4} = _field_desc, binary_data)
      when type in ["M", "G"] do
    # Visual FoxPro memo (M) and general (G) fields: 4-byte little-endian
    # block number in the FPT file; 0 means no memo.
    case binary_data do
      <<0::little-32>> -> {:ok, nil}
      <<block_number::little-32>> -> {:ok, {:memo_ref, block_number}}
      _ -> {:error, :invalid_memo_reference}
    end
  end

  def parse(%FieldDescriptor{type: "M"} = _field_desc, binary_data) do
    # Memo field: reference to memo block
    trimmed = String.trim(binary_data)
    
    case trimmed do
      "" -> {:ok, nil}  # Empty memo reference
      _ ->
        case Integer.parse(trimmed) do
          {block_number, ""} -> {:ok, {:memo_ref, block_number}}
          _ -> {:ok, nil}  # Invalid memo reference treated as empty
        end
    end
  end

  def parse(%FieldDescriptor{type: "I", length: 4} = _field_desc, binary_data) do
    # Visual FoxPro integer: always a 4-byte little-endian signed integer.
    # Its bytes can look like text (for example "   1"), so never parse as text.
    case binary_data do
      <<value::little-signed-32>> -> {:ok, value}
      _ -> {:error, :invalid_integer_size}
    end
  end

  def parse(%FieldDescriptor{type: "I"} = _field_desc, binary_data) do
    # Integer field: In dBase III format, often stored as text string (right-aligned)
    # Try text parsing first, then binary if that fails
    trimmed = String.trim(binary_data)
    
    case trimmed do
      "" -> {:ok, nil}  # Empty field
      _ ->
        case Integer.parse(trimmed) do
          {value, ""} -> {:ok, value}
          _ -> 
            # If text parsing fails, try binary format (4-byte little-endian)
            case byte_size(binary_data) do
              4 ->
                <<value::little-signed-32>> = binary_data
                {:ok, value}
              _ ->
                {:error, :invalid_integer_size}
            end
        end
    end
  end

  def parse(%FieldDescriptor{type: "T"} = _field_desc, binary_data) do
    # DateTime field: In dBase III, often stored as text. Try multiple formats.
    trimmed = String.trim(binary_data)
    
    case trimmed do
      "" -> {:ok, nil}  # Empty field
      _ ->
        # Try text parsing first (common in dBase III)
        case parse_datetime_text(trimmed) do
          {:ok, datetime} -> {:ok, datetime}
          {:error, :truncated_datetime} -> {:ok, nil}  # Treat truncated as null
          {:error, _} ->
            # If text parsing fails, try binary format (8-byte Julian day + milliseconds)
            case byte_size(binary_data) do
              8 ->
                <<julian_day::little-32, milliseconds::little-32>> = binary_data
                
                # Handle empty/null datetime (often represented as all zeros)
                case {julian_day, milliseconds} do
                  {0, 0} -> {:ok, nil}
                  _ ->
                    # Convert Julian day to date
                    case julian_to_date(julian_day) do
                      {:ok, date} ->
                        # Convert milliseconds to time
                        case milliseconds_to_time(milliseconds) do
                          {:ok, time} ->
                            # Combine date and time into datetime
                            case DateTime.new(date, time, "Etc/UTC") do
                              {:ok, datetime} -> {:ok, datetime}
                              {:error, _} -> {:error, :invalid_datetime}
                            end
                          {:error, _reason} -> {:ok, nil}  # Treat invalid time as null
                        end
                      {:error, _reason} -> {:ok, nil}  # Treat invalid date as null
                    end
                end
              _ ->
                {:error, :invalid_datetime_size}
            end
        end
    end
  end

  def parse(%FieldDescriptor{type: "Y"} = _field_desc, binary_data) do
    # Visual FoxPro currency: 8-byte little-endian signed integer holding the
    # amount multiplied by 10,000. Returned as an exact Decimal with 4 places.
    case binary_data do
      <<value::little-signed-64>> -> {:ok, Decimal.new(sign(value), abs(value), -4)}
      _ -> {:error, :invalid_currency_size}
    end
  end

  def parse(%FieldDescriptor{type: "B"} = _field_desc, binary_data) do
    # Visual FoxPro double: 8-byte little-endian IEEE 754 float.
    case binary_data do
      <<value::little-float-64>> -> {:ok, value}
      _ -> {:error, :invalid_double_size}
    end
  end

  def parse(%FieldDescriptor{type: "0"} = _field_desc, binary_data) do
    # Visual FoxPro _NullFlags system field: a bit mask, returned as raw bytes.
    {:ok, binary_data}
  end

  def parse(%FieldDescriptor{type: _type} = _field_desc, _binary_data) do
    # Unknown field type
    {:error, :unknown_field_type}
  end

  defp sign(value) when value < 0, do: -1
  defp sign(_value), do: 1

  # Helper function to convert Julian day number to date
  defp julian_to_date(julian_day) do
    # Julian day calculation based on astronomical Julian day
    # This handles the conversion from Julian day number to Gregorian calendar
    try do
      # Algorithm from "Astronomical Algorithms" by Jean Meeus
      a = julian_day + 32044
      b = div(4 * a + 3, 146097)
      c = a - div(146097 * b, 4)
      d = div(4 * c + 3, 1461)
      e = c - div(1461 * d, 4)
      m = div(5 * e + 2, 153)
      
      day = e - div(153 * m + 2, 5) + 1
      month = m + 3 - 12 * div(m, 10)
      year = 100 * b + d - 4800 + div(m, 10)
      
      Date.new(year, month, day)
    rescue
      _ -> {:error, :invalid_julian_day}
    end
  end

  # Helper function to convert milliseconds since midnight to time
  defp milliseconds_to_time(milliseconds) do
    # Ensure milliseconds is within valid range (0 to 86399999 for 24 hours)
    if milliseconds >= 0 and milliseconds < 86_400_000 do
      total_seconds = div(milliseconds, 1000)
      remaining_milliseconds = rem(milliseconds, 1000)
      
      hours = div(total_seconds, 3600)
      minutes = div(rem(total_seconds, 3600), 60)
      seconds = rem(total_seconds, 60)
      
      # Convert milliseconds to microseconds for Time.new/4
      microseconds = remaining_milliseconds * 1000
      
      Time.new(hours, minutes, seconds, microseconds)
    else
      {:error, :invalid_time_milliseconds}
    end
  end

  # Helper function to parse datetime from text format
  defp parse_datetime_text(text) do
    # Common datetime text formats in DBF files:
    # YYYYMMDD - Date only
    # YYYYMMDDHHMMSS - Full datetime
    # Various timestamp formats
    
    # Check if the text contains only numeric characters (and spaces)
    clean_text = String.replace(text, " ", "")
    if String.match?(clean_text, ~r/^\d*$/) and String.length(clean_text) > 0 do
      case String.length(clean_text) do
        8 ->
          # YYYYMMDD format (date only)
          case clean_text do
            <<year::binary-size(4), month::binary-size(2), day::binary-size(2)>> ->
              case {Integer.parse(year), Integer.parse(month), Integer.parse(day)} do
                {{y, ""}, {m, ""}, {d, ""}} when y > 1900 and y < 3000 and m >= 1 and m <= 12 and d >= 1 and d <= 31 ->
                  case Date.new(y, m, d) do
                    {:ok, date} -> 
                      # Convert to datetime at midnight UTC
                      case DateTime.new(date, ~T[00:00:00], "Etc/UTC") do
                        {:ok, datetime} -> {:ok, datetime}
                        {:error, _} -> {:error, :invalid_date}
                      end
                    {:error, _} -> {:error, :invalid_date}
                  end
                _ -> {:error, :invalid_date_format}
              end
            _ -> {:error, :invalid_date_format}
          end
        
        14 ->
          # YYYYMMDDHHMMSS format (full datetime)
          case clean_text do
            <<year::binary-size(4), month::binary-size(2), day::binary-size(2), 
              hour::binary-size(2), minute::binary-size(2), second::binary-size(2)>> ->
              case {Integer.parse(year), Integer.parse(month), Integer.parse(day),
                    Integer.parse(hour), Integer.parse(minute), Integer.parse(second)} do
                {{y, ""}, {m, ""}, {d, ""}, {h, ""}, {min, ""}, {s, ""}} when 
                  y > 1900 and y < 3000 and m >= 1 and m <= 12 and d >= 1 and d <= 31 and
                  h >= 0 and h <= 23 and min >= 0 and min <= 59 and s >= 0 and s <= 59 ->
                  case NaiveDateTime.new(y, m, d, h, min, s) do
                    {:ok, naive_datetime} -> 
                      # Convert to UTC datetime
                      case DateTime.from_naive(naive_datetime, "Etc/UTC") do
                        {:ok, datetime} -> {:ok, datetime}
                        {:error, _} -> {:error, :invalid_datetime}
                      end
                    {:error, _} -> {:error, :invalid_datetime}
                  end
                _ -> {:error, :invalid_datetime_format}
              end
            _ -> {:error, :invalid_datetime_format}
          end
        
        n when n in [5, 6, 7] ->
          # Partial/truncated dates - treat as invalid but don't crash
          {:error, :truncated_datetime}
        
        _ ->
          # Other numeric formats - might be timestamps or other formats
          {:error, :unsupported_datetime_format}
      end
    else
      # Non-numeric or empty content
      {:error, :invalid_datetime_format}
    end
  end
end