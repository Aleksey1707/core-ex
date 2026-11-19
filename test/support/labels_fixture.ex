defmodule Core.LabelsFixture do
  @moduledoc """
  События и нагрузки с подписями (`Core.Labels.*`): нагрузка по полям всех видов сведений,
  нагрузка с полями Enum, нагрузка с вложенными struct'ами, списками, семейством и Prim-композитом,
  нагрузка с ручным плагином и полями `text:`, нагрузка с вложенной структурой по полям
  (`Core.Struct`), изменения «было → стало» (`Core.Es.ValueChanged` и ручной struct с `value:`),
  нагрузка-Prim, событие без нагрузки, нагрузка с id каждого вида,
  Prim текстом и map'ой с id в ключах, нагрузка с id без вида, событие другого агрегата с id в варианте
  семейства, id в скрытых полях нагрузки, вложенного struct'а, варианта семейства и map'ы, изменение на
  id, id под `text:` в поле, списке, множестве и значении изменения; автор каждого события — учётная
  запись с резолвером; фикстурные резолверы имён; событие с ПДн-полями каждого вида сведений и изменение на
  ПДн-значении; нагрузка с полями-множествами и полями-словарями; событие страницы событий со
  сведениями (`Core.Web.Event`, `labels: true`).

  Плагины семейств `Core.LabelsFixture.Shape.Codec` и `Core.LabelsFixture.Contact.Codec` и кодеки
  `Core.LabelsFixture.Event.Codec`, `Core.LabelsFixture.Event.ContactFamily.Codec` и
  `Core.LabelsFixture.Event.ManualFamily.Codec` — полный набор ратчета полноты: в кодеки не входят
  событие с id без вида, событие другого агрегата, событие со скрытыми id (у его семейства
  `Core.LabelsFixture.Mark` плагина нет), изменение на id и события с id под `text:`. Нагрузку событий
  `Core.LabelsFixture.Event.Codec` и `Core.LabelsFixture.Event.ContactFamily.Codec` дампят фасады:
  кодеки, плагины семейств, плагин вложенных struct'ов `Core.LabelsFixture.Codec` и ручной плагин
  нагрузки `Core.LabelsFixture.Event.Limited.Codec` зарегистрированы в `Core.CodecFixture.plugins/0`.
  События с нагрузкой без плагина и с вложенной структурой по полям без плагина — в семействе
  `ManualFamily`, его кодек в фасад не входит.
  """

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

  defmodule Holder do
    @moduledoc "Имя владельца — ПДн."

    use Core.Prim.String,
      name: "Имя владельца",
      min_len: 1,
      max_len: 50,
      personal: true
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
    alias Core.Result

    require Error

    @doc "Имена по id для резолвера `resolver`."
    @spec get(module(), [struct()], Context.t()) :: Result.t(%{struct() => String.t() | nil})

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

    use Core.Struct,
      fields: [
        city: [prim: Core.LabelsFixture.Name],
        zip: [type: :string, optional: true, default: nil],
        checksum: [type: :string, optional: true, default: nil]
      ]

    use Core.Labels.Fields,
      labels: [
        city: "Город",
        zip: "Индекс",
        checksum: :hidden
      ]
  end

  defmodule PersonalPlace do
    @moduledoc "Декларативный тип с ПДн-местами: подписи читают общую декларацию, места в спеке сняты."

    use Core.Struct,
      fields: [
        name: [prim: Core.LabelsFixture.Name, personal: true],
        phones: [list: [prim: Core.PrimFixture.Personal, personal: true]]
      ]

    use Core.Labels.Fields,
      labels: [
        name: "Имя",
        phones: "Телефоны"
      ]
  end

  defmodule Line do
    @moduledoc "Позиция — элемент списка struct'ов."

    use Core.Struct,
      fields: [
        title: [prim: Core.LabelsFixture.Name],
        count: [prim: Core.LabelsFixture.Count]
      ]

    use Core.Labels.Fields,
      labels: [
        title: "Наименование",
        count: "Количество"
      ]
  end

  defmodule Parcel do
    @moduledoc "Посылка — вложенный struct сведений структурой по полям: вид полей из `use Core.Struct`."

    use Core.Struct,
      fields: [
        name: [prim: Core.LabelsFixture.Name],
        count: [prim: Core.LabelsFixture.Count],
        note: [type: :string, optional: true],
        trace: [type: :string]
      ]

    use Core.Labels.Fields,
      labels: [
        name: "Название",
        count: "Количество",
        note: "Примечание",
        trace: :hidden
      ]
  end

  defmodule Shape do
    @moduledoc "Фигура — семейство вариантов."

    defmodule Kind do
      @moduledoc """
      Вид фигуры.

      | Значение | Описание |
      |---|---|
      | `:circle` | круг |
      | `:rect` | прямоугольник |
      | `:pin` | метка |
      """

      use Core.Enum,
        name: "Вид фигуры",
        values: ~w(circle rect pin)a
    end

    defmodule Circle do
      @moduledoc "Вариант: круг."

      use Core.Struct,
        fields: [
          radius: [type: :pos_integer],
          kind: [enum: Core.LabelsFixture.Shape.Kind, default: :circle]
        ]

      use Core.Labels.Fields,
        labels: [radius: "Радиус", kind: :hidden]
    end

    defmodule Rect do
      @moduledoc "Вариант: прямоугольник."

      use Core.Struct,
        fields: [
          width: [type: :pos_integer],
          height: [type: :pos_integer],
          kind: [enum: Core.LabelsFixture.Shape.Kind, default: :rect]
        ]

      use Core.Labels.Fields,
        labels: [width: "Ширина", height: "Высота", kind: :hidden]
    end

    defmodule Pin do
      @moduledoc "Вариант: метка на позиции."

      use Core.Struct,
        fields: [
          item: [prim: Core.LabelsFixture.ItemID],
          kind: [enum: Core.LabelsFixture.Shape.Kind, default: :pin]
        ]

      use Core.Labels.Fields,
        labels: [item: "Позиция", kind: :hidden]
    end

    use Core.Union,
      variants: [
        {Core.LabelsFixture.Shape.Circle, [kind: :circle]},
        {Core.LabelsFixture.Shape.Rect, [kind: :rect]},
        {Core.LabelsFixture.Shape.Pin, [kind: :pin]}
      ]
  end

  defmodule Shape.Codec do
    @moduledoc "Варианты фигуры: форма без обёртки, дискриминатор `kind`."

    use Core.Codec.Plugin, union: Core.LabelsFixture.Shape
  end

  defmodule Contact do
    @moduledoc "Способ связи — семейство с вариантами-Prim: текст, plain-виды, id каждого вида и композит."

    defmodule Phone do
      @moduledoc "Вариант: телефон, который человек читает текстом функции."

      use Core.Prim.String,
        name: "Телефон",
        min_len: 5,
        max_len: 32

      use Core.Labels.Text, with: &Core.LabelsFixture.Texts.phone/1
    end

    defmodule Code do
      @moduledoc "Вариант: код без объявления вида — plain-вид Prim."

      use Core.Prim.Integer,
        name: "Код",
        min: 0
    end

    defmodule Note do
      @moduledoc "Вариант: заметка без объявления вида — plain-вид текста."

      use Core.Prim.String,
        name: "Заметка",
        min_len: 1,
        max_len: 64
    end

    defmodule Due do
      @moduledoc "Вариант: срок без объявления вида — plain-вид даты."

      use Core.Prim.Date, name: "Срок"
    end

    defmodule Seen do
      @moduledoc "Вариант: отметка времени без объявления вида — plain-вид дата-времени."

      use Core.Prim.DateTime, name: "Отметка"
    end

    defmodule Item do
      @moduledoc "Вариант: позиция — ссылка на запись."

      use Core.Prim.UUID,
        name: "Позиция",
        version: 7

      use Core.Labels.ID,
        kind: :ref,
        entity: :stock_item,
        resolver: Core.LabelsFixture.ItemQuery
    end

    defmodule User do
      @moduledoc "Вариант: учётная запись — ссылка на учётную запись."

      use Core.Prim.UUID,
        name: "Пользователь",
        version: 7

      use Core.Labels.ID,
        kind: :user,
        resolver: Core.LabelsFixture.UserQuery
    end

    defmodule Snapshot do
      @moduledoc "Вариант: снимок — только id."

      use Core.Prim.UUID,
        name: "Снимок",
        version: 7

      use Core.Labels.ID, kind: :id
    end

    defmodule Alias do
      @moduledoc "Вариант: Prim-композит над телефоном — вид базы."

      use Core.Prim.Compose,
        name: "Псевдоним телефона",
        of: Core.LabelsFixture.Contact.Phone
    end

    use Core.Union,
      variants: [
        {Core.LabelsFixture.Contact.Phone, "phone"},
        {Core.LabelsFixture.Contact.Code, "code"},
        {Core.LabelsFixture.Contact.Note, "note"},
        {Core.LabelsFixture.Contact.Due, "due"},
        {Core.LabelsFixture.Contact.Seen, "seen"},
        {Core.LabelsFixture.Contact.Item, "item"},
        {Core.LabelsFixture.Contact.User, "user"},
        {Core.LabelsFixture.Contact.Snapshot, "snapshot"},
        {Core.LabelsFixture.Contact.Alias, "alias"}
      ]
  end

  defmodule Contact.Codec do
    @moduledoc "Варианты способа связи: форма без обёртки, тег адреса."

    use Core.Codec.Plugin, union: Core.LabelsFixture.Contact
  end

  defmodule Seal do
    @moduledoc "Пломба — вложенный struct сведений со скрытым id."

    defstruct [:item, :origin]

    use Core.Labels.Fields,
      fields: [item: [prim: Core.LabelsFixture.ItemID]],
      labels: [item: "Позиция", origin: :hidden]
  end

  defmodule Mark do
    @moduledoc "Отметка — семейство без плагина: вариант со скрытым id."

    defmodule Signed do
      @moduledoc "Вариант: подпись учётной записи."

      defstruct [:signer, :origin, kind: :signed]

      use Core.Labels.Fields,
        fields: [signer: [prim: Core.LabelsFixture.UserID]],
        labels: [signer: "Подписант", origin: :hidden, kind: :hidden]
    end
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

    @doc "Телефон текстом функции."
    @spec phone(Core.LabelsFixture.Contact.Phone.t()) :: String.t()

    def phone(%Core.LabelsFixture.Contact.Phone{value: value}), do: "Тел. " <> value

    @doc "Позиция без имени: id выходит текстом, а не ссылкой."
    @spec ref(Core.LabelsFixture.ItemID.t()) :: String.t()

    def ref(%Core.LabelsFixture.ItemID{}), do: "Позиция"
  end

  defmodule Quote do
    @moduledoc "Цитата: источник и набор источников выходят текстом, отметка скрыта."

    defstruct [:origin, :origins, :ghost]

    use Core.Labels.Fields,
      fields: [
        origin: [text: &Core.LabelsFixture.Texts.ref/1],
        origins: [set: [text: &Core.LabelsFixture.Texts.ref/1]]
      ],
      labels: [
        origin: "Источник",
        origins: "Источники",
        ghost: :hidden
      ]
  end

  defmodule Ghost do
    @moduledoc "Struct без объявления полей: достижим только скрытым полем."

    defstruct [:note]
  end

  defmodule Raw do
    @moduledoc "Значение-семейство без объявления полей и не Prim."

    defstruct [:note]
  end

  defmodule BareKind do
    @moduledoc """
    Вид без подписей значений: достижим только скрытым полем.

    | Значение | Описание |
    |---|---|
    | `:one` | первый |
    | `:two` | второй |
    """

    use Core.Enum,
      name: "Вид",
      values: ~w(one two)a
  end

  defmodule Shift do
    @moduledoc "Значение изменения: видимая позиция, `text:`-источник и скрытая отметка."

    defstruct [:item, :origin, :ghost]

    use Core.Labels.Fields,
      fields: [
        item: [prim: Core.LabelsFixture.ItemID],
        origin: [text: &Core.LabelsFixture.Texts.ref/1]
      ],
      labels: [
        item: "Позиция",
        origin: "Источник",
        ghost: :hidden
      ]
  end

  defmodule Event do
    @moduledoc false

    defmodule Family do
      @moduledoc "Семейство событий с подписями: объявлено раньше событий, вложенных в `Event`."

      use Core.Es.Event.Family,
        aggregate: Core.LabelsFixture,
        aggregate_id: AggID,
        by: UserID,
        codec: Core.LabelsFixture.Event.Codec

      @type t :: struct()
    end

    defmodule ItemFamily do
      @moduledoc "Семейство события другого агрегата — позиции `Assigned`."

      use Core.Es.Event.Family,
        aggregate: Core.LabelsFixture,
        aggregate_id: Core.LabelsFixture.ItemID,
        by: UserID,
        codec: Core.LabelsFixture.Event.ItemFamily.Codec

      @type t :: Core.LabelsFixture.Event.Assigned.t()
    end

    defmodule ContactFamily do
      @moduledoc "Семейство события с видимым семейством Prim-вариантов."

      use Core.Es.Event.Family,
        aggregate: Core.LabelsFixture,
        aggregate_id: AggID,
        by: UserID,
        codec: Core.LabelsFixture.Event.ContactFamily.Codec

      @type t :: Core.LabelsFixture.Event.Reachable.t()
    end

    defmodule ManualFamily do
      @moduledoc "Семейство событий с нагрузкой без плагина: в фасад их кодек не входит."

      use Core.Es.Event.Family,
        aggregate: Core.LabelsFixture,
        aggregate_id: AggID,
        by: UserID,
        codec: Core.LabelsFixture.Event.ManualFamily.Codec

      @type t :: struct()
    end

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
        family: Family,
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
        family: Family,
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
            shape: [union: LabelsFixture.Shape, personal: false],
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
        family: Family,
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
        family: ManualFamily,
        payload: Payload

      use Core.Labels.Event, title: "Метки расставлены"
    end

    defmodule Packed do
      @moduledoc "Событие с вложенной структурой по полям."

      defmodule Payload do
        @moduledoc "Нагрузка со структурой по полям."

        use Core.Es.Event.Payload, fields: [parcel: [entity: Core.LabelsFixture.Parcel]]

        use Core.Labels.Fields, labels: [parcel: "Посылка"]
      end

      use Core.Es.Event,
        family: ManualFamily,
        payload: Payload

      use Core.Labels.Event, title: "Посылка собрана"
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
        family: Family,
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
        family: Family,
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
        family: ManualFamily,
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
        family: ManualFamily,
        payload: Payload

      use Core.Labels.Event, title: "Метки изменены"
    end

    defmodule Carried do
      @moduledoc "Событие с ручной нагрузкой: список, множество и словарь вариантов семейства — без плагина."

      defmodule Payload do
        @moduledoc "Нагрузка: контейнеры над семейством Prim-вариантов."

        defstruct [:contacts, :reached, :reached_by]

        use Core.Labels.Fields,
          fields: [
            contacts: [list: [union: Core.LabelsFixture.Contact]],
            reached: [set: [union: Core.LabelsFixture.Contact]],
            reached_by: [map: [key: [type: :string], value: [union: Core.LabelsFixture.Contact]]]
          ],
          labels: [
            contacts: "Способы связи",
            reached: "Достигнутые",
            reached_by: "Достигнутые по источнику"
          ]
      end

      use Core.Es.Event,
        family: ManualFamily,
        payload: Payload

      use Core.Labels.Event, title: "Связь подтверждена"
    end

    defmodule ContactChanged do
      @moduledoc "Событие с ручным struct'ом изменения: значение — вариант семейства Prim-вариантов."

      defmodule Payload do
        @moduledoc "Изменение способа связи: значение — вариант семейства."

        defstruct [:old_value, :new_value]

        use Core.Labels.Fields,
          change: "Способ связи",
          value: [union: Core.LabelsFixture.Contact]
      end

      use Core.Es.Event,
        family: ManualFamily,
        payload: Payload

      use Core.Labels.Event, title: "Способ связи изменён"
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
            limits: [type: :map, personal: false, optional: true]
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
        family: Family,
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
            shape: [union: LabelsFixture.Shape, personal: false],
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
        family: ItemFamily,
        payload: Payload

      use Core.Labels.Event, title: "Исполнитель назначен"
    end

    defmodule Sealed do
      @moduledoc "Событие с id в скрытых полях: нагрузки, вложенного struct'а, варианта семейства и map'ы."

      alias Core.LabelsFixture

      defmodule Payload do
        @moduledoc "Нагрузка со скрытыми ссылками рядом с видимыми."

        use Core.Es.Event.Payload,
          fields: [
            item: [prim: LabelsFixture.ItemID],
            origin: [prim: LabelsFixture.ItemID],
            approver: [prim: LabelsFixture.UserID],
            seal: [entity: LabelsFixture.Seal, personal: false],
            mark: [union: LabelsFixture.Mark, personal: false],
            limits: [type: :map, personal: false],
            extra: [type: :map, personal: false]
          ]

        use Core.Labels.Fields,
          labels: [
            item: "Позиция",
            origin: :hidden,
            approver: :hidden,
            seal: "Пломба",
            mark: "Отметка",
            limits: [label: "Лимиты", key: "Позиция", value: "Лимит"],
            extra: :hidden
          ]
      end

      use Core.Es.Event,
        family: Family,
        payload: Payload

      use Core.Labels.Event, title: "Позиция опломбирована"
    end

    defmodule Moved do
      @moduledoc "Событие «было → стало» на id с резолвером."

      defmodule Payload do
        @moduledoc "Изменение позиции."

        use Core.Es.ValueChanged,
          type: Core.LabelsFixture.ItemID

        use Core.Labels.Fields, change: "Позиция"
      end

      use Core.Es.Event,
        family: Family,
        payload: Payload

      use Core.Labels.Event, title: "Позиция перенесена"
    end

    defmodule Quoted do
      @moduledoc "Событие с id под `text:`: в поле, в списке и в множестве."

      alias Core.LabelsFixture

      defmodule Payload do
        @moduledoc "Нагрузка, где id выходят текстом функции."

        defstruct [:origin, :origins, :origin_set]

        use Core.Labels.Fields,
          fields: [
            origin: [text: &LabelsFixture.Texts.ref/1],
            origins: [list: [text: &LabelsFixture.Texts.ref/1]],
            origin_set: [set: [text: &LabelsFixture.Texts.ref/1]]
          ],
          labels: [
            origin: "Источник",
            origins: "Источники",
            origin_set: "Набор источников"
          ]
      end

      use Core.Es.Event,
        family: Family,
        payload: Payload

      use Core.Labels.Event, title: "Источник процитирован"
    end

    defmodule Requoted do
      @moduledoc "Событие с ручным struct'ом изменения: id под `value: [text: …]`."

      defmodule Payload do
        @moduledoc "Изменение источника: значение — id, выходящий текстом."

        defstruct [:old_value, :new_value]

        use Core.Labels.Fields,
          change: "Источник",
          value: [text: &Core.LabelsFixture.Texts.ref/1]
      end

      use Core.Es.Event,
        family: Family,
        payload: Payload

      use Core.Labels.Event, title: "Цитата изменена"
    end

    defmodule RequotedMany do
      @moduledoc "Событие с ручным struct'ом изменения: id под `value: [list: [text: …]]`."

      defmodule Payload do
        @moduledoc "Изменение источников: значение — список id, выходящих текстом."

        defstruct [:old_value, :new_value]

        use Core.Labels.Fields,
          change: "Источники",
          value: [list: [text: &Core.LabelsFixture.Texts.ref/1]]
      end

      use Core.Es.Event,
        family: Family,
        payload: Payload

      use Core.Labels.Event, title: "Цитаты изменены"
    end

    defmodule Unmarked do
      @moduledoc "Событие с id без вида в сведениях."

      defmodule Payload do
        @moduledoc "Нагрузка с id без вида."

        use Core.Es.Event.Payload, fields: [ref: [prim: Core.LabelsFixture.BareID]]

        use Core.Labels.Fields, labels: [ref: "Ссылка"]
      end

      use Core.Es.Event,
        family: Family,
        payload: Payload

      use Core.Labels.Event, title: "Ссылка без вида"
    end

    defmodule Limited do
      @moduledoc "Событие с map'ой с id в ключах на ручном плагине: ключи дампит кодек."

      defmodule Payload do
        @moduledoc "Лимиты по позициям."

        defstruct [:limits]

        use Core.Labels.Fields,
          fields: [limits: [type: :map]],
          labels: [limits: [label: "Лимиты", key: "Позиция", value: "Лимит"]]
      end

      use Core.Es.Event,
        family: Family,
        payload: Payload

      use Core.Labels.Event, title: "Лимиты заданы"
    end

    defmodule Contacted do
      @moduledoc "Событие с ПДн-полями каждого вида сведений: текст, группа, список, ссылка, map'а."

      alias Core.LabelsFixture

      defmodule Payload do
        @moduledoc "Нагрузка с полями `subject:`."

        use Core.Es.Event.Payload,
          fields: [
            holder: [prim: LabelsFixture.Holder, subject: :aggregate_id],
            address: [entity: LabelsFixture.Address, personal: true, subject: :aggregate_id],
            aliases: [list: [prim: LabelsFixture.Holder], subject: :aggregate_id],
            owner: [prim: LabelsFixture.UserID, personal: true, subject: :aggregate_id],
            limits: [type: :map, personal: true, subject: :aggregate_id, optional: true]
          ]

        use Core.Labels.Fields,
          labels: [
            holder: "Владелец",
            address: "Адрес",
            aliases: "Псевдонимы",
            owner: "Учётная запись",
            limits: [label: "Лимиты", key: "Позиция", value: "Лимит"]
          ]
      end

      use Core.Es.Event,
        family: Family,
        payload: Payload

      use Core.Labels.Event, title: "Контакт указан"
    end

    defmodule HolderChanged do
      @moduledoc "Событие «было → стало» на ПДн-значении: стороны — поля с `subject:`."

      alias Core.LabelsFixture

      defmodule Payload do
        @moduledoc "Изменение владельца."

        use Core.Es.Event.Payload,
          fields: [
            old_value: [prim: LabelsFixture.Holder, subject: :aggregate_id],
            new_value: [prim: LabelsFixture.Holder, subject: :aggregate_id]
          ]

        use Core.Labels.Fields, change: "Владелец"
      end

      use Core.Es.Event,
        family: Family,
        payload: Payload

      use Core.Labels.Event, title: "Владелец сменён"
    end

    defmodule Renamed do
      @moduledoc "Событие с нагрузкой-Prim."

      use Core.Es.Event,
        family: Family,
        payload: Core.LabelsFixture.Name

      use Core.Labels.Event,
        title: "Запись переименована",
        payload: "Название"
    end

    defmodule Grouped do
      @moduledoc "Событие с полями-множествами и полями-словарями: id, Enum, числа, даты и struct'ы внутри."

      alias Core.LabelsFixture

      defmodule Payload do
        @moduledoc "Нагрузка с множествами и словарями; у словаря лимитов — подписи ключа и значения, id в скрытом словаре."

        use Core.Es.Event.Payload,
          fields: [
            items: [set: [prim: LabelsFixture.ItemID]],
            statuses: [set: [enum: LabelsFixture.Status]],
            counts: [set: [prim: LabelsFixture.Count]],
            backup: [set: [prim: LabelsFixture.ItemID], optional: true],
            limits: [map: [key: [prim: LabelsFixture.ItemID], value: [prim: LabelsFixture.Count]]],
            lines: [map: [key: [enum: LabelsFixture.Status], value: [entity: LabelsFixture.Line]]],
            origins: [map: [key: [type: :string], value: [prim: LabelsFixture.ItemID]]],
            days: [set: [prim: LabelsFixture.Day], optional: true]
          ]

        use Core.Labels.Fields,
          labels: [
            items: "Позиции",
            statuses: "Статусы",
            counts: "Счётчики",
            backup: "Запасные позиции",
            limits: [label: "Лимиты", key: "Позиция", value: "Лимит"],
            lines: "Строки по статусу",
            origins: :hidden,
            days: "Дни"
          ]
      end

      use Core.Es.Event,
        family: Family,
        payload: Payload

      use Core.Labels.Event, title: "Позиции сгруппированы"
    end

    defmodule Kinds do
      @moduledoc "Событие с полем каждого вида подписей: вид × сведения, ссылки и полнота."

      alias Core.LabelsFixture

      defmodule Payload do
        @moduledoc "Нагрузка с полем каждого вида подписей."

        use Core.Es.Event.Payload,
          fields: [
            prim: [prim: LabelsFixture.ItemID],
            enum: [enum: LabelsFixture.Status],
            entity: [entity: LabelsFixture.Seal, personal: false],
            union: [union: LabelsFixture.Shape, personal: false],
            list: [list: [prim: LabelsFixture.ItemID]],
            set: [set: [prim: LabelsFixture.ItemID]],
            map: [map: [key: [prim: LabelsFixture.ItemID], value: [enum: LabelsFixture.Status]]],
            type: [type: :string]
          ]

        use Core.Labels.Fields,
          labels: [
            prim: "Prim",
            enum: "Enum",
            entity: "Entity",
            union: "Union",
            list: "List",
            set: "Set",
            map: [label: "Map", key: "Ключ", value: "Значение"],
            type: "Type"
          ]
      end

      use Core.Es.Event,
        family: Family,
        payload: Payload

      use Core.Labels.Event, title: "Все виды полей"
    end

    defmodule Reachable do
      @moduledoc "Событие с видимым семейством Prim-вариантов: способ связи выходит листом по варианту."

      alias Core.LabelsFixture

      defmodule Payload do
        @moduledoc "Нагрузка: способ связи — вариант семейства, необязательный и ПДн-место."

        use Core.Es.Event.Payload,
          fields: [contact: [union: LabelsFixture.Contact, personal: true, optional: true]]

        use Core.Labels.Fields, labels: [contact: "Способ связи"]
      end

      use Core.Es.Event,
        family: ContactFamily,
        payload: Payload

      use Core.Labels.Event, title: "Способ связи указан"
    end

    defmodule Reached do
      @moduledoc "Событие с видимым семейством Prim-вариантов без ПДн: круг wire через фасад."

      alias Core.LabelsFixture

      defmodule Payload do
        @moduledoc "Нагрузка: способ связи — вариант семейства."

        use Core.Es.Event.Payload,
          fields: [contact: [union: LabelsFixture.Contact, personal: false]]

        use Core.Labels.Fields, labels: [contact: "Способ связи"]
      end

      use Core.Es.Event,
        family: ContactFamily,
        payload: Payload

      use Core.Labels.Event, title: "Способ связи получен"
    end

    defmodule Closed do
      @moduledoc "Событие без нагрузки."

      use Core.Es.Event,
        family: Family,
        payload: nil

      use Core.Labels.Event, title: "Запись закрыта"
    end

    defmodule Blended do
      @moduledoc """
      Событие со скрытыми полями, `text:`, семейством, множеством и словарём: скрытое и `text:` не
      выходят ни в сведения, ни в словарь ссылок, ни в ратчет полноты.
      """

      alias Core.LabelsFixture

      defmodule Payload do
        @moduledoc "Нагрузка: скрытое — id без вида, Enum без подписей и struct без объявления полей."

        use Core.Es.Event.Payload,
          fields: [
            item: [prim: LabelsFixture.ItemID],
            shape: [union: LabelsFixture.Shape, personal: false],
            tags: [set: [prim: LabelsFixture.ItemID]],
            limits: [map: [key: [prim: LabelsFixture.ItemID], value: [prim: LabelsFixture.Count]]],
            quote: [entity: LabelsFixture.Quote, personal: false],
            secret: [prim: LabelsFixture.ItemID],
            digest: [prim: LabelsFixture.BareID],
            kind: [enum: LabelsFixture.BareKind],
            ghost: [entity: LabelsFixture.Ghost, personal: false]
          ]

        use Core.Labels.Fields,
          labels: [
            item: "Позиция",
            shape: "Фигура",
            tags: "Метки",
            limits: [label: "Лимиты", key: "Позиция", value: "Лимит"],
            quote: "Цитата",
            secret: :hidden,
            digest: :hidden,
            kind: :hidden,
            ghost: :hidden
          ]
      end

      use Core.Es.Event,
        family: ManualFamily,
        payload: Payload

      use Core.Labels.Event, title: "Смешанная форма"
    end

    defmodule Shifted do
      @moduledoc "Событие «было → стало» на struct'е со скрытым полем и `text:`-источником."

      defmodule Payload do
        @moduledoc "Изменение позиции: значение — struct с видимой позицией и текстом источника."

        defstruct [:old_value, :new_value]

        use Core.Labels.Fields,
          change: "Позиция",
          value: [entity: Core.LabelsFixture.Shift]
      end

      use Core.Es.Event,
        family: ManualFamily,
        payload: Payload

      use Core.Labels.Event, title: "Позиция передвинута"
    end
  end

  defmodule Event.Codec do
    @moduledoc "Кодек событий с подписями — полный набор ратчета полноты (`Core.Labels.CompletenessCase`)."

    alias Core.LabelsFixture.Event

    @tag_by_mod %{
      Event.Updated => "labels.updated",
      Event.StatusChanged => "labels.status_changed",
      Event.Shipped => "labels.shipped",
      Event.NameChanged => "labels.name_changed",
      Event.StatusSwitched => "labels.status_switched",
      Event.Linked => "labels.linked",
      Event.Limited => "labels.limited",
      Event.Contacted => "labels.contacted",
      Event.HolderChanged => "labels.holder_changed",
      Event.Renamed => "labels.renamed",
      Event.Grouped => "labels.grouped",
      Event.Kinds => "labels.kinds",
      Event.Closed => "labels.closed"
    }

    use Core.Es.Event.Codec,
      family: Event.Family,
      type: "labels",
      tags: @tag_by_mod
  end

  defmodule Event.ItemFamily.Codec do
    @moduledoc "Кодек события другого агрегата; в ратчет и фасад не входит."

    alias Core.LabelsFixture.Event

    use Core.Es.Event.Codec,
      family: Event.ItemFamily,
      type: "labels_item",
      tags: %{Event.Assigned => "labels_item.assigned"}
  end

  defmodule Event.ManualFamily.Codec do
    @moduledoc "Кодек событий с нагрузкой без плагина: ратчет полноты, без фасада."

    alias Core.LabelsFixture.Event

    @tag_by_mod %{
      Event.Tagged => "labels_manual.tagged",
      Event.Packed => "labels_manual.packed",
      Event.OriginChanged => "labels_manual.origin_changed",
      Event.TagsChanged => "labels_manual.tags_changed",
      Event.Carried => "labels_manual.carried",
      Event.ContactChanged => "labels_manual.contact_changed",
      Event.Blended => "labels_manual.blended",
      Event.Shifted => "labels_manual.shifted"
    }

    use Core.Es.Event.Codec,
      family: Event.ManualFamily,
      type: "labels_manual",
      tags: @tag_by_mod
  end

  defmodule Event.ContactFamily.Codec do
    @moduledoc "Кодек события со способом связи: входит в полный набор ратчета полноты."

    alias Core.LabelsFixture.Event

    use Core.Es.Event.Codec,
      family: Event.ContactFamily,
      type: "labels_contact",
      tags: %{
        Event.Reachable => "labels_contact.reachable",
        Event.Reached => "labels_contact.reached"
      }
  end

  defmodule Codec do
    @moduledoc "Плагин вложенных struct'ов нагрузки и ручной нагрузки `Event.Limited` — для дампа событий фасадами."

    alias Core.LabelsFixture

    use Core.Codec.Plugin, types: [LabelsFixture.Address, LabelsFixture.Line]
  end

  defmodule Event.Limited.Codec do
    @moduledoc "Ручной плагин нагрузки `Event.Limited`: ключи-id и значения — дампом кодека."

    alias Core.LabelsFixture.Count
    alias Core.LabelsFixture.Event.Limited
    alias Core.LabelsFixture.ItemID
    alias Core.Result

    use Core.Codec.Plugin,
      types: [Limited.Payload]

    @impl true
    def dump(%Limited.Payload{limits: limits}, codec),
      do: %{"limits" => Map.new(limits, fn {id, limit} -> {codec.dump(id), codec.dump(limit)} end)}

    @impl true
    def load(Limited.Payload, %{"limits" => limits}, codec) when is_map(limits) do
      limits
      |> Map.to_list()
      |> Result.traverse(&load_limit(&1, codec))
      |> Result.map(&%Limited.Payload{limits: Map.new(&1)})
    end

    # ---

    defp load_limit({id, limit}, codec) do
      with {:ok, id} <- codec.load(ItemID, id),
           {:ok, limit} <- codec.load(Count, limit),
           do: {:ok, {id, limit}}
    end
  end

  defmodule WebEvent do
    @moduledoc "Событие страницы событий со сведениями; ссылка на учётную запись — `%{id, login}`."

    use Core.Web.Event,
      codec: Core.CodecFixture.External,
      user_ref: [
        dump: &Core.LabelsFixture.WebEvent.user_ref/2,
        schema: Core.WebEventFixture.UserRef
      ],
      labels: true

    @doc "Ссылка на учётную запись: дамп id и имя."
    @spec user_ref(String.t(), String.t() | nil) :: %{id: String.t(), login: String.t() | nil}

    def user_ref(id, login) when is_binary(id), do: %{id: id, login: login}
  end
end
