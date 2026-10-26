defmodule Core.Labels.DetailsTest do
  use ExUnit.Case, async: true

  alias Core.Es.Event.At
  alias Core.Es.Personal
  alias Core.EventFixture.AggID
  alias Core.Labels.Details
  alias Core.LabelsFixture.Address
  alias Core.LabelsFixture.Amount
  alias Core.LabelsFixture.AuthorID
  alias Core.LabelsFixture.BareID
  alias Core.LabelsFixture.BaseUnit
  alias Core.LabelsFixture.Count
  alias Core.LabelsFixture.Day
  alias Core.LabelsFixture.Event
  alias Core.LabelsFixture.Holder
  alias Core.LabelsFixture.ItemID
  alias Core.LabelsFixture.Line
  alias Core.LabelsFixture.Moment
  alias Core.LabelsFixture.Name
  alias Core.LabelsFixture.Parcel
  alias Core.LabelsFixture.Shape
  alias Core.LabelsFixture.SnapshotID
  alias Core.LabelsFixture.Title
  alias Core.LabelsFixture.Unit
  alias Core.LabelsFixture.UserID
  alias Core.Version

  describe "нагрузка по полям" do
    test "сведения каждого вида — в порядке спеки нагрузки, без скрытого поля" do
      name = Name.new!("Склад")
      count = Count.new!(3)
      amount = Amount.new!("12.50")
      day = Day.new!(~D[2026-10-13])
      moment = Moment.new!(~U[2026-10-13 09:30:00.000000Z])

      payload = Event.Updated.Payload.new(name, count, amount, day, moment, "первая партия", true, 2, "импорт")

      assert Details.build(event(Event.Updated, payload)) ==
               {"Запись изменена",
                [
                  %{label: "Название", kind: :text, value: name},
                  %{label: "Количество", kind: :number, value: count},
                  %{label: "Сумма", kind: :number, value: amount},
                  %{label: "День", kind: :date, value: day},
                  %{label: "Момент", kind: :datetime, value: moment},
                  %{label: "Примечание", kind: :text, value: "первая партия"},
                  %{label: "Срочно", kind: :text, value: "Да"},
                  %{label: "Ранг", kind: :number, value: 2}
                ]}
    end

    test "поле без значения — value: nil со своим видом; boolean false — «Нет»" do
      payload =
        Event.Updated.Payload.new(
          Name.new!("Склад"),
          Count.new!(0),
          nil,
          Day.new!(~D[2026-10-13]),
          Moment.new!(~U[2026-10-13 09:30:00.000000Z]),
          nil,
          false,
          1,
          "импорт"
        )

      {_title, details} = Details.build(event(Event.Updated, payload))

      assert %{label: "Сумма", kind: :number, value: nil} in details
      assert %{label: "Примечание", kind: :text, value: nil} in details
      assert %{label: "Срочно", kind: :text, value: "Нет"} in details
    end
  end

  describe "поле Enum" do
    test "сведение text с подписью значения" do
      payload = Event.StatusChanged.Payload.new(:active, :draft)

      assert Details.build(event(Event.StatusChanged, payload)) ==
               {"Статус сменён",
                [
                  %{label: "Статус", kind: :text, value: "Активна"},
                  %{label: "Прежний статус", kind: :text, value: "Черновик"}
                ]}
    end

    test "поле без значения — value: nil" do
      payload = Event.StatusChanged.Payload.new(:archived, nil)

      {_title, details} = Details.build(event(Event.StatusChanged, payload))

      assert %{label: "Прежний статус", kind: :text, value: nil} in details
    end
  end

  describe "вложенность" do
    test "struct — группа, список — элементы без подписи, семейство — группа варианта, композит — вид базы" do
      city = Name.new!("Казань")
      title = Name.new!("Болт")
      count = Count.new!(4)
      heading = Title.new!("Срочная отправка")

      payload =
        Event.Shipped.Payload.new(
          %Address{city: city, zip: "420000", checksum: "x1"},
          nil,
          [%Line{title: title, count: count}],
          [count],
          %Shape.Circle{radius: 3},
          heading
        )

      assert Details.build(event(Event.Shipped, payload)) ==
               {"Заказ отправлен",
                [
                  %{
                    label: "Адрес",
                    kind: :group,
                    value: [
                      %{label: "Город", kind: :text, value: city},
                      %{label: "Индекс", kind: :text, value: "420000"}
                    ]
                  },
                  %{label: "Запасной адрес", kind: :group, value: nil},
                  %{
                    label: "Позиции",
                    kind: :list,
                    value: [
                      %{
                        kind: :group,
                        value: [
                          %{label: "Наименование", kind: :text, value: title},
                          %{label: "Количество", kind: :number, value: count}
                        ]
                      }
                    ]
                  },
                  %{label: "Счётчики", kind: :list, value: [%{kind: :number, value: count}]},
                  %{label: "Фигура", kind: :group, value: [%{label: "Радиус", kind: :number, value: 3}]},
                  %{label: "Заголовок", kind: :text, value: heading}
                ]}
    end

    test "вариант семейства — группа полей своего варианта" do
      payload =
        Event.Shipped.Payload.new(
          %Address{city: Name.new!("Казань")},
          nil,
          [],
          [],
          %Shape.Rect{width: 2, height: 5},
          Title.new!("Отправка")
        )

      {_title, details} = Details.build(event(Event.Shipped, payload))

      assert %{label: "Фигура", kind: :group, value: [%{label: "Ширина", value: 2}, %{label: "Высота", value: 5}]} =
               Enum.find(details, &(&1.label == "Фигура"))

      assert %{label: "Позиции", kind: :list, value: []} in details
    end
  end

  test "спека fields: и text: — текст функцией, у списка — по элементу; скрытое не выходит" do
    count = Count.new!(2)
    payload = %Event.Tagged.Payload{origin: %Line{}, tags: ~w(urgent fragile)a, count: count, trace: "t-1"}

    assert Details.build(event(Event.Tagged, payload)) ==
             {"Метки расставлены",
              [
                %{label: "Источник", kind: :text, value: "Позиция"},
                %{
                  label: "Метки",
                  kind: :list,
                  value: [%{kind: :text, value: "urgent"}, %{kind: :text, value: "fragile"}]
                },
                %{label: "Количество", kind: :number, value: count}
              ]}
  end

  test "вложенная структура по полям — сведения по её спеке, скрытое не выходит" do
    name = Name.new!("Коробка")
    count = Count.new!(4)
    payload = Event.Packed.Payload.new(%Parcel{name: name, count: count, note: nil, trace: "t-2"})

    assert Details.build(event(Event.Packed, payload)) ==
             {"Посылка собрана",
              [
                %{
                  label: "Посылка",
                  kind: :group,
                  value: [
                    %{label: "Название", kind: :text, value: name},
                    %{label: "Количество", kind: :number, value: count},
                    %{label: "Примечание", kind: :text, value: nil}
                  ]
                }
              ]}
  end

  describe "изменение «было → стало»" do
    test "Core.Es.ValueChanged на Prim — одно сведение change, стороны без подписи" do
      old = Name.new!("Склад")
      new = Name.new!("Склад у реки")
      payload = Event.NameChanged.Payload.new(old, new)

      assert Details.build(event(Event.NameChanged, payload)) ==
               {"Название изменено",
                [%{label: "Название", kind: :change, old: %{kind: :text, value: old}, new: %{kind: :text, value: new}}]}
    end

    test "Core.Es.ValueChanged на Enum — подпись значения; сторона без значения — value: nil" do
      payload = Event.StatusSwitched.Payload.new(nil, :active)

      assert Details.build(event(Event.StatusSwitched, payload)) ==
               {"Статус переключён",
                [
                  %{
                    label: "Статус",
                    kind: :change,
                    old: %{kind: :text, value: nil},
                    new: %{kind: :text, value: "Активна"}
                  }
                ]}
    end

    test "ручной struct с value: [text: …] — текст функцией" do
      payload = %Event.OriginChanged.Payload{old_value: %Address{}, new_value: %Line{}}

      assert Details.build(event(Event.OriginChanged, payload)) ==
               {"Источник изменён",
                [
                  %{
                    label: "Источник",
                    kind: :change,
                    old: %{kind: :text, value: "Адрес"},
                    new: %{kind: :text, value: "Позиция"}
                  }
                ]}
    end

    test "ручной struct с value: [list: …] — стороны списком элементов" do
      payload = %Event.TagsChanged.Payload{old_value: [], new_value: ~w(urgent)a}

      assert Details.build(event(Event.TagsChanged, payload)) ==
               {"Метки изменены",
                [
                  %{
                    label: "Метки",
                    kind: :change,
                    old: %{kind: :list, value: []},
                    new: %{kind: :list, value: [%{kind: :text, value: "urgent"}]}
                  }
                ]}
    end
  end

  describe "вид id и Prim текстом" do
    test "ref — ссылка с видом записи, user — учётная запись, id — текстом; Prim с текстом — текст функции" do
      item = ItemID.new()
      other = ItemID.new()
      owner = UserID.new()
      author = UserID.new()
      snapshot = SnapshotID.new()

      payload =
        Event.Linked.Payload.new(
          item,
          nil,
          [other],
          owner,
          AuthorID.new!(author),
          snapshot,
          Unit.new!("kg"),
          BaseUnit.new!("pc"),
          nil
        )

      assert Details.build(event(Event.Linked, payload)) ==
               {"Позиция связана",
                [
                  %{label: "Позиция", kind: :ref, entity: :stock_item, value: item},
                  %{label: "Запасная позиция", kind: :ref, entity: :stock_item, value: nil},
                  %{label: "Позиции", kind: :list, value: [%{kind: :ref, entity: :stock_item, value: other}]},
                  %{label: "Владелец", kind: :user, value: owner},
                  %{label: "Автор", kind: :user, value: author},
                  %{label: "Снимок", kind: :text, value: snapshot},
                  %{label: "Единица", kind: :text, value: "Килограмм"},
                  %{label: "Базовая единица", kind: :text, value: "Штука"},
                  %{label: "Лимиты", kind: :list, value: nil}
                ]}
    end

    test "map'а с id в ключах — список групп «ключ — значение», вид значения — по самому значению" do
      item = ItemID.new()
      count = Count.new!(5)

      payload =
        Event.Linked.Payload.new(
          ItemID.new(),
          nil,
          [],
          UserID.new(),
          AuthorID.new!(UserID.new()),
          SnapshotID.new(),
          Unit.new!("kg"),
          BaseUnit.new!("kg"),
          %{item => count}
        )

      {_title, details} = Details.build(event(Event.Linked, payload))

      assert %{
               label: "Лимиты",
               kind: :list,
               value: [
                 %{
                   kind: :group,
                   value: [
                     %{label: "Позиция", kind: :ref, entity: :stock_item, value: item},
                     %{label: "Лимит", kind: :number, value: count}
                   ]
                 }
               ]
             } in details
    end

    test "id без Core.Labels.ID — ArgumentError с именем модуля" do
      payload = Event.Unmarked.Payload.new(BareID.new())

      assert_raise ArgumentError, ~r/Core.LabelsFixture.BareID: id без вида в сведениях/, fn ->
        Details.build(event(Event.Unmarked, payload))
      end
    end
  end

  test "нагрузка-Prim — одно сведение с подписью payload:" do
    name = Name.new!("Склад")

    assert Details.build(event(Event.Renamed, name)) ==
             {"Запись переименована", [%{label: "Название", kind: :text, value: name}]}
  end

  test "уничтоженное ПДн-значение — вид destroyed без значения, сторона изменения — элемент destroyed" do
    payload =
      Event.Contacted.Payload.new(
        Holder.new!("Анна"),
        %Address{city: Name.new!("Казань")},
        [Holder.new!("Аня")],
        UserID.new(),
        %{"склад" => 5}
      )

    assert Details.build(Personal.Test.destroyed(event(Event.Contacted, payload))) ==
             {"Контакт указан",
              [
                %{label: "Владелец", kind: :destroyed},
                %{label: "Адрес", kind: :destroyed},
                %{label: "Псевдонимы", kind: :destroyed},
                %{label: "Учётная запись", kind: :destroyed},
                %{label: "Лимиты", kind: :destroyed}
              ]}

    changed = event(Event.HolderChanged, Event.HolderChanged.Payload.new(Holder.new!("Анна"), Holder.new!("Аня")))

    assert Details.build(Personal.Test.destroyed(changed, [:old_value])) ==
             {"Владелец сменён",
              [
                %{
                  label: "Владелец",
                  kind: :change,
                  old: %{kind: :destroyed},
                  new: %{kind: :text, value: Holder.new!("Аня")}
                }
              ]}
  end

  test "нагрузка nil — пустые сведения" do
    closed = Event.Closed.new(AggID.new(), Version.new(), UserID.new(), At.now!())

    assert Details.build(closed) == {"Запись закрыта", []}
  end

  # ---

  defp event(module, payload), do: module.new(payload, AggID.new(), Version.new(), UserID.new(), At.now!())
end
