defmodule Core.Web.Event do
  @moduledoc """
  Событие страницы событий: событие и словарь ссылок страницы → map для JSON (ADR-0066).

  Подключается модулем приложения; свою часть формы — профиль кодека, ссылку на учётную запись и
  подписи — приложение задаёт опциями:

      defmodule MyAppWeb.Schemas.Event do
        use Core.Web.Event,
          codec: MyApp.Codec.External,
          user_ref: [
            dump: &MyAppWeb.Presenters.User.ref/2,
            schema: MyAppWeb.Schemas.UserRef
          ],
          labels: true
      end

  | Опция | Обязательность | Что задаёт |
  |---|---|---|
  | `codec:` | обязательна | внешний профиль кодека приложения (модуль с `dump/1`): им дампятся конверт события и значения сведений |
  | `user_ref:` | необязательна | ссылку на учётную запись: `dump:` — захват функции «дамп id, имя → map» арности 2; `schema:` — модуль OpenApiSpex-схемы map'ы от `dump:`, обязателен при `open_api_spex` (см. «Схема») |
  | `labels:` | необязательна, `false` | `true` — название и сведения события (`Core.Labels.Details`) в `title` и `details`; требует `user_ref:` |

  `user_ref:` — опция-выражение (`docs/rules/20-agreements.md`, «Опции `use`»): её форма, `dump:`,
  модуль `schema:` и требование `user_ref:` при `labels: true` проверяются в теле модуля; `codec:` и
  `labels:` — литералы, проверяются при раскрытии `use`.

  Порождает `to_wire/2`: событие и словарь ссылок страницы (`Core.Labels.Refs.get/2`) → map.

  | Поле | На wire |
  |---|---|
  | `id`, `aggregateId`, `type`, `at` | поля конверта дампом `codec:` |
  | `aggregateVersion` | версия агрегата после события |
  | `payload` | нагрузка конверта, ключи — camelCase; id в ней — строки дампа, без подмены ссылками; ПДн — ниже |
  | `by` | без `user_ref:` — дамп id; с ним — результат `dump:` от дампа id и имени из словаря ссылок |
  | `title` | при `labels: true` — название события |
  | `details` | при `labels: true` — сведения события (таблица ниже) |

  | Сведение | На wire |
  |---|---|
  | вид | строкой — имя вида `Core.Labels.Details`, перечень — под таблицей |
  | `:number` | строкой с десятичной точкой: integer — `Integer.to_string/1`, decimal и float — нормальная запись |
  | `:text`, `:date`, `:datetime` | Prim — дампом `codec:`, строка — как есть |
  | `:ref` | `%{entity, id, name}`: вид записи — camelCase атома, id — дампом `codec:`, имя — из словаря ссылок |
  | `:user` | результат `dump:` от дампа id и имени из словаря ссылок — той же формы, что `by` |
  | `:group`, `:list`, `:set` | сведения и элементы — рекурсивно |
  | `:map` | пары `%{key, value}`: ключ и значение — элементы, рекурсивно; с `label` при подписях ключа и значения |
  | `:change` | `%{label, kind: "change", old, new}` |

  Виды: `"text"`, `"number"`, `"date"`, `"datetime"`, `"user"`, `"ref"`, `"group"`, `"list"`, `"set"`, `"map"`,
  `"change"`, `"destroyed"`. Строка, которую отдал кодек (`decimal: :string`), выходит как есть. У
  элемента списка, стороны изменения и стороны неподписанного словаря `label` нет; значения нет —
  `value: nil`.

  Маркеры ПДн-значений дампа (`Core.Es.Personal.Marker`, поля с `subject:`) снимает сам `to_wire/2`
  (ADR-0074): живое значение уходит открытым wire-значением — права на него проверил usecase, —
  уничтоженное — `{"$destroyed": true}` на месте поля целиком, любого вида. Ключ `$destroyed`
  camelize не меняет и с wire-ключом поля не совпадает. Сведение поля с уничтоженным значением —
  вида `"destroyed"` с подписью и без `value`, у стороны изменения — `%{kind: "destroyed"}`. Свой
  `Jason.encode` дампа в обход `to_wire/2` на маркере отказывает, и значения в тексте отказа нет.

  Автор или id сведений, которых нет в словаре ссылок при `user_ref:`, — `ArgumentError`: словарь
  собирают с той же страницы событий. Без `user_ref:` словарь не читается — подходит и пустой.

  Точечная правка — дело приложения: `%{MyEvent.to_wire(event, refs) | payload: nil}`.

  ## Схема

  Если у приложения есть `open_api_spex` (проверка — при раскрытии `use`), модуль становится
  OpenAPI-схемой события страницы событий (`schema/0`), и страница описывается
  `Core.Web.Response.Schema.page(MyAppWeb.Schemas.Event)`. Название схемы — последний сегмент имени
  модуля; объект открытый, все поля обязательны: `type` — строка без перечисления (схема одна на все
  агрегаты), `aggregateVersion` — целое от 1, `payload` — схема без типа, nullable, с формой уничтоженного
  значения в описании, `at` — `date-time`, `by` — строка без `user_ref:` и `schema:` из `user_ref:` с ним.

  При `labels: true` — ещё `title` и `details`: схема сведений — вложенный модуль `Detail` (`oneOf` по
  видам с дискриминатором `kind`, название `<Имя>Detail`), схемы видов — его вложенные модули `Text`,
  `Number`, `Date`, `DateTime`, `User`, `Ref`, `Group`, `List`, `Set`, `Map`, `Change`, `Destroyed`
  (`<Имя>DetailText`, …). Сведения группы, списка, множества, ключ и значение пары словаря и сторона
  изменения ссылаются на схему сведений, значение вида `user` — на `schema:` из `user_ref:`; у вида
  `destroyed` значения нет. Без `open_api_spex` модуль — только дамп, и `schema:` не требуется.

  Сборку ломают: нет `codec:`, `codec:` без `dump/1`, неизвестная опция, `user_ref:` без `dump:` или с
  неизвестной опцией, `dump:` не захватом функции арности 2, `labels:` не boolean, `labels: true` без
  `user_ref:`; при `open_api_spex` — `user_ref:` без `schema:`, `schema:` без `schema/0` или `core`,
  собранный без `open_api_spex` (тела схем строит условный модуль библиотеки; правка —
  `mix deps.compile core --force`).

  Макрос занимает в модуле имя `to_wire/2`, при `open_api_spex` — ещё `schema/0` и, при
  `labels: true`, вложенный модуль `Detail` с модулями видов.
  """

  alias Core.Es
  alias Core.Es.Personal.Marker
  alias Core.Helper
  alias Core.Labels.Check
  alias Core.Web.Event.Details

  @typedoc "Событие страницы событий для JSON."
  @type t :: %{
          id: String.t(),
          aggregateId: String.t(),
          aggregateVersion: pos_integer(),
          type: String.t(),
          payload: term(),
          at: String.t(),
          by: String.t() | map()
        }

  @typedoc "Событие страницы событий для JSON с названием и сведениями (`labels: true`)."
  @type labelled :: %{
          id: String.t(),
          aggregateId: String.t(),
          aggregateVersion: pos_integer(),
          type: String.t(),
          payload: term(),
          at: String.t(),
          by: map(),
          title: String.t(),
          details: [detail()]
        }

  @typedoc """
  Сведение для JSON: у элемента списка, стороны изменения и стороны неподписанного словаря `label` нет, у вида
  `destroyed` нет `value`.
  """
  @type detail ::
          %{optional(:label) => String.t(), required(:kind) => String.t(), required(:value) => value()}
          | %{label: String.t(), kind: String.t(), old: detail(), new: detail()}
          | %{optional(:label) => String.t(), required(:kind) => String.t()}

  @typedoc """
  Значение сведения: дамп кодека, число строкой, ссылка, ссылка на учётную запись, сведения группы, пары
  словаря.
  """
  @type value :: String.t() | struct() | ref() | map() | [detail()] | [%{key: detail(), value: detail()}] | nil

  @typedoc "Ссылка на запись."
  @type ref :: %{entity: String.t(), id: term(), name: String.t() | nil}

  @typedoc "Дамп ссылки на учётную запись: дамп id и имя из словаря ссылок → map."
  @type user_dump :: (term(), String.t() | nil -> map())

  @label "Web.Event"
  @required_keys ~w(codec)a
  @optional_keys ~w(user_ref labels)a
  @expression_keys ~w(user_ref)a
  @user_ref_required_keys ~w(dump)a
  @user_ref_optional_keys []
  @user_ref_schema_keys ~w(schema)a

  # Вид сведения → вложенный модуль схемы в `Detail`; суффикс названия и описание — у
  # `Core.Web.Event.Schema`.
  @variants [
    text: quote(do: __MODULE__.Text),
    number: quote(do: __MODULE__.Number),
    date: quote(do: __MODULE__.Date),
    datetime: quote(do: __MODULE__.DateTime),
    user: quote(do: __MODULE__.User),
    ref: quote(do: __MODULE__.Ref),
    group: quote(do: __MODULE__.Group),
    list: quote(do: __MODULE__.List),
    set: quote(do: __MODULE__.Set),
    map: quote(do: __MODULE__.Map),
    change: quote(do: __MODULE__.Change),
    destroyed: quote(do: __MODULE__.Destroyed)
  ]

  # Поле на wire → guard сужения в порождённой `to_wire/2` (`nil` — без guard'а).
  @fields [id: nil, aggregateId: nil, aggregateVersion: :is_integer, type: :is_binary, payload: nil, at: nil, by: nil]
  @labelled_fields Keyword.merge(@fields, by: :is_map, title: :is_binary, details: :is_list)

  # ===== объявление =====

  @doc """
  Объявить дамп события страницы событий: профиль кодека (`codec:`), ссылку на учётную запись
  (`user_ref:`) и подписи (`labels:`); при `open_api_spex` у приложения — и его схему.
  """
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    opts = Helper.Opts.literal!(opts, @expression_keys, @label)
    codec = Helper.Opts.module!(opts, :codec, @label, exports: [dump: 1])
    labels? = labels!(Keyword.get(opts, :labels, false))

    case Code.ensure_loaded?(OpenApiSpex) do
      true ->
        schema_built!(Code.ensure_compiled(__MODULE__.Schema))

        quote do
          unquote(wire(codec, opts[:user_ref], labels?, true))
          unquote(schemas())
        end

      false ->
        wire(codec, opts[:user_ref], labels?, false)
    end
  end

  @doc false
  @spec schema_built!({:module, module()} | {:error, atom()}) :: :ok

  def schema_built!({:module, _schema}), do: :ok

  def schema_built!({:error, _reason}) do
    Helper.Opts.reject!(
      @label,
      "open_api_spex есть, но core собран без него — схемы события нет; пересоберите: mix deps.compile core --force"
    )
  end

  @doc false
  @spec user_ref!(term(), boolean(), boolean()) :: keyword() | nil

  def user_ref!(nil, schema?, false = _labels?) when is_boolean(schema?), do: nil

  def user_ref!(nil, schema?, true = _labels?) when is_boolean(schema?) do
    Helper.Opts.reject!(
      "#{@label}: labels",
      "true требует user_ref: — автор события и учётная запись в сведениях выходят одной формой"
    )
  end

  def user_ref!(user_ref, schema?, labels?) when is_boolean(schema?) and is_boolean(labels?) do
    where = "#{@label}: user_ref"

    {required, optional} =
      case schema? do
        true -> {@user_ref_required_keys ++ @user_ref_schema_keys, @user_ref_optional_keys}
        false -> {@user_ref_required_keys, @user_ref_optional_keys ++ @user_ref_schema_keys}
      end

    Helper.Opts.validate!(user_ref, required, optional, where)
    Check.capture!(Keyword.fetch!(user_ref, :dump), 2, "#{where}: dump")

    user_ref
  end

  @doc false
  @spec user_schema!(keyword() | nil) :: module() | nil

  def user_schema!(nil), do: nil

  def user_schema!(user_ref) when is_list(user_ref),
    do: Helper.Opts.module!(user_ref, :schema, "#{@label}: user_ref", exports: [schema: 0])

  # ---

  defp labels!(labels?) when is_boolean(labels?), do: labels?
  defp labels!(other), do: Helper.Opts.reject!("#{@label}: labels", "ожидается boolean, получено #{inspect(other)}")

  defp wire(codec, user_ref, labels?, schema?) do
    quote generated: true do
      @web_event_codec unquote(codec)
      @web_event_user_ref Core.Web.Event.user_ref!(unquote(user_ref), unquote(schema?), unquote(labels?))
      @web_event_user_dump @web_event_user_ref[:dump]
      @web_event_labels unquote(labels?)

      case @web_event_labels do
        false -> unquote(plain())
        true -> unquote(labelled())
      end
    end
  end

  defp plain do
    quote generated: true do
      @doc "Событие страницы событий для JSON по словарю ссылок страницы."
      @spec to_wire(Core.Es.Event.t(), Core.Labels.Refs.t()) :: Core.Web.Event.t()

      def to_wire(%_{payload: _} = event, refs) when is_map(refs), do: unquote(narrow(@fields, false))
    end
  end

  defp labelled do
    quote generated: true do
      @doc "Событие страницы событий с названием и сведениями для JSON по словарю ссылок страницы."
      @spec to_wire(Core.Es.Event.t(), Core.Labels.Refs.t()) :: Core.Web.Event.labelled()

      def to_wire(%_{payload: _} = event, refs) when is_map(refs), do: unquote(narrow(@labelled_fields, true))
    end
  end

  # Сужение результата библиотеки (ADR-0014): map собирается заново из переменных паттерна.
  defp narrow(fields, labels?) do
    vars = for {field, _guard} <- fields, do: {field, Macro.var(field, __MODULE__)}
    wire = {:%{}, [], vars}

    guard =
      for({field, guard} <- fields, guard != nil, do: quote(do: Kernel.unquote(guard)(unquote(vars[field]))))
      |> Enum.reduce(&quote(do: unquote(&2) and unquote(&1)))

    quote generated: true do
      case Core.Web.Event.to_wire(event, refs, @web_event_codec, @web_event_user_dump, unquote(labels?)) do
        unquote(wire) when unquote(guard) -> unquote(wire)
      end
    end
  end

  # Модули схем — только в `quote`: тела строит `Core.Web.Event.Schema`, который есть, только если
  # `core` собран с `open_api_spex` (ADR-0064). Не `OpenApiSpex.schema/2`: тот выключает
  # предупреждения всего модуля, а с ним — и порождённой `to_wire/2`.
  defp schemas do
    quote generated: true do
      web_event_title = List.last(Module.split(__MODULE__))
      web_event_user = Core.Web.Event.user_schema!(@web_event_user_ref)

      web_event_detail =
        case @web_event_labels do
          false ->
            nil

          true ->
            unquote(detail())

            __MODULE__.Detail
        end

      @behaviour OpenApiSpex.Schema

      @web_event_schema Core.Web.Event.Schema.event(web_event_title, web_event_user, web_event_detail)

      @doc "OpenAPI-схема события страницы событий."
      @spec schema() :: OpenApiSpex.Schema.t()

      @impl true
      def schema, do: @web_event_schema
    end
  end

  defp detail do
    quote generated: true do
      defmodule __MODULE__.Detail do
        @moduledoc "Сведение события страницы событий: вид — в `kind`."

        unquote_splicing(Enum.map(@variants, &variant/1))

        @behaviour OpenApiSpex.Schema

        @web_event_schema Core.Web.Event.Schema.detail(web_event_title, unquote(@variants))

        @doc "OpenAPI-схема сведения события: `oneOf` по видам, дискриминатор `kind`."
        @spec schema() :: OpenApiSpex.Schema.t()

        @impl true
        def schema, do: @web_event_schema
      end
    end
  end

  defp variant({kind, module}) do
    quote generated: true do
      defmodule unquote(module) do
        @moduledoc unquote("Сведение события вида `#{kind}`.")

        @behaviour OpenApiSpex.Schema

        @web_event_schema Core.Web.Event.Schema.variant(web_event_title, unquote(kind), web_event_user)

        @doc unquote("OpenAPI-схема сведения вида `#{kind}`.")
        @spec schema() :: OpenApiSpex.Schema.t()

        @impl true
        def schema, do: @web_event_schema
      end
    end
  end

  # ===== дамп =====

  @doc false
  @spec to_wire(struct(), Core.Labels.Refs.t(), module(), user_dump() | nil, boolean()) :: t() | labelled()

  def to_wire(%_{by: by} = event, refs, codec, user_dump, labels?)
      when is_map(refs) and is_atom(codec) and is_boolean(labels?) do
    fields = Es.Event.Codec.to_fields(codec.dump(event))

    wire = %{
      id: fields.id,
      aggregateId: fields.aggregate_id,
      aggregateVersion: fields.aggregate_version,
      type: fields.type,
      payload: Helper.Keys.camelize(open(fields.payload)),
      at: fields.at,
      by: by(fields.by, by, refs, user_dump)
    }

    case labels? do
      false -> wire
      true -> Map.merge(wire, Details.to_wire(event, refs, codec, user_dump))
    end
  end

  # ---

  # Маркер ПДн-значения стоит только среди полей нагрузки верхнего уровня (ADR-0073).
  defp open(payload) when is_map(payload), do: Map.new(payload, fn {key, value} -> {key, open_value(value)} end)
  defp open(payload), do: payload

  defp open_value(%Marker{destroyed: true}), do: %{"$destroyed" => true}
  defp open_value(%Marker{value: value}), do: value
  defp open_value(value), do: value

  defp by(dumped, _by, _refs, nil), do: dumped

  defp by(dumped, by, refs, user_dump) when is_function(user_dump, 2),
    do: user_dump.(dumped, Details.name!(refs, by, "автор события"))
end
