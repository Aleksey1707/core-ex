defmodule Core.Labels.RefsTest do
  use ExUnit.Case, async: true

  alias Core.Context
  alias Core.Error
  alias Core.Es.Event.At
  alias Core.EventFixture.ActorID
  alias Core.EventFixture.AggID
  alias Core.Labels.Refs
  alias Core.LabelsFixture.Amount
  alias Core.LabelsFixture.AuthorID
  alias Core.LabelsFixture.BaseUnit
  alias Core.LabelsFixture.Count
  alias Core.LabelsFixture.Day
  alias Core.LabelsFixture.Event
  alias Core.LabelsFixture.ItemID
  alias Core.LabelsFixture.ItemQuery
  alias Core.LabelsFixture.Moment
  alias Core.LabelsFixture.Name
  alias Core.LabelsFixture.Shape
  alias Core.LabelsFixture.SnapshotID
  alias Core.LabelsFixture.Unit
  alias Core.LabelsFixture.UserID
  alias Core.LabelsFixture.UserQuery
  alias Core.Pagination
  alias Core.Version

  test "id с резолвером на любой глубине: поле, список, ключ и значение map'ы, композит" do
    [item, backup, listed, keyed] = for _ <- 1..4, do: ItemID.new()
    [owner, author, valued] = for _ <- 1..3, do: UserID.new()

    names = %{
      item => "Позиция 1",
      backup => "Позиция 2",
      listed => "Позиция 3",
      keyed => "Позиция 4",
      owner => "Владелец",
      author => "Автор",
      valued => "Получатель"
    }

    event =
      linked(item, owner, backup: backup, items: [listed], author: AuthorID.new!(author), limits: %{keyed => valued})

    assert Refs.get(event, context(names)) == {:ok, names}
  end

  test "автор события и id в варианте семейства; id агрегата не обходится" do
    [by, assignee] = for _ <- 1..2, do: UserID.new()
    item = ItemID.new()
    names = %{by => "Автор", assignee => "Исполнитель", item => "Позиция"}

    assert Refs.get(assigned(by, assignee, item), context(names)) == {:ok, names}
  end

  test "резолвер — один вызов на резолвер пачкой уникальных id всей страницы" do
    [first, second] = for _ <- 1..2, do: ItemID.new()
    [by, owner] = for _ <- 1..2, do: UserID.new()

    page =
      Pagination.Result.new(
        [
          assigned(by, owner, first),
          linked(first, owner, items: [second, first]),
          closed()
        ],
        3
      )

    names = %{first => "Первая", second => "Вторая", by => "Автор", owner => "Владелец"}

    assert Refs.get(page, context(names)) == {:ok, names}

    assert_received {:get_names, ItemQuery, items}
    assert Enum.sort(items) == Enum.sort([first, second])
    assert_received {:get_names, UserQuery, users}
    assert Enum.sort(users) == Enum.sort([by, owner])
    refute_received {:get_names, _resolver, _ids}
  end

  test "список событий — тот же словарь, что и страница" do
    item = ItemID.new()
    owner = UserID.new()
    events = [linked(item, owner), closed()]
    names = %{item => "Позиция", owner => "Владелец"}

    assert Refs.get(events, context(names)) == {:ok, names}
    assert Refs.get(Pagination.Result.new(events, 2), context(names)) == {:ok, names}
  end

  test "без id с резолвером — пустой словарь без вызовов резолвера" do
    events = [
      updated(),
      closed(),
      Event.Renamed.new(Name.new!("Склад"), AggID.new(), Version.new(), ActorID.new(), At.now!())
    ]

    assert Refs.get(Pagination.Result.new(events, 3), Context.new()) == {:ok, %{}}
    assert Refs.get([], Context.new()) == {:ok, %{}}
    refute_received {:get_names, _resolver, _ids}
  end

  test "запись без имени — nil" do
    item = ItemID.new()
    owner = UserID.new()
    names = %{item => nil, owner => "Владелец"}

    assert Refs.get(linked(item, owner), context(names)) == {:ok, names}
  end

  test "отказ резолвера — итог сборки словаря" do
    item = ItemID.new()
    owner = UserID.new()

    assert {:error, %Error{code: :not_found, ns: ItemQuery, detail: [^item]}} =
             Refs.get(linked(item, owner), context(%{owner => "Владелец"}))
  end

  # ---

  defp context(names), do: Context.new(%{names: names})

  defp linked(item, owner, fields \\ []) do
    payload =
      struct!(
        Event.Linked.Payload,
        Keyword.merge(
          [
            item: item,
            items: [],
            owner: owner,
            author: AuthorID.new!(owner),
            snapshot: SnapshotID.new(),
            unit: Unit.new!("kg"),
            base_unit: BaseUnit.new!("pc")
          ],
          fields
        )
      )

    Event.Linked.new(payload, AggID.new(), Version.new(), ActorID.new(), At.now!())
  end

  defp assigned(by, assignee, item) do
    payload = %Event.Assigned.Payload{
      assignee: assignee,
      shape: %Shape.Pin{item: item},
      amount: Amount.new!("12.50"),
      day: Day.new!(~D[2026-10-13]),
      moment: Moment.new!(~U[2026-10-13 09:30:00.000000Z])
    }

    Event.Assigned.new(payload, ItemID.new(), Version.new(), by, At.now!())
  end

  defp updated do
    payload =
      Event.Updated.Payload.new(
        Name.new!("Склад"),
        Count.new!(3),
        Amount.new!("12.50"),
        Day.new!(~D[2026-10-13]),
        Moment.new!(~U[2026-10-13 09:30:00.000000Z]),
        nil,
        true,
        2,
        "импорт"
      )

    Event.Updated.new(payload, AggID.new(), Version.new(), ActorID.new(), At.now!())
  end

  defp closed, do: Event.Closed.new(AggID.new(), Version.new(), ActorID.new(), At.now!())
end
