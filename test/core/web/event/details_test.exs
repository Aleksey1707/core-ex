defmodule Core.Web.Event.DetailsTest do
  use ExUnit.Case, async: true

  alias Core.CodecFixture.External
  alias Core.Es.Event.At
  alias Core.EventFixture.ActorID
  alias Core.EventFixture.AggID
  alias Core.LabelsFixture.Address
  alias Core.LabelsFixture.Amount
  alias Core.LabelsFixture.AuthorID
  alias Core.LabelsFixture.BaseUnit
  alias Core.LabelsFixture.Count
  alias Core.LabelsFixture.Day
  alias Core.LabelsFixture.Event
  alias Core.LabelsFixture.ItemID
  alias Core.LabelsFixture.Line
  alias Core.LabelsFixture.Moment
  alias Core.LabelsFixture.Name
  alias Core.LabelsFixture.Shape
  alias Core.LabelsFixture.SnapshotID
  alias Core.LabelsFixture.Title
  alias Core.LabelsFixture.Unit
  alias Core.LabelsFixture.UserID
  alias Core.LabelsFixture.WebEvent
  alias Core.Version

  describe "нагрузка по полям" do
    test "вид строкой, число строкой с десятичной точкой, дата и дата-время дампом кодека, «Да»" do
      moment = Moment.new!(~U[2026-10-13 09:30:00.000000Z])

      payload =
        Event.Updated.Payload.new(
          Name.new!("Склад"),
          Count.new!(3),
          Amount.new!("12.50"),
          Day.new!(~D[2026-10-13]),
          moment,
          "первая партия",
          true,
          2,
          "импорт"
        )

      assert wire(event(Event.Updated, payload), %{}) == %{
               "title" => "Запись изменена",
               "details" => [
                 text("Название", "Склад"),
                 number("Количество", "3"),
                 number("Сумма", "12.50"),
                 detail("День", "date", "2026-10-13"),
                 detail("Момент", "datetime", External.dump(moment)),
                 text("Примечание", "первая партия"),
                 text("Срочно", "Да"),
                 number("Ранг", "2")
               ]
             }
    end

    test "поле без значения — value: null со своим видом; «Нет»" do
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

      %{"details" => details} = wire(event(Event.Updated, payload), %{})

      assert number("Сумма", nil) in details
      assert text("Примечание", nil) in details
      assert text("Срочно", "Нет") in details
    end
  end

  test "decimal кодека — нормальная запись строкой" do
    {{:module, web_event, _bytecode, _exports}, []} =
      compile_event(:DecimalProfile,
        codec: Core.CodecFixture.Internal,
        user_ref: [dump: &WebEvent.user_ref/2],
        labels: true
      )

    payload =
      Event.Updated.Payload.new(
        Name.new!("Склад"),
        Count.new!(3),
        Amount.new!("1E+3"),
        day(),
        moment(),
        nil,
        true,
        1,
        "импорт"
      )

    %Event.Updated{by: by} = event = event(Event.Updated, payload)

    assert %{details: [_name, _count, %{label: "Сумма", kind: "number", value: "1000"} | _]} =
             web_event.to_wire(event, %{by => "Автор"})
  end

  test "title и details — рядом с полями события, автор — ссылкой на учётную запись" do
    %Event.Closed{by: by} = closed = event(Event.Closed, nil)

    assert %{type: "labels_web.closed", by: %{login: "Автор"}, title: "Запись закрыта", details: []} =
             WebEvent.to_wire(closed, %{by => "Автор"})
  end

  test "вложенность: группа, список групп и чисел без подписи, вариант семейства, композит" do
    payload =
      Event.Shipped.Payload.new(
        %Address{city: Name.new!("Казань"), zip: "420000", checksum: "x1"},
        nil,
        [%Line{title: Name.new!("Болт"), count: Count.new!(4)}],
        [Count.new!(4)],
        %Shape.Rect{width: 2, height: 5},
        Title.new!("Срочная отправка")
      )

    assert wire(event(Event.Shipped, payload), %{}) == %{
             "title" => "Заказ отправлен",
             "details" => [
               group("Адрес", [text("Город", "Казань"), text("Индекс", "420000")]),
               group("Запасной адрес", nil),
               list("Позиции", [
                 %{"kind" => "group", "value" => [text("Наименование", "Болт"), number("Количество", "4")]}
               ]),
               list("Счётчики", [%{"kind" => "number", "value" => "4"}]),
               group("Фигура", [number("Ширина", "2"), number("Высота", "5")]),
               text("Заголовок", "Срочная отправка")
             ]
           }
  end

  describe "ссылки" do
    test "ref — {entity, id, name} с видом записи в camelCase, user — дамп user_ref:, id — текстом" do
      [item, other] = for _ <- 1..2, do: ItemID.new()
      [owner, author] = for _ <- 1..2, do: UserID.new()
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

      refs = %{item => "Позиция 1", other => nil, owner => "Владелец", author => "Автор"}

      assert wire(event(Event.Linked, payload), refs) == %{
               "title" => "Позиция связана",
               "details" => [
                 ref("Позиция", item, "Позиция 1"),
                 detail("Запасная позиция", "ref", nil),
                 list("Позиции", [%{"kind" => "ref", "value" => ref_value(other, nil)}]),
                 user("Владелец", owner, "Владелец"),
                 user("Автор", author, "Автор"),
                 text("Снимок", External.dump(snapshot)),
                 text("Единица", "Килограмм"),
                 text("Базовая единица", "Штука"),
                 list("Лимиты", nil)
               ]
             }
    end

    test "map'а с id в ключах — список групп «ключ — значение»" do
      keyed = ItemID.new()
      payload = %Event.Limited.Payload{limits: %{keyed => Count.new!(5)}}

      assert wire(event(Event.Limited, payload), %{keyed => "Позиция 5"}) == %{
               "title" => "Лимиты заданы",
               "details" => [
                 list("Лимиты", [
                   %{"kind" => "group", "value" => [ref("Позиция", keyed, "Позиция 5"), number("Лимит", "5")]}
                 ])
               ]
             }
    end

    test "id, которого нет в словаре ссылок, — ArgumentError" do
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
          nil
        )

      %Event.Linked{by: by} = event = event(Event.Linked, payload)

      assert_raise ArgumentError, ~r/нет в словаре ссылок/, fn ->
        WebEvent.to_wire(event, %{by => "Автор"})
      end
    end
  end

  describe "изменение" do
    test "{label, kind: change, old, new}, стороны без подписи" do
      payload = Event.NameChanged.Payload.new(Name.new!("Склад"), Name.new!("Склад у реки"))

      assert wire(event(Event.NameChanged, payload), %{}) == %{
               "title" => "Название изменено",
               "details" => [
                 %{
                   "label" => "Название",
                   "kind" => "change",
                   "old" => %{"kind" => "text", "value" => "Склад"},
                   "new" => %{"kind" => "text", "value" => "Склад у реки"}
                 }
               ]
             }
    end

    test "сторона без значения — value: null" do
      payload = Event.StatusSwitched.Payload.new(nil, :active)

      assert %{"details" => [%{"old" => %{"kind" => "text", "value" => nil}, "new" => %{"value" => "Активна"}}]} =
               wire(event(Event.StatusSwitched, payload), %{})
    end
  end

  test "нагрузка-Prim — одно сведение, нагрузка nil — пустые сведения" do
    assert wire(event(Event.Renamed, Name.new!("Склад")), %{}) == %{
             "title" => "Запись переименована",
             "details" => [text("Название", "Склад")]
           }

    assert wire(event(Event.Closed, nil), %{}) == %{"title" => "Запись закрыта", "details" => []}
  end

  # ---

  # Название и сведения — JSON дампа: автор события в словаре ссылок, поля конверта не сверяются.
  defp wire(%_{by: by} = event, refs) do
    event
    |> WebEvent.to_wire(Map.put(refs, by, "Автор"))
    |> Map.take(~w(title details)a)
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp event(Event.Closed, nil), do: Event.Closed.new(AggID.new(), Version.new(), ActorID.new(), At.now!())
  defp event(module, payload), do: module.new(payload, AggID.new(), Version.new(), ActorID.new(), At.now!())

  defp day, do: Day.new!(~D[2026-10-13])
  defp moment, do: Moment.new!(~U[2026-10-13 09:30:00.000000Z])

  defp compile_event(name, opts) do
    module = Module.concat(__MODULE__, name)

    Code.eval_quoted(
      quote do
        defmodule unquote(module) do
          use Core.Web.Event, unquote(opts)
        end
      end
    )
  end

  defp detail(label, kind, value), do: %{"label" => label, "kind" => kind, "value" => value}
  defp text(label, value), do: detail(label, "text", value)
  defp number(label, value), do: detail(label, "number", value)
  defp group(label, details), do: detail(label, "group", details)
  defp list(label, items), do: detail(label, "list", items)
  defp ref(label, id, name), do: detail(label, "ref", ref_value(id, name))
  defp user(label, id, login), do: detail(label, "user", %{"id" => External.dump(id), "login" => login})

  defp ref_value(id, name), do: %{"entity" => "stockItem", "id" => External.dump(id), "name" => name}
end
