defmodule Xbase.CodePage do
  @moduledoc """
  Converts text between a DBF table's code page and UTF-8.

  The code page is identified by the language driver byte at offset 29 of the
  DBF header. Supported code pages:

  | Byte          | Encoding     |
  | ------------- | ------------ |
  | `0x03`, `0x57` | Windows-1252 |
  | `0x01`        | DOS 437      |
  | `0x02`        | DOS 850      |

  Any other byte (including `0x00`, "no code page") maps to `:raw`, which
  leaves bytes untouched.
  """

  @type encoding :: :raw | :cp1252 | :cp437 | :cp850

  @encodings [:raw, :cp1252, :cp437, :cp850]

  # Unicode code points for bytes 0x80..0xFF. Bytes that a code page leaves
  # undefined map to the code point of the same value, so decoding is lossless.
  @cp1252 ~w(
    20AC 0081 201A 0192 201E 2026 2020 2021
    02C6 2030 0160 2039 0152 008D 017D 008F
    0090 2018 2019 201C 201D 2022 2013 2014
    02DC 2122 0161 203A 0153 009D 017E 0178
    00A0 00A1 00A2 00A3 00A4 00A5 00A6 00A7
    00A8 00A9 00AA 00AB 00AC 00AD 00AE 00AF
    00B0 00B1 00B2 00B3 00B4 00B5 00B6 00B7
    00B8 00B9 00BA 00BB 00BC 00BD 00BE 00BF
    00C0 00C1 00C2 00C3 00C4 00C5 00C6 00C7
    00C8 00C9 00CA 00CB 00CC 00CD 00CE 00CF
    00D0 00D1 00D2 00D3 00D4 00D5 00D6 00D7
    00D8 00D9 00DA 00DB 00DC 00DD 00DE 00DF
    00E0 00E1 00E2 00E3 00E4 00E5 00E6 00E7
    00E8 00E9 00EA 00EB 00EC 00ED 00EE 00EF
    00F0 00F1 00F2 00F3 00F4 00F5 00F6 00F7
    00F8 00F9 00FA 00FB 00FC 00FD 00FE 00FF
  )
          |> Enum.map(&String.to_integer(&1, 16))
          |> List.to_tuple()

  @cp437 ~w(
    00C7 00FC 00E9 00E2 00E4 00E0 00E5 00E7
    00EA 00EB 00E8 00EF 00EE 00EC 00C4 00C5
    00C9 00E6 00C6 00F4 00F6 00F2 00FB 00F9
    00FF 00D6 00DC 00A2 00A3 00A5 20A7 0192
    00E1 00ED 00F3 00FA 00F1 00D1 00AA 00BA
    00BF 2310 00AC 00BD 00BC 00A1 00AB 00BB
    2591 2592 2593 2502 2524 2561 2562 2556
    2555 2563 2551 2557 255D 255C 255B 2510
    2514 2534 252C 251C 2500 253C 255E 255F
    255A 2554 2569 2566 2560 2550 256C 2567
    2568 2564 2565 2559 2558 2552 2553 256B
    256A 2518 250C 2588 2584 258C 2590 2580
    03B1 00DF 0393 03C0 03A3 03C3 00B5 03C4
    03A6 0398 03A9 03B4 221E 03C6 03B5 2229
    2261 00B1 2265 2264 2320 2321 00F7 2248
    00B0 2219 00B7 221A 207F 00B2 25A0 00A0
  )
         |> Enum.map(&String.to_integer(&1, 16))
         |> List.to_tuple()

  @cp850 ~w(
    00C7 00FC 00E9 00E2 00E4 00E0 00E5 00E7
    00EA 00EB 00E8 00EF 00EE 00EC 00C4 00C5
    00C9 00E6 00C6 00F4 00F6 00F2 00FB 00F9
    00FF 00D6 00DC 00F8 00A3 00D8 00D7 0192
    00E1 00ED 00F3 00FA 00F1 00D1 00AA 00BA
    00BF 00AE 00AC 00BD 00BC 00A1 00AB 00BB
    2591 2592 2593 2502 2524 00C1 00C2 00C0
    00A9 2563 2551 2557 255D 00A2 00A5 2510
    2514 2534 252C 251C 2500 253C 00E3 00C3
    255A 2554 2569 2566 2560 2550 256C 00A4
    00F0 00D0 00CA 00CB 00C8 0131 00CD 00CE
    00CF 2518 250C 2588 2584 00A6 00CC 2580
    00D3 00DF 00D4 00D2 00F5 00D5 00B5 00FE
    00DE 00DA 00DB 00D9 00FD 00DD 00AF 00B4
    00AD 00B1 2017 00BE 00B6 00A7 00F7 00B8
    00B0 00A8 00B7 00B9 00B3 00B2 25A0 00A0
  )
         |> Enum.map(&String.to_integer(&1, 16))
         |> List.to_tuple()

  @doc "Returns the encodings that `decode/2` and `encode/2` accept."
  @spec encodings() :: [encoding()]
  def encodings, do: @encodings

  @doc """
  Returns the encoding for a DBF header language driver byte.

      iex> Xbase.CodePage.from_language_driver(0x03)
      :cp1252
      iex> Xbase.CodePage.from_language_driver(0x00)
      :raw
  """
  @spec from_language_driver(integer() | nil) :: encoding()
  def from_language_driver(0x03), do: :cp1252
  def from_language_driver(0x57), do: :cp1252
  def from_language_driver(0x01), do: :cp437
  def from_language_driver(0x02), do: :cp850
  def from_language_driver(_), do: :raw

  @doc """
  Decodes bytes stored in `encoding` into a UTF-8 string.

      iex> Xbase.CodePage.decode(<<"Qu", 0xE9, "bec">>, :cp1252)
      "Québec"
  """
  @spec decode(binary(), encoding()) :: binary()
  def decode(binary, :raw), do: binary

  def decode(binary, encoding) do
    table = table(encoding)

    for <<byte <- binary>>, into: "" do
      if byte < 0x80, do: <<byte>>, else: <<elem(table, byte - 0x80)::utf8>>
    end
  end

  @doc """
  Encodes a UTF-8 string into `encoding`.

  Returns `{:error, {:unencodable, char}}` for a character the code page cannot
  represent.

      iex> Xbase.CodePage.encode("Québec", :cp1252)
      {:ok, <<"Qu", 0xE9, "bec">>}
  """
  @spec encode(binary(), encoding()) :: {:ok, binary()} | {:error, {:unencodable, binary()}}
  def encode(string, :raw), do: {:ok, string}

  def encode(string, encoding) do
    reverse = reverse_table(encoding)

    string
    |> String.codepoints()
    |> Enum.reduce_while({:ok, []}, fn char, {:ok, acc} ->
      case encode_char(char, reverse) do
        {:ok, byte} -> {:cont, {:ok, [byte | acc]}}
        :error -> {:halt, {:error, {:unencodable, char}}}
      end
    end)
    |> case do
      {:ok, bytes} -> {:ok, bytes |> Enum.reverse() |> IO.iodata_to_binary()}
      error -> error
    end
  end

  defp encode_char(<<code_point::utf8>>, _reverse) when code_point < 0x80, do: {:ok, code_point}

  defp encode_char(<<code_point::utf8>>, reverse) do
    case Map.fetch(reverse, code_point) do
      {:ok, byte} -> {:ok, byte}
      :error -> :error
    end
  end

  # Not valid UTF-8: pass the byte through unchanged.
  defp encode_char(<<byte>>, _reverse), do: {:ok, byte}
  defp encode_char(_char, _reverse), do: :error

  defp table(:cp1252), do: @cp1252
  defp table(:cp437), do: @cp437
  defp table(:cp850), do: @cp850

  for encoding <- [:cp1252, :cp437, :cp850] do
    reverse =
      encoding
      |> then(&Module.get_attribute(__MODULE__, &1))
      |> Tuple.to_list()
      |> Enum.with_index(0x80)
      |> Map.new()

    defp reverse_table(unquote(encoding)), do: unquote(Macro.escape(reverse))
  end
end
