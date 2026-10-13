defmodule Core.Web.LabelsTest do
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
  alias Core.LabelsFixture.Wire
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
    {{:module, wire, _bytecode, _exports}, []} =
      compile_wire(:DecimalProfile, codec: Core.CodecFixture.Internal, user_ref: [dump: &Wire.user_ref/2])

    payload = Event.Assigned.Payload.new(UserID.new(), %Shape.Circle{radius: 1}, Amount.new!("1E+3"), day(), moment())
    %Event.Assigned{by: by} = event = assigned(payload)

    assert %{details: [_assignee, _shape, %{label: "Сумма", kind: "number", value: "1000"} | _]} =
             wire.to_wire(event, %{payload.assignee => "Исполнитель", by => "Автор"})
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
      [item, keyed] = for _ <- 1..2, do: ItemID.new()
      [owner, author] = for _ <- 1..2, do: UserID.new()

      payload =
        Event.Linked.Payload.new(
          item,
          nil,
          [],
          owner,
          AuthorID.new!(author),
          SnapshotID.new(),
          Unit.new!("kg"),
          BaseUnit.new!("kg"),
          %{keyed => Count.new!(5)}
        )

      refs = %{item => "Позиция 1", keyed => "Позиция 5", owner => "Владелец", author => "Автор"}
      %{"details" => details} = wire(event(Event.Linked, payload), refs)

      assert list("Лимиты", [
               %{"kind" => "group", "value" => [ref("Позиция", keyed, "Позиция 5"), number("Лимит", "5")]}
             ]) in details
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

      assert_raise ArgumentError, ~r/нет в словаре ссылок/, fn ->
        Wire.to_wire(event(Event.Linked, payload), %{})
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

    closed = Event.Closed.new(AggID.new(), Version.new(), ActorID.new(), At.now!())

    assert wire(closed, %{}) == %{"title" => "Запись закрыта", "details" => []}
  end

  describe "отказ сборки" do
    test "без codec: — CompileError" do
      assert_raise CompileError, ~r/Web.Labels: нет обязательных опций: \[:codec\]/, fn ->
        compile_wire(:NoCodec, user_ref: [dump: &Wire.user_ref/2])
      end
    end

    test "codec: без dump/1 — CompileError" do
      assert_raise CompileError, ~r/Web.Labels: codec: модуль URI должен экспортировать dump\/1/, fn ->
        compile_wire(:BadCodec, codec: URI, user_ref: [dump: &Wire.user_ref/2])
      end
    end

    test "без user_ref: — CompileError" do
      assert_raise CompileError, ~r/Web.Labels: нет обязательных опций: \[:user_ref\]/, fn ->
        compile_wire(:NoUserRef, codec: External)
      end
    end

    test "user_ref: без dump: — CompileError" do
      assert_raise CompileError, ~r/NoDump: user_ref: нет обязательных опций: \[:dump\]/, fn ->
        compile_wire(:NoDump, codec: External, user_ref: [])
      end
    end

    test "user_ref: с неизвестной опцией — CompileError" do
      assert_raise CompileError, ~r/Unknown: user_ref: неизвестные опции: \[:login\]/, fn ->
        compile_wire(:Unknown, codec: External, user_ref: [dump: &Wire.user_ref/2, login: true])
      end
    end

    test "dump: не захват функции арности 2 — CompileError" do
      assert_raise CompileError, ~r/Arity: user_ref: dump: — захват функции арности 2/, fn ->
        compile_wire(:Arity, codec: External, user_ref: [dump: &Kernel.inspect/1])
      end
    end
  end

  # ---

  defp wire(event, refs) do
    event
    |> Wire.to_wire(refs)
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp event(module, payload), do: module.new(payload, AggID.new(), Version.new(), ActorID.new(), At.now!())

  defp assigned(payload), do: Event.Assigned.new(payload, ItemID.new(), Version.new(), UserID.new(), At.now!())

  defp day, do: Day.new!(~D[2026-10-13])
  defp moment, do: Moment.new!(~U[2026-10-13 09:30:00.000000Z])

  defp compile_wire(name, opts) do
    module = Module.concat(__MODULE__, name)

    Code.eval_quoted(
      quote do
        defmodule unquote(module) do
          use Core.Web.Labels, unquote(opts)
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
