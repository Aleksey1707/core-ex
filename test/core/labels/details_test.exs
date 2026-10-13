defmodule Core.Labels.DetailsTest do
  use ExUnit.Case, async: true

  alias Core.Es.Event.At
  alias Core.EventFixture.ActorID
  alias Core.EventFixture.AggID
  alias Core.Labels.Details
  alias Core.LabelsFixture.Amount
  alias Core.LabelsFixture.Count
  alias Core.LabelsFixture.Day
  alias Core.LabelsFixture.Event
  alias Core.LabelsFixture.Moment
  alias Core.LabelsFixture.Name
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

  test "нагрузка-Prim — одно сведение с подписью payload:" do
    name = Name.new!("Склад")

    assert Details.build(event(Event.Renamed, name)) ==
             {"Запись переименована", [%{label: "Название", kind: :text, value: name}]}
  end

  test "нагрузка nil — пустые сведения" do
    closed = Event.Closed.new(AggID.new(), Version.new(), ActorID.new(), At.now!())

    assert Details.build(closed) == {"Запись закрыта", []}
  end

  # ---

  defp event(module, payload), do: module.new(payload, AggID.new(), Version.new(), ActorID.new(), At.now!())
end
