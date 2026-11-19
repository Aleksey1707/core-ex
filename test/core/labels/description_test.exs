defmodule Core.Labels.DescriptionTest do
  use ExUnit.Case, async: true

  alias Core.Context
  alias Core.Es.Event.At
  alias Core.EventFixture.AggID
  alias Core.Labels.Details
  alias Core.Labels.Refs
  alias Core.LabelsDescriptionFixture.Changed
  alias Core.LabelsDescriptionFixture.Changed.Payload, as: ChangedPayload
  alias Core.LabelsDescriptionFixture.Created
  alias Core.LabelsDescriptionFixture.Line
  alias Core.LabelsDescriptionFixture.Payload, as: CreatedPayload
  alias Core.LabelsFixture.Count
  alias Core.LabelsFixture.ItemID
  alias Core.LabelsFixture.Name
  alias Core.LabelsFixture.SnapshotID
  alias Core.LabelsFixture.UserID
  alias Core.Version

  describe "проекции описания значения" do
    test "сведения: лист, группа, множество, словарь и свободная map'а одного прохода" do
      [item, line_item, notes_key] = for _ <- 1..3, do: ItemID.new()
      snapshot = SnapshotID.new()
      [low, high] = Enum.sort_by(for(_ <- 1..2, do: ItemID.new()), &ItemID.value/1)
      owner = UserID.new()
      by = UserID.new()
      title = Name.new!("Болт")
      low_count = Count.new!(2)
      high_count = Count.new!(7)
      note_count = Count.new!(5)

      payload = %CreatedPayload{
        item: item,
        owner: owner,
        title: title,
        snapshot: snapshot,
        line: %Line{item: line_item, note: "ящик", ghost: ItemID.new()},
        items: MapSet.new([high, low]),
        limits: %{high => high_count, low => low_count},
        notes: %{notes_key => note_count}
      }

      assert Details.build(created(payload, by)) ==
               {"Описание собрано",
                [
                  %{label: "Позиция", kind: :ref, entity: :stock_item, value: item},
                  %{label: "Владелец", kind: :user, value: owner},
                  %{label: "Название", kind: :text, value: title},
                  %{label: "Снимок", kind: :text, value: snapshot},
                  %{
                    label: "Строка",
                    kind: :group,
                    value: [
                      %{label: "Позиция", kind: :ref, entity: :stock_item, value: line_item},
                      %{label: "Примечание", kind: :text, value: "ящик"}
                    ]
                  },
                  %{
                    label: "Позиции",
                    kind: :set,
                    value: [
                      %{kind: :ref, entity: :stock_item, value: low},
                      %{kind: :ref, entity: :stock_item, value: high}
                    ]
                  },
                  %{
                    label: "Лимиты",
                    kind: :map,
                    value: [
                      %{
                        key: %{label: "Позиция", kind: :ref, entity: :stock_item, value: low},
                        value: %{label: "Лимит", kind: :number, value: low_count}
                      },
                      %{
                        key: %{label: "Позиция", kind: :ref, entity: :stock_item, value: high},
                        value: %{label: "Лимит", kind: :number, value: high_count}
                      }
                    ]
                  },
                  %{
                    label: "Заметки",
                    kind: :list,
                    value: [
                      %{
                        kind: :group,
                        value: [
                          %{label: "Источник", kind: :ref, entity: :stock_item, value: notes_key},
                          %{label: "Значение", kind: :number, value: note_count}
                        ]
                      }
                    ]
                  }
                ]}
    end

    test "словарь ссылок: id описанных узлов, а вид `:text` и id `:id` ссылкой не выходят" do
      [item, line_item, key, set_item, free_key] = for _ <- 1..5, do: ItemID.new()
      owner = UserID.new()
      by = UserID.new()

      payload = %CreatedPayload{
        item: item,
        owner: owner,
        title: Name.new!("Болт"),
        snapshot: SnapshotID.new(),
        line: %Line{item: line_item, note: nil, ghost: ItemID.new()},
        items: MapSet.new([set_item]),
        limits: %{key => Count.new!(1)},
        notes: %{free_key => Count.new!(2)}
      }

      names = Map.new([by, item, owner, line_item, key, set_item, free_key], &{&1, "Имя"})

      assert Refs.get(created(payload, by), context(names)) == {:ok, names}
    end

    test "канонический порядок множества и пар словаря живёт в описании" do
      ids = for _ <- 1..40, do: ItemID.new()
      [low, high | _rest] = Enum.sort_by(ids, &ItemID.value/1)
      by = UserID.new()

      payload = %CreatedPayload{
        item: low,
        owner: by,
        title: Name.new!("Болт"),
        snapshot: SnapshotID.new(),
        line: %Line{item: low, note: nil, ghost: high},
        items: MapSet.new([high, low]),
        limits: Map.new([high, low], &{&1, Count.new!(1)}),
        notes: %{}
      }

      {_title, details} = Details.build(created(payload, by))

      assert %{kind: :set, value: [%{value: ^low}, %{value: ^high}]} =
               Enum.find(details, &(&1.label == "Позиции"))

      assert %{kind: :map, value: [%{key: %{value: ^low}}, %{key: %{value: ^high}}]} =
               Enum.find(details, &(&1.label == "Лимиты"))
    end

    test "изменение: стороны описаны как элементы, ссылки собраны с обеих" do
      [old_item, new_item] = for _ <- 1..2, do: ItemID.new()
      by = UserID.new()
      payload = ChangedPayload.new(old_item, new_item)

      assert Details.build(changed(payload, by)) ==
               {"Позиция изменена",
                [
                  %{
                    label: "Позиция",
                    kind: :change,
                    old: %{kind: :ref, entity: :stock_item, value: old_item},
                    new: %{kind: :ref, entity: :stock_item, value: new_item}
                  }
                ]}

      names = Map.new([by, old_item, new_item], &{&1, "Имя"})
      assert Refs.get(changed(payload, by), context(names)) == {:ok, names}
    end
  end

  # ---

  defp context(names), do: Context.new(%{names: names})

  defp created(payload, by), do: Created.new(payload, AggID.new(), Version.new(), by, At.now!())

  defp changed(payload, by), do: Changed.new(payload, AggID.new(), Version.new(), by, At.now!())
end
