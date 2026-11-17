defmodule Core.Es.Personal.PlanTest do
  use ExUnit.Case, async: true

  alias Core.Es.Event.Payload
  alias Core.Es.Personal.Plan

  defmodule Name do
    @moduledoc false

    use Core.Prim.String,
      name: "Имя",
      min_len: 1,
      max_len: 50
  end

  defmodule Step do
    @moduledoc false

    use Core.Struct,
      fields: [
        owner_id: [prim: Core.EventFixture.PersonID],
        recipient: [prim: Core.PrimFixture.Personal, subject: {:local, :owner_id}],
        state: [type: :string]
      ]
  end

  defmodule Sealed do
    @moduledoc false

    use Core.Struct,
      fields: [phone: [prim: Core.PrimFixture.Personal, subject: :aggregate_id]]
  end

  defmodule Opaque do
    @moduledoc false

    defstruct [:value]
  end

  @where "Es.Event.Payload: fields"

  describe "entries/1" do
    test "места верхнего уровня, элемента списка и субъект по умолчанию" do
      fields =
        fields(
          person_id: [prim: Core.EventFixture.PersonID],
          phones: [list: [prim: Core.PrimFixture.Personal]],
          note: [prim: Core.PrimFixture.Personal, personal: true],
          meta: [prim: Name]
        )

      assert Plan.entries(fields) == [
               %{path: [:phones, :each], subject: :aggregate_id},
               %{path: [:note], subject: :aggregate_id}
             ]
    end

    test "вложенная сущность: путь сквозь entity и :each, локальный субъект — путь от корня" do
      fields = fields(steps: [list: [entity: Step]])

      assert Plan.entries(fields) == [
               %{path: [:steps, :each, :recipient], subject: {:path, [:steps, :each, :owner_id]}}
             ]
    end

    test "personal: true у поля останавливает спуск, personal: false не понижает Prim" do
      fields =
        fields(
          step: [entity: Sealed, personal: true],
          phone: [prim: Core.PrimFixture.Personal, personal: false]
        )

      assert Plan.entries(fields) == [
               %{path: [:step], subject: :aggregate_id},
               %{path: [:phone], subject: :aggregate_id}
             ]
    end

    test "set: и ключ map: поднимают границу до контейнера, значение map: — поэлементно" do
      fields =
        fields(
          roles: [set: [prim: Core.PrimFixture.Personal]],
          by_key: [map: [key: [type: :string, personal: true], value: [prim: Name]]],
          by_value: [map: [key: [type: :string], value: [prim: Core.PrimFixture.Personal]]]
        )

      assert Plan.entries(fields) == [
               %{path: [:roles], subject: :aggregate_id},
               %{path: [:by_key], subject: :aggregate_id},
               %{path: [:by_value, :each], subject: :aggregate_id}
             ]
    end

    test "форма плана события — wire-ключи, форма обхода — имена полей" do
      fields = fields(phone: [prim: Core.PrimFixture.Personal, wire: "tel"])

      assert Plan.entries(fields) == [%{path: [:tel], subject: :aggregate_id}]
      assert Plan.runtime_entries(fields) == [%{path: [:phone], subject: :aggregate_id}]
    end
  end

  describe "entries!/2" do
    test "subject: в поддереве без ПДн-места" do
      assert_raise CompileError, ~r/^Es\.Event\.Payload: fields: note: subject: :aggregate_id — в поддереве нет/, fn ->
        entries!(note: [prim: Name, subject: :aggregate_id])
      end
    end

    test "переопределение subject: под personal: true" do
      assert_raise CompileError, ~r/^Es\.Event\.Payload: fields: steps: subject: под personal: true/, fn ->
        entries!(steps: [list: [entity: Step], personal: true])
      end
    end

    test "субъект — не UUID Prim" do
      assert_raise CompileError, ~r/^Es\.Event\.Payload: fields: phone: субъект name — не Prim\.UUID/, fn ->
        entries!(
          name: [prim: Name],
          phone: [prim: Core.PrimFixture.Personal, subject: :name]
        )
      end
    end

    test "субъект сам ПДн" do
      assert_raise CompileError, ~r/^Es\.Event\.Payload: fields: phone: субъект person — ПДн-значение/, fn ->
        entries!(
          person: [prim: Core.PrimFixture.Personal],
          phone: [prim: Core.PrimFixture.Personal, subject: :person]
        )
      end
    end

    test "обязательное ПДн-место при необязательном субъекте" do
      assert_raise CompileError,
                   ~r/^Es\.Event\.Payload: fields: phone: обязательное при необязательном субъекте person_id/,
                   fn ->
                     entries!(
                       person_id: [prim: Core.EventFixture.PersonID, optional: true],
                       phone: [prim: Core.PrimFixture.Personal, subject: :person_id]
                     )
                   end
    end

    test "непрозрачная сущность без personal: true/false" do
      assert_raise CompileError, ~r/^Es\.Event\.Payload: fields: thing: сущность .*Opaque без общей декларации/, fn ->
        entries!(thing: [entity: Opaque])
      end
    end

    test "непрозрачное семейство без personal: true/false" do
      assert_raise CompileError, ~r/^Es\.Event\.Payload: fields: mark: семейство .*Mark/, fn ->
        entries!(mark: [union: Core.DerivedFixture.Mark])
      end
    end

    test "type: :map без personal: true/false" do
      assert_raise CompileError, ~r/^Es\.Event\.Payload: fields: extra: вид type: :map/, fn ->
        entries!(extra: [type: :map])
      end
    end

    test "personal: false снимает требование разметки у непрозрачного типа" do
      fields = fields(thing: [entity: Opaque, personal: false])

      assert Plan.entries!(fields, @where, uuid_prim: &Payload.uuid_prim?/1) == []
    end
  end

  describe "assert_writable!/3" do
    test "уничтоженное значение на вложенном месте — отказ" do
      entries = Plan.runtime_entries(fields(steps: [list: [entity: Step]]))

      step = %Step{owner_id: Core.EventFixture.PersonID.new(), recipient: %Core.Es.Personal.Destroyed{}, state: "new"}

      assert_raise ArgumentError, ~r/ПДн-место steps\.each\.recipient: уничтоженное/, fn ->
        Plan.assert_writable!(%{steps: [step]}, entries)
      end
    end

    test "непустое ПДн-значение при nil локальном субъекте — отказ" do
      entries = Plan.runtime_entries(fields(steps: [list: [entity: Step]]))

      step = %Step{owner_id: nil, recipient: Core.PrimFixture.Personal.new!("+7 900 000-00-00"), state: "new"}

      assert_raise ArgumentError, ~r/ПДн-место steps\.each\.recipient: непустое ПДн-значение без субъекта/, fn ->
        Plan.assert_writable!(%{steps: [step]}, entries)
      end
    end

    test "пустое значение при nil субъекте и неизвестный aggregate_id записи не мешают" do
      entries = Plan.runtime_entries(fields(steps: [list: [entity: Step]]))

      assert :ok = Plan.assert_writable!(%{steps: [%Step{owner_id: nil, recipient: nil, state: "new"}]}, entries)
      phones = Plan.runtime_entries(fields(phone: [prim: Core.PrimFixture.Personal]))

      assert :ok = Plan.assert_writable!(%{phone: Core.PrimFixture.Personal.new!("+7 900 000-00-00")}, phones)
    end
  end

  # ---

  defp fields(spec), do: Core.Field.declare!(spec, :payload, @where)

  defp entries!(spec), do: Plan.entries!(fields(spec), @where, uuid_prim: &Payload.uuid_prim?/1)
end
