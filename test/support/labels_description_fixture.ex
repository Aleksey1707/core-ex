defmodule Core.LabelsDescriptionFixture do
  @moduledoc """
  Малый набор описания значения (`Core.Labels.Description`): нагрузка с листом, группой,
  множеством, словарём и свободной map'ой и событие «было → стало».

  Тесты описания идут через публичные входы сведений (`Core.Labels.Details.build/1`) и словаря
  ссылок (`Core.Labels.Refs.get/2`); кодек набору не нужен.
  """

  alias Core.LabelsFixture

  defmodule Line do
    @moduledoc "Вложенный struct описания: видимая поле-ссылка, текст и скрытая ссылка."

    use Core.Struct,
      fields: [
        item: [prim: LabelsFixture.ItemID],
        note: [type: :string],
        ghost: [prim: LabelsFixture.ItemID]
      ]

    use Core.Labels.Fields,
      labels: [item: "Позиция", note: "Примечание", ghost: :hidden]
  end

  defmodule Payload do
    @moduledoc "Нагрузка: ссылка, учётная запись, текст, группа, множество, словарь и свободная map'а."

    use Core.Es.Event.Payload,
      fields: [
        item: [prim: LabelsFixture.ItemID],
        owner: [prim: LabelsFixture.UserID],
        title: [prim: LabelsFixture.Name],
        snapshot: [prim: LabelsFixture.SnapshotID],
        line: [entity: Line, personal: false],
        items: [set: [prim: LabelsFixture.ItemID]],
        limits: [map: [key: [prim: LabelsFixture.ItemID], value: [prim: LabelsFixture.Count]]],
        notes: [type: :map, personal: false]
      ]

    use Core.Labels.Fields,
      labels: [
        item: "Позиция",
        owner: "Владелец",
        title: "Название",
        snapshot: "Снимок",
        line: "Строка",
        items: "Позиции",
        limits: [label: "Лимиты", key: "Позиция", value: "Лимит"],
        notes: [label: "Заметки", key: "Источник", value: "Значение"]
      ]
  end

  defmodule Created do
    @moduledoc "Событие описания."

    use Core.Es.Event,
      family: LabelsFixture.Event.Family,
      payload: Payload

    use Core.Labels.Event, title: "Описание собрано"
  end

  defmodule Changed do
    @moduledoc "Событие «было → стало» на ссылке."

    defmodule Payload do
      @moduledoc "Изменение позиции."

      use Core.Es.ValueChanged,
        type: LabelsFixture.ItemID

      use Core.Labels.Fields, change: "Позиция"
    end

    use Core.Es.Event,
      family: LabelsFixture.Event.Family,
      payload: Payload

    use Core.Labels.Event, title: "Позиция изменена"
  end
end
