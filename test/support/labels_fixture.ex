defmodule Core.LabelsFixture do
  @moduledoc """
  События и нагрузки с подписями (`Core.Labels.*`): нагрузка по полям всех видов сведений,
  нагрузка с полями Enum, нагрузка с вложенными struct'ами, списками, семейством и Prim-композитом,
  нагрузка с ручным плагином и полями `text:`, изменения «было → стало» (`Core.Es.ValueChanged` и
  ручной struct с `value:`), нагрузка-Prim и событие без нагрузки.
  """

  alias Core.EventFixture.ActorID
  alias Core.EventFixture.AggID

  defmodule Name do
    @moduledoc "Название."

    use Core.Prim.String,
      name: "Название",
      min_len: 1,
      max_len: 50
  end

  defmodule Count do
    @moduledoc "Количество."

    use Core.Prim.Integer,
      name: "Количество",
      min: 0
  end

  defmodule Amount do
    @moduledoc "Сумма."

    use Core.Prim.Decimal,
      name: "Сумма",
      scale: 2
  end

  defmodule Day do
    @moduledoc "День."

    use Core.Prim.Date,
      name: "День"
  end

  defmodule Moment do
    @moduledoc "Момент."

    use Core.Prim.DateTime,
      name: "Момент"
  end

  defmodule Status do
    @moduledoc """
    Статус.

    | Значение | Описание |
    |---|---|
    | `:draft` | черновик |
    | `:active` | действует |
    | `:archived` | убран в архив |
    """

    use Core.Enum,
      name: "Статус",
      values: ~w(draft active archived)a

    use Core.Labels.Values,
      labels: [
        active: "Активна",
        archived: "В архиве",
        draft: "Черновик"
      ]
  end

  defmodule Title do
    @moduledoc "Заголовок — Prim-композит над названием."

    use Core.Prim.Compose,
      name: "Заголовок",
      of: Core.LabelsFixture.Name
  end

  defmodule Address do
    @moduledoc "Адрес — вложенный struct сведений со спекой видимых полей."

    defstruct [:city, :zip, :checksum]

    use Core.Labels.Fields,
      fields: [
        city: [prim: Core.LabelsFixture.Name],
        zip: [type: :string, optional: true]
      ],
      labels: [
        city: "Город",
        zip: "Индекс",
        checksum: :hidden
      ]
  end

  defmodule Line do
    @moduledoc "Позиция — элемент списка struct'ов."

    defstruct [:title, :count]

    use Core.Labels.Fields,
      fields: [
        title: [prim: Core.LabelsFixture.Name],
        count: [prim: Core.LabelsFixture.Count]
      ],
      labels: [
        title: "Наименование",
        count: "Количество"
      ]
  end

  defmodule Shape do
    @moduledoc "Фигура — семейство вариантов."

    defmodule Circle do
      @moduledoc "Вариант: круг."

      defstruct [:radius, kind: :circle]

      use Core.Labels.Fields,
        fields: [radius: [type: :pos_integer]],
        labels: [radius: "Радиус", kind: :hidden]
    end

    defmodule Rect do
      @moduledoc "Вариант: прямоугольник."

      defstruct [:width, :height, kind: :rect]

      use Core.Labels.Fields,
        fields: [width: [type: :pos_integer], height: [type: :pos_integer]],
        labels: [width: "Ширина", height: "Высота", kind: :hidden]
    end
  end

  defmodule Texts do
    @moduledoc "Функции текста значений без собственного модуля."

    @doc "Источник: один из двух struct'ов."
    @spec origin(struct()) :: String.t()

    def origin(%Core.LabelsFixture.Address{}), do: "Адрес"
    def origin(%Core.LabelsFixture.Line{}), do: "Позиция"
  end

  defmodule Event do
    @moduledoc false

    defmodule Updated do
      @moduledoc "Событие с нагрузкой по полям: поле каждого вида, необязательное и скрытое."

      alias Core.LabelsFixture

      defmodule Payload do
        @moduledoc "Нагрузка по полям."

        use Core.Es.Event.Payload,
          fields: [
            name: [prim: LabelsFixture.Name],
            count: [prim: LabelsFixture.Count],
            amount: [prim: LabelsFixture.Amount, optional: true],
            day: [prim: LabelsFixture.Day],
            moment: [prim: LabelsFixture.Moment],
            note: [type: :string, optional: true],
            urgent: [type: :boolean],
            rank: [type: :pos_integer],
            source: [type: :string]
          ]

        use Core.Labels.Fields,
          labels: [
            name: "Название",
            count: "Количество",
            amount: "Сумма",
            day: "День",
            moment: "Момент",
            note: "Примечание",
            urgent: "Срочно",
            rank: "Ранг",
            source: :hidden
          ]
      end

      use Core.Es.Event,
        aggregate_id: AggID,
        by: ActorID,
        payload: Payload

      use Core.Labels.Event, title: "Запись изменена"
    end

    defmodule StatusChanged do
      @moduledoc "Событие с нагрузкой из полей Enum: обязательное и необязательное."

      defmodule Payload do
        @moduledoc "Нагрузка с полями Enum."

        use Core.Es.Event.Payload,
          fields: [
            status: [enum: Core.LabelsFixture.Status],
            previous: [enum: Core.LabelsFixture.Status, optional: true]
          ]

        use Core.Labels.Fields,
          labels: [
            status: "Статус",
            previous: "Прежний статус"
          ]
      end

      use Core.Es.Event,
        aggregate_id: AggID,
        by: ActorID,
        payload: Payload

      use Core.Labels.Event, title: "Статус сменён"
    end

    defmodule Shipped do
      @moduledoc "Событие с вложенным struct'ом, списками, семейством и Prim-композитом."

      alias Core.LabelsFixture

      defmodule Payload do
        @moduledoc "Нагрузка с вложенностью."

        use Core.Es.Event.Payload,
          fields: [
            address: [entity: LabelsFixture.Address],
            backup: [entity: LabelsFixture.Address, optional: true],
            lines: [list: [entity: LabelsFixture.Line]],
            counts: [list: [prim: LabelsFixture.Count]],
            shape: [union: LabelsFixture.Shape],
            title: [prim: LabelsFixture.Title]
          ]

        use Core.Labels.Fields,
          labels: [
            address: "Адрес",
            backup: "Запасной адрес",
            lines: "Позиции",
            counts: "Счётчики",
            shape: "Фигура",
            title: "Заголовок"
          ]
      end

      use Core.Es.Event,
        aggregate_id: AggID,
        by: ActorID,
        payload: Payload

      use Core.Labels.Event, title: "Заказ отправлен"
    end

    defmodule Tagged do
      @moduledoc "Событие с нагрузкой ручного плагина: спека видимых полей `fields:` и поля `text:`."

      alias Core.LabelsFixture

      defmodule Payload do
        @moduledoc "Нагрузка без спеки полей."

        defstruct [:origin, :tags, :count, :trace]

        use Core.Labels.Fields,
          fields: [
            origin: [text: &LabelsFixture.Texts.origin/1],
            tags: [list: [text: &Atom.to_string/1]],
            count: [prim: LabelsFixture.Count]
          ],
          labels: [
            origin: "Источник",
            tags: "Метки",
            count: "Количество",
            trace: :hidden
          ]
      end

      use Core.Es.Event,
        aggregate_id: AggID,
        by: ActorID,
        payload: Payload

      use Core.Labels.Event, title: "Метки расставлены"
    end

    defmodule NameChanged do
      @moduledoc "Событие «было → стало» на Prim: `Core.Es.ValueChanged` с подписью изменения."

      defmodule Payload do
        @moduledoc "Изменение названия."

        use Core.Es.ValueChanged,
          type: Core.LabelsFixture.Name

        use Core.Labels.Fields, change: "Название"
      end

      use Core.Es.Event,
        aggregate_id: AggID,
        by: ActorID,
        payload: Payload

      use Core.Labels.Event, title: "Название изменено"
    end

    defmodule StatusSwitched do
      @moduledoc "Событие «было → стало» на Enum: стороны могут быть без значения."

      defmodule Payload do
        @moduledoc "Изменение статуса."

        use Core.Es.ValueChanged,
          type: Core.LabelsFixture.Status,
          nilable: true

        use Core.Labels.Fields, change: "Статус"
      end

      use Core.Es.Event,
        aggregate_id: AggID,
        by: ActorID,
        payload: Payload

      use Core.Labels.Event, title: "Статус переключён"
    end

    defmodule OriginChanged do
      @moduledoc "Событие с ручным struct'ом изменения: вид значения — `value: [text: …]`."

      defmodule Payload do
        @moduledoc "Изменение источника: значение — один из двух struct'ов."

        defstruct [:old_value, :new_value]

        use Core.Labels.Fields,
          change: "Источник",
          value: [text: &Core.LabelsFixture.Texts.origin/1]
      end

      use Core.Es.Event,
        aggregate_id: AggID,
        by: ActorID,
        payload: Payload

      use Core.Labels.Event, title: "Источник изменён"
    end

    defmodule TagsChanged do
      @moduledoc "Событие с ручным struct'ом изменения: вид значения — `value: [list: …]`."

      defmodule Payload do
        @moduledoc "Изменение меток: значение — список открытых атомов."

        defstruct [:old_value, :new_value]

        use Core.Labels.Fields,
          change: "Метки",
          value: [list: [text: &Atom.to_string/1]]
      end

      use Core.Es.Event,
        aggregate_id: AggID,
        by: ActorID,
        payload: Payload

      use Core.Labels.Event, title: "Метки изменены"
    end

    defmodule Renamed do
      @moduledoc "Событие с нагрузкой-Prim."

      use Core.Es.Event,
        aggregate_id: AggID,
        by: ActorID,
        payload: Core.LabelsFixture.Name

      use Core.Labels.Event,
        title: "Запись переименована",
        payload: "Название"
    end

    defmodule Closed do
      @moduledoc "Событие без нагрузки."

      use Core.Es.Event,
        aggregate_id: AggID,
        by: ActorID,
        payload: nil

      use Core.Labels.Event, title: "Запись закрыта"
    end
  end
end
