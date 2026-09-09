defmodule Core.Mq.Stream.BufferTest do
  use ExUnit.Case, async: true

  alias Core.Mq.Stream.Buffer

  test "кредит возвращается на последней записи чанка" do
    {buffer, credits} = Buffer.put_chunk(Buffer.new(), entries(0, 2))

    assert credits == 0
    assert Buffer.len(buffer) == 2
    assert Buffer.remaining(buffer) == 2

    assert {:ok, {0, "e0"}, buffer, 0} = Buffer.take(buffer)
    assert {:ok, {1, "e1"}, buffer, 1} = Buffer.take(buffer)
    assert Buffer.len(buffer) == 0
    assert Buffer.remaining(buffer) == 0
  end

  test "чанк без записей кредитуется сразу" do
    assert {buffer, 1} = Buffer.put_chunk(Buffer.new(), [])
    assert Buffer.len(buffer) == 0
  end

  test "следующие чанки ждут своей очереди, кредит — за каждый" do
    {buffer, 0} = Buffer.put_chunk(Buffer.new(), entries(0, 2))
    {buffer, 0} = Buffer.put_chunk(buffer, entries(2, 3))

    assert Buffer.remaining(buffer) == 2
    assert Buffer.len(buffer) == 5

    {:ok, _entry, buffer, 0} = Buffer.take(buffer)
    {:ok, _entry, buffer, 1} = Buffer.take(buffer)

    # Кредит за первый чанк выдан, счётчик переехал на второй.
    assert Buffer.remaining(buffer) == 3

    {:ok, _entry, buffer, 0} = Buffer.take(buffer)
    {:ok, _entry, buffer, 0} = Buffer.take(buffer)

    assert {:ok, {4, "e4"}, buffer, 1} = Buffer.take(buffer)
    assert Buffer.remaining(buffer) == 0
  end

  test "пустой буфер отдаёт :empty" do
    assert {:empty, _buffer} = Buffer.take(Buffer.new())
  end

  test "чанк за чанком: счётчики не путаются" do
    {buffer, 0} = Buffer.put_chunk(Buffer.new(), entries(0, 1))
    {:ok, _entry, buffer, 1} = Buffer.take(buffer)

    assert Buffer.remaining(buffer) == 0
    assert {:empty, buffer} = Buffer.take(buffer)

    {buffer, 0} = Buffer.put_chunk(buffer, entries(1, 1))

    assert {:ok, {1, "e1"}, _buffer, 1} = Buffer.take(buffer)
  end

  # ---

  defp entries(from, count) do
    Enum.map(from..(from + count - 1), &{&1, "e#{&1}"})
  end
end
