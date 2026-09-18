defmodule Core.Es.StoreTest do
  use Core.DataCase, async: true

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.EventFixture
  alias Core.EventFixture.AggID
  alias Core.Exc
  alias Core.Pagination
  alias Core.Version

  @codec EventFixture.Event.Codec

  defmodule Stranger do
    @moduledoc false

    defstruct ~w(id)a
  end

  describe "append/5" do
    test "пишет события нескольких потоков; Test.events! отдаёт поток по возрастанию версии" do
      first = AggID.new()
      second = AggID.new()
      opened = event(first, 1)
      other = event(second, 1)
      closed = EventFixture.in_stream(EventFixture.closed(), first, 2)

      assert :ok = append([opened, other, closed])

      assert wires(Es.Store.Test.events!(@codec, first)) == wires([opened, closed])
      assert wires(Es.Store.Test.events!(@codec, second)) == wires([other])
    end

    test "пустая пачка — :ok" do
      assert :ok = append([])
    end

    test "без continuous? поток начинается не с 1 и имеет разрывы" do
      id = AggID.new()

      assert :ok = append([event(id, 5), event(id, 7)])
      assert :ok = append([event(id, 9)])

      assert versions(id) == [5, 7, 9]
    end

    test "занятая версия — :version_mismatch вызывающего; транзакция пригодна для запросов" do
      id = AggID.new()
      written = event(id, 1)
      assert :ok = append([written])

      assert {:error, %Error{module: __MODULE__, ns: :fake, code: :version_mismatch} = error} =
               append([event(id, 1)])

      assert error.detail == %{aggregate_id: dump(id), expected: 1, actual: 1, source: :storage}
      assert wires(Es.Store.Test.events!(@codec, id)) == wires([written])
    end

    test "отказ пачки нескольких потоков называет поток с конфликтом" do
      free = AggID.new()
      taken = AggID.new()
      assert :ok = append([event(taken, 1), event(taken, 2)])

      assert {:error, %Error{detail: detail}} = append([event(free, 1), event(taken, 2)])

      assert detail == %{aggregate_id: dump(taken), expected: 2, actual: 2, source: :storage}
    end

    test "версии потока в пачке не по возрастанию — ArgumentError" do
      id = AggID.new()

      assert_raise ArgumentError, ~r/не по возрастанию/, fn ->
        append([event(id, 2), event(id, 1)])
      end
    end

    test "событие не из tags: кодека — FunctionClauseError" do
      assert_raise FunctionClauseError, fn -> append([%Stranger{id: 1}]) end
    end
  end

  describe "append/5 с continuous?: true" do
    test "первая версия потока в пачке — следующая за головой" do
      id = AggID.new()

      assert :ok = append([event(id, 1), event(id, 2)], continuous?: true)
      assert :ok = append([event(id, 3)], continuous?: true)

      assert versions(id) == [1, 2, 3]
    end

    test "пустой поток начинается с 1" do
      id = AggID.new()

      assert {:error, %Error{detail: detail}} = append([event(id, 2)], continuous?: true)

      assert detail == %{aggregate_id: dump(id), expected: 2, actual: nil, source: :storage}
      assert versions(id) == []
    end

    test "разрыв после головы потока — :version_mismatch" do
      id = AggID.new()
      assert :ok = append([event(id, 1)])

      assert {:error, %Error{detail: detail}} =
               append([event(id, 3), event(id, 4)], continuous?: true)

      assert detail == %{aggregate_id: dump(id), expected: 3, actual: 1, source: :storage}
      assert versions(id) == [1]
    end

    test "версия ниже головы потока — :version_mismatch" do
      id = AggID.new()
      assert :ok = append([event(id, 1), event(id, 3)])

      assert {:error, %Error{detail: detail}} = append([event(id, 2)], continuous?: true)

      assert detail == %{aggregate_id: dump(id), expected: 2, actual: 3, source: :storage}
    end

    test "поток длиннее чанка записи пишется целиком" do
      id = AggID.new()

      assert :ok = append(Enum.map(1..1_001, &event(id, &1)), continuous?: true)
      assert :ok = append([event(id, 1_002)], continuous?: true)

      assert versions(id) == Enum.to_list(1..1_002)
    end

    test "версии потока в пачке не подряд — ArgumentError" do
      id = AggID.new()

      assert_raise ArgumentError, ~r/не подряд/, fn ->
        append([event(id, 1), event(id, 3)], continuous?: true)
      end
    end
  end

  describe "Test.events!/2" do
    test "поток того же aggregate_id другого типа агрегата не читается" do
      id = AggID.new()
      written = event(id, 1)
      assert :ok = append([written])
      insert_row(id, aggregate_type: "other", tag: "other.created")

      assert wires(Es.Store.Test.events!(@codec, id)) == wires([written])
    end

    test "событие с неизвестным тегом — Core.Exc" do
      id = AggID.new()
      insert_row(id, aggregate_type: @codec.__es_type__(), tag: "fixture.unknown")

      assert_raise Exc, fn -> Es.Store.Test.events!(@codec, id) end
    end
  end

  describe "read_stream/5" do
    test "страница по возрастанию версии; count — весь поток" do
      id = AggID.new()
      [first, second, third, fourth, fifth] = Enum.map(1..5, &event(id, &1))
      assert :ok = append([fourth, fifth])
      assert :ok = append([first, second, third])

      assert {:ok, %Pagination.Result{items: items, count: 5}} = page(id, 3, 1)

      assert wires(items) == wires([second, third, fourth])
    end

    test "offset за концом потока — пустая страница с count всего потока" do
      id = AggID.new()
      assert :ok = append([event(id, 1), event(id, 2)])

      assert {:ok, %Pagination.Result{items: [], count: 2}} = page(id, 10, 5)
    end

    test "пустой поток — страница с count: 0" do
      assert {:ok, %Pagination.Result{items: [], count: 0}} = page(AggID.new(), 10, 0)
    end

    test "поток того же aggregate_id другого типа агрегата на страницу не попадает" do
      id = AggID.new()
      written = event(id, 1)
      assert :ok = append([written])
      insert_row(id, aggregate_type: "other", tag: "other.created")

      assert {:ok, %Pagination.Result{items: items, count: 1}} = page(id, 10, 0)

      assert wires(items) == wires([written])
    end

    test "событие с неизвестным тегом — ошибка всей страницы" do
      id = AggID.new()
      insert_row(id, aggregate_type: @codec.__es_type__(), tag: "fixture.unknown")
      assert :ok = append([event(id, 2)])

      assert {:error, %Error{code: :unknown_event_type, detail: "fixture.unknown"}} =
               page(id, 10, 0)
    end
  end

  defp append(events, opts \\ []) do
    Es.Store.append(@codec, events, Context.new(), &mismatch/1, opts)
  end

  defp page(id, limit, offset) do
    Es.Store.read_stream(
      @codec,
      id,
      Pagination.Limit.new!(limit),
      Pagination.Offset.new!(offset),
      Context.new()
    )
  end

  defp mismatch(detail), do: EventFixture.Errors.domain(__MODULE__, :version_mismatch, detail)

  defp event(id, version), do: EventFixture.in_stream(EventFixture.created(), id, version)

  defp versions(id) do
    @codec
    |> Es.Store.Test.events!(id)
    |> Enum.map(&Version.value(&1.aggregate_version))
  end

  defp wires(events), do: Enum.map(events, &dump/1)

  defp dump(id), do: Config.codec().dump(id)

  defp insert_row(id, attrs) do
    row = %{
      aggregate_type: Keyword.fetch!(attrs, :aggregate_type),
      aggregate_id: dump(id),
      aggregate_version: 1,
      event_id: Ecto.UUID.generate(),
      tag: Keyword.fetch!(attrs, :tag),
      payload: nil,
      by_id: Ecto.UUID.generate(),
      at: DateTime.utc_now(:second)
    }

    {1, _} = TestRepo.insert_all(Es.Store.Schema, [row])
  end
end
