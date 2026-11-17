defmodule Core.Labels.KindTableTest do
  use ExUnit.Case, async: true

  alias Core.Context
  alias Core.Es.Event.At
  alias Core.EventFixture.AggID
  alias Core.Field
  alias Core.Labels.CompletenessCase
  alias Core.Labels.Details
  alias Core.Labels.Refs
  alias Core.LabelsFixture.Event
  alias Core.LabelsFixture.Event.Kinds
  alias Core.LabelsFixture.ItemID
  alias Core.LabelsFixture.Seal
  alias Core.LabelsFixture.Shape
  alias Core.LabelsFixture.UserID
  alias Core.Version

  # Подпись поля каждого вида в `Event.Kinds.Payload`.
  @labels %{
    prim: "Prim",
    enum: "Enum",
    entity: "Entity",
    union: "Union",
    list: "List",
    set: "Set",
    map: "Map",
    type: "Type"
  }

  describe "вид × подписи" do
    test "каждый вид выходит сведением своего вида" do
      assert Enum.sort(Map.keys(@labels)) == Enum.sort(Field.kinds(:labels))

      detail_kinds = %{
        prim: :ref,
        enum: :text,
        entity: :group,
        union: :group,
        list: :list,
        set: :set,
        map: :map,
        type: :text
      }

      {_title, details} = Details.build(event(fresh()))

      for {kind, label} <- @labels do
        assert %{kind: detail_kind} = Enum.find(details, &(&1.label == label)), "нет сведения вида #{kind}"
        assert detail_kind == Map.fetch!(detail_kinds, kind), "вид сведения: #{kind}"
      end
    end

    test "каждый вид обходится словарём ссылок" do
      ids = fresh()

      refs = %{
        prim: [ids.prim],
        enum: [],
        entity: [ids.seal],
        union: [ids.pinned],
        list: [ids.list],
        set: [ids.set],
        map: [ids.map],
        type: []
      }

      assert Enum.sort(Map.keys(refs)) == Enum.sort(Field.kinds(:labels))

      names = Map.new([ids.by | Enum.concat(Map.values(refs))], &{&1, "Имя"})

      assert {:ok, found} = Refs.get(event(ids), Context.new(%{names: names}))

      for {kind, expected} <- refs do
        assert Enum.all?(expected, &Map.has_key?(found, &1)), "id вида #{kind} не в словаре"
      end

      assert Enum.sort(Map.keys(found)) == Enum.sort([ids.by | Enum.concat(Map.values(refs))])
    end

    test "полнота обходит каждый вид" do
      modules = [Event.Codec, Shape.Codec, Core.LabelsFixture.Codec]

      assert :ok = CompletenessCase.check_found(modules)
      assert :ok = CompletenessCase.check_titles(modules)
      assert :ok = CompletenessCase.check_fields(modules)
      assert :ok = CompletenessCase.check_values(modules)
      assert :ok = CompletenessCase.check_ids(modules)
      assert :ok = CompletenessCase.check_variants(modules)
    end

    # Пробелы листовых видов с модулем видны полноте на любой глубине: Prim — поле и значение
    # словаря, Enum — поле, список, множество и ключ словаря.
    test "полнота находит Prim и Enum на любой глубине" do
      modules = [Core.LabelsBrokenFixture.Event.Codec, Core.LabelsBrokenFixture.Mark.Codec]

      assert {:error, %{unkinded: unkinded}} = CompletenessCase.check_ids(modules)
      assert {:error, %{unlabelled: unlabelled}} = CompletenessCase.check_values(modules)

      assert Enum.sort(unkinded) ==
               Enum.sort([
                 {Core.LabelsBrokenFixture.Event.Marked.Payload, :ref, Core.LabelsFixture.BareID},
                 {Core.LabelsBrokenFixture.Event.Marked.Payload, :refs, Core.LabelsFixture.BareID}
               ])

      assert Enum.sort(unlabelled) ==
               Enum.sort([
                 {Core.LabelsBrokenFixture.Event.Marked.Payload, :kind, Core.LabelsBrokenFixture.Kind},
                 {Core.LabelsBrokenFixture.Event.Marked.Payload, :kind_set, Core.LabelsBrokenFixture.Kind},
                 {Core.LabelsBrokenFixture.Event.Marked.Payload, :kinds, Core.LabelsBrokenFixture.Kind},
                 {Core.LabelsBrokenFixture.Event.Marked.Payload, :refs, Core.LabelsBrokenFixture.Kind}
               ])
    end
  end

  # ---

  defp fresh do
    %{
      prim: ItemID.new(),
      seal: ItemID.new(),
      pinned: ItemID.new(),
      list: ItemID.new(),
      set: ItemID.new(),
      map: ItemID.new(),
      by: UserID.new()
    }
  end

  defp event(ids) do
    payload =
      Kinds.Payload.new(
        ids.prim,
        :active,
        %Seal{item: ids.seal},
        %Shape.Pin{item: ids.pinned},
        [ids.list],
        MapSet.new([ids.set]),
        %{ids.map => :active},
        "строка"
      )

    Kinds.new(payload, AggID.new(), Version.new(), ids.by, At.now!())
  end
end
