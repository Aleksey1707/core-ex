defmodule Core.LabelsFixture do
  @moduledoc """
  События и нагрузки с подписями (`Core.Labels.*`): нагрузка по полям всех видов сведений,
  нагрузка с полями Enum, нагрузка с вложенными struct'ами, списками, семейством и Prim-композитом,
  нагрузка с ручным плагином и полями `text:`, изменения «было → стало» (`Core.Es.ValueChanged` и
  ручной struct с `value:`), нагрузка-Prim, событие без нагрузки, нагрузка с id каждого вида,
  Prim текстом и map'ой с id в ключах, нагрузка с id без вида, событие от учётной записи с id в варианте
  семейства; фикстурные резолверы имён; модуль дампа сведений на wire и их схемы (`Core.Web.Labels`).

  Плагин семейства `Core.LabelsFixture.Shape.Codec` и кодек `Core.LabelsFixture.Event.Codec` — полный
  набор ратчета полноты: в кодек не входят событие с id без вида и событие другого агрегата.
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

  defmodule Names do
    @moduledoc """
    Имена фикстурных резолверов: из `:names` контекста, id вне него — отказ `:not_found`.

    Каждый вызов резолвера шлёт процессу теста `{:get_names, резолвер, ids}`.
    """

    alias Core.Context
    alias Core.Error

    require Error

    @doc "Имена по id для резолвера `resolver`."
    @spec get(module(), [struct()], Context.t()) :: {:ok, %{struct() => String.t() | nil}} | {:error, Error.t()}

    def get(resolver, ids, %Context{} = context) when is_atom(resolver) and is_list(ids) do
      send(self(), {:get_names, resolver, ids})
      names = Context.find(context, :names) || %{}

      case Enum.reject(ids, &Map.has_key?(names, &1)) do
        [] -> {:ok, Map.take(names, ids)}
        missing -> {:error, Error.domain(code: :not_found, ns: resolver, message: "Запись не найдена", detail: missing)}
      end
    end
  end

  defmodule ItemQuery do
    @moduledoc "Резолвер имён позиций."

    @behaviour Core.Labels.Resolver

    @spec get_names([struct()], Core.Context.t()) :: Core.Result.t(%{struct() => String.t() | nil})

    @impl true
    def get_names(ids, context), do: Core.LabelsFixture.Names.get(__MODULE__, ids, context)
  end

  defmodule UserQuery do
    @moduledoc "Резолвер имён учётных записей."

    @behaviour Core.Labels.Resolver

    @spec get_names([struct()], Core.Context.t()) :: Core.Result.t(%{struct() => String.t() | nil})

    @impl true
    def get_names(ids, context), do: Core.LabelsFixture.Names.get(__MODULE__, ids, context)
  end

  defmodule ItemID do
    @moduledoc "Id позиции — ссылка на запись."

    use Core.Prim.UUID,
      name: "Позиция",
      version: 7

    use Core.Labels.ID,
      kind: :ref,
      entity: :stock_item,
      resolver: Core.LabelsFixture.ItemQuery
  end

  defmodule UserID do
    @moduledoc "Id учётной записи — ссылка на учётную запись."

    use Core.Prim.UUID,
      name: "Пользователь",
      version: 7

    use Core.Labels.ID,
      kind: :user,
      resolver: Core.LabelsFixture.UserQuery
  end

  defmodule SnapshotID do
    @moduledoc "Id снимка — только id."

    use Core.Prim.UUID,
      name: "Снимок",
      version: 7

    use Core.Labels.ID, kind: :id
  end

  defmodule BareID do
    @moduledoc "Id без вида в сведениях."

    use Core.Prim.UUID,
      name: "Без вида",
      version: 7
  end

  defmodule AuthorID do
    @moduledoc "Автор — Prim-композит над id учётной записи."

    use Core.Prim.Compose,
      name: "Автор",
      of: Core.LabelsFixture.UserID
  end

  defmodule Unit do
    @moduledoc "Единица измерения — код, который человек читает по имени."

    use Core.Prim.String,
      name: "Единица",
      min_len: 1,
      max_len: 10

    use Core.Labels.Text, with: &Core.LabelsFixture.Texts.unit/1
  end

  defmodule BaseUnit do
    @moduledoc "Базовая единица — Prim-композит над единицей с текстом."

    use Core.Prim.Compose,
      name: "Базовая единица",
      of: Core.LabelsFixture.Unit
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

    defmodule Pin do
      @moduledoc "Вариант: метка на позиции."

      defstruct [:item, kind: :pin]

      use Core.Labels.Fields,
        fields: [item: [prim: Core.LabelsFixture.ItemID]],
        labels: [item: "Позиция", kind: :hidden]
    end
  end

  defmodule Shape.Codec do
    @moduledoc "Варианты фигуры: форма без обёртки, дискриминатор `kind`."

    alias Core.LabelsFixture.Shape

    use Core.Codec.Plugin,
      union: Shape,
      variants: [
        {Shape.Circle, [kind: :circle], radius: [type: :pos_integer]},
        {Shape.Rect, [kind: :rect], width: [type: :pos_integer], height: [type: :pos_integer]},
        {Shape.Pin, [kind: :pin], item: [prim: Core.LabelsFixture.ItemID]}
      ]
  end

  defmodule Texts do
    @moduledoc "Функции текста значений без собственного модуля."

    @doc "Источник: один из двух struct'ов."
    @spec origin(struct()) :: String.t()

    def origin(%Core.LabelsFixture.Address{}), do: "Адрес"
    def origin(%Core.LabelsFixture.Line{}), do: "Позиция"

    @doc "Имя единицы измерения по коду."
    @spec unit(Core.LabelsFixture.Unit.t()) :: String.t()

    def unit(%Core.LabelsFixture.Unit{value: "kg"}), do: "Килограмм"
    def unit(%Core.LabelsFixture.Unit{value: "pc"}), do: "Штука"
  end

  defmodule UserRef do
    @moduledoc "OpenAPI-схема ссылки на учётную запись `%{id, login}`."

    alias OpenApiSpex.Schema

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "UserRef",
        type: :object,
        properties: %{id: %Schema{type: :string}, login: %Schema{type: :string, nullable: true}},
        required: ~w(id login)a
      },
      struct?: false
    )
  end

  defmodule Wire do
    @moduledoc """
    Дамп сведений на wire и их схема: внешний профиль кодека, ссылка на учётную запись `%{id, login}`.
    """

    use Core.Web.Labels,
      codec: Core.CodecFixture.External,
      user_ref: [
        dump: &Core.LabelsFixture.Wire.user_ref/2,
        schema: Core.LabelsFixture.UserRef
      ]

    @doc "Ссылка на учётную запись: дамп id и имя."
    @spec user_ref(String.t(), String.t() | nil) :: %{id: String.t(), login: String.t() | nil}

    def user_ref(id, login) when is_binary(id), do: %{id: id, login: login}
  end

  defmodule Event do
    @moduledoc false

    @type t :: struct()

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

    defmodule Linked do
      @moduledoc "Событие с id каждого вида, Prim текстом и map'ой с id в ключах."

      alias Core.LabelsFixture

      defmodule Payload do
        @moduledoc "Нагрузка со ссылками."

        use Core.Es.Event.Payload,
          fields: [
            item: [prim: LabelsFixture.ItemID],
            backup: [prim: LabelsFixture.ItemID, optional: true],
            items: [list: [prim: LabelsFixture.ItemID]],
            owner: [prim: LabelsFixture.UserID],
            author: [prim: LabelsFixture.AuthorID],
            snapshot: [prim: LabelsFixture.SnapshotID],
            unit: [prim: LabelsFixture.Unit],
            base_unit: [prim: LabelsFixture.BaseUnit],
            limits: [type: :map, optional: true]
          ]

        use Core.Labels.Fields,
          labels: [
            item: "Позиция",
            backup: "Запасная позиция",
            items: "Позиции",
            owner: "Владелец",
            author: "Автор",
            snapshot: "Снимок",
            unit: "Единица",
            base_unit: "Базовая единица",
            limits: [label: "Лимиты", key: "Позиция", value: "Лимит"]
          ]
      end

      use Core.Es.Event,
        aggregate_id: AggID,
        by: ActorID,
        payload: Payload

      use Core.Labels.Event, title: "Позиция связана"
    end

    defmodule Assigned do
      @moduledoc "Событие позиции от учётной записи: id в нагрузке, в варианте семейства, рядом даты и сумма."

      alias Core.LabelsFixture

      defmodule Payload do
        @moduledoc "Нагрузка назначения."

        use Core.Es.Event.Payload,
          fields: [
            assignee: [prim: LabelsFixture.UserID],
            shape: [union: LabelsFixture.Shape],
            amount: [prim: LabelsFixture.Amount],
            day: [prim: LabelsFixture.Day],
            moment: [prim: LabelsFixture.Moment]
          ]

        use Core.Labels.Fields,
          labels: [
            assignee: "Исполнитель",
            shape: "Фигура",
            amount: "Сумма",
            day: "День",
            moment: "Момент"
          ]
      end

      use Core.Es.Event,
        aggregate_id: LabelsFixture.ItemID,
        by: LabelsFixture.UserID,
        payload: Payload

      use Core.Labels.Event, title: "Исполнитель назначен"
    end

    defmodule Unmarked do
      @moduledoc "Событие с id без вида в сведениях."

      defmodule Payload do
        @moduledoc "Нагрузка с id без вида."

        use Core.Es.Event.Payload, fields: [ref: [prim: Core.LabelsFixture.BareID]]

        use Core.Labels.Fields, labels: [ref: "Ссылка"]
      end

      use Core.Es.Event,
        aggregate_id: AggID,
        by: ActorID,
        payload: Payload

      use Core.Labels.Event, title: "Ссылка без вида"
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

  defmodule Event.Codec do
    @moduledoc "Кодек событий с подписями — полный набор ратчета полноты (`Core.Labels.CompletenessCase`)."

    alias Core.LabelsFixture.Event

    @tag_by_mod %{
      Event.Updated => "labels.updated",
      Event.StatusChanged => "labels.status_changed",
      Event.Shipped => "labels.shipped",
      Event.Tagged => "labels.tagged",
      Event.NameChanged => "labels.name_changed",
      Event.StatusSwitched => "labels.status_switched",
      Event.OriginChanged => "labels.origin_changed",
      Event.TagsChanged => "labels.tags_changed",
      Event.Linked => "labels.linked",
      Event.Renamed => "labels.renamed",
      Event.Closed => "labels.closed"
    }

    use Core.Es.Event.Codec,
      event: Event,
      type: "labels",
      tags: @tag_by_mod
  end
end
