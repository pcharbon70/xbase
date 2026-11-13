defmodule Xbase.RecordShapeTest do
  @moduledoc """
  Pins the element shape returned by read_record/2, read_records/1 and
  stream_records/1 (see notes/fixes/003-read-records-return-shape.md).
  """
  use ExUnit.Case, async: true

  alias Xbase.Parser
  alias Xbase.Types.{FieldDescriptor, Record}

  setup do
    path =
      Path.join(System.tmp_dir!(), "xbase_record_shape_#{System.unique_integer([:positive])}.dbf")

    fields = [%FieldDescriptor{name: "NAME", type: "C", length: 10, decimal_count: 0}]
    {:ok, dbf} = Parser.create_dbf(path, fields)
    {:ok, dbf} = Parser.append_record(dbf, %{"NAME" => "Kept"})
    {:ok, dbf} = Parser.append_record(dbf, %{"NAME" => "Deleted"})
    {:ok, dbf} = Parser.mark_deleted(dbf, 1)

    on_exit(fn ->
      Parser.close_dbf(dbf)
      File.rm(path)
    end)

    %{dbf: dbf}
  end

  test "read_record/2 returns a Record struct, including deleted records", %{dbf: dbf} do
    assert {:ok, %Record{data: %{"NAME" => "Kept"}, deleted: false}} = Parser.read_record(dbf, 0)

    assert {:ok, %Record{data: %{"NAME" => "Deleted"}, deleted: true}} =
             Parser.read_record(dbf, 1)
  end

  test "read_records/1 returns plain field maps for active records only", %{dbf: dbf} do
    assert {:ok, [%{"NAME" => "Kept"} = record]} = Parser.read_records(dbf)
    refute is_struct(record)
  end

  test "stream_records/1 yields plain field maps for active records only", %{dbf: dbf} do
    assert [%{"NAME" => "Kept"} = record] = dbf |> Parser.stream_records() |> Enum.to_list()
    refute is_struct(record)
  end
end
