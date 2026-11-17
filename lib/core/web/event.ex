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

  Порождает `to_wire/2`: событие и словарь ссылок страницы (`Core.Labels.Refs.get/2`) → map, — и
  `to_wire_page/2`: страница событий и контекст → `Core.Result` со страницей `to_wire/2`, словарь
  ссылок собирается со всей страницы один раз.

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

  Маркеры ПДн-значений дампа (`Core.Es.Personal.Marker`) снимает сам `to_wire/2` (ADR-0074): живое
  значение уходит открытым wire-значением — права на него проверил usecase, — уничтоженное —
  `{"$destroyed": true}` на месте ПДн-значения целиком, любого вида. То же — для
  `%Core.Es.Personal.Destroyed{}` после `load`: он стоит на каждом ПДн-месте плана, в том числе
  вложенном (свойство сущности, элемент `list:`, значение словаря), и снимается вызовом дампа
  чтения по общей декларации. Ключ `$destroyed` camelize не меняет и с wire-ключом поля не
  совпадает. Сведение поля с уничтоженным значением — вида `"destroyed"` с подписью и без `value`,
  у стороны изменения — `%{kind: "destroyed"}`. Свой `Jason.encode` дампа в обход `to_wire/2` на
  маркере отказывает, и значения в тексте отказа нет.

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

  Макрос занимает в модуле имена `to_wire/2` и `to_wire_page/2`, при `open_api_spex` — ещё `schema/0`
  и, при `labels: true`, вложенный модуль `Detail` с модулями видов.
  """

  alias Core.Es
  alias Core.Es.Personal.Destroyed
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

      unquote(page(labels?, not is_nil(user_ref)))
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

  defp page(labels?, refs?) do
    type =
      case labels? do
        false -> quote(do: Core.Web.Event.t())
        true -> quote(do: Core.Web.Event.labelled())
      end

    body =
      if refs? do
        quote generated: true do
          case Core.Labels.Refs.get(page, context) do
            {:ok, refs} -> {:ok, Core.Pagination.Result.map(page, &to_wire(&1, refs))}
            {:error, error} -> {:error, error}
          end
        end
      else
        quote generated: true do
          {:ok, Core.Pagination.Result.map(page, &to_wire(&1, %{}))}
        end
      end

    quote generated: true do
      @doc """
      Страница событий для JSON: словарь ссылок собирается со всей страницы один раз, затем
      `to_wire/2` применяется к элементам; `total` и порядок сохраняются. Профиль без подписей и
      без `user_ref:` словарь не читает — ссылок в `to_wire/2` нет.
      """
      @spec to_wire_page(Core.Pagination.Result.t(Core.Es.Event.t()), Core.Context.t()) ::
              Core.Result.t(Core.Pagination.Result.t(unquote(type)))

      def to_wire_page(%Core.Pagination.Result{} = page, %Core.Context{} = context) do
        unquote(body)
      end
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

  def to_wire(%mod{by: by} = event, refs, codec, user_dump, labels?)
      when is_map(refs) and is_atom(codec) and is_boolean(labels?) do
    fields = Es.Event.Codec.to_fields(event_wire(mod, event, codec))

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

  # Маркеры ПДн-значений дампа стоят на местах нагрузки любой глубины (ADR-0073): снимаются
  # рекурсивно — у значения-маркера открытая часть, у уничтоженного — признак.
  defp open(payload), do: open_value(payload)

  defp open_value(%Marker{destroyed: true}), do: %{"$destroyed" => true}
  defp open_value(%Marker{value: value}), do: value
  defp open_value(%_{} = value), do: value
  defp open_value(map) when is_map(map), do: Map.new(map, fn {key, value} -> {key, open_value(value)} end)
  defp open_value(list) when is_list(list), do: Enum.map(list, &open_value/1)
  defp open_value(value), do: value

  # Событие после `load` может нести `%Destroyed{}` на вложенном ПДн-месте: фасад такой дамп
  # отвергает (уничтоженное не пишется в новое событие), поэтому конверт собирается по общей
  # декларации, а уничтоженное место выходит признаком. Живое ПДн и все прочие значения — обычным
  # дампом фасада.
  defp event_wire(mod, event, codec) do
    if destroyed?(event.payload) do
      type = mod.__es_family__().__es_codec__().type(mod)
      Es.Event.Codec.dump_envelope(event, type, read_dump(event.payload, codec), codec)
    else
      codec.dump(event)
    end
  end

  defp destroyed?(%Destroyed{}), do: true
  defp destroyed?(%_{} = value), do: destroyed?(Map.from_struct(value))
  defp destroyed?(map) when is_map(map), do: Enum.any?(map, fn {_key, value} -> destroyed?(value) end)
  defp destroyed?(list) when is_list(list), do: Enum.any?(list, &destroyed?/1)
  defp destroyed?(_value), do: false

  defp read_dump(%Destroyed{}, _codec), do: %{"$destroyed" => true}

  defp read_dump(%mod{} = payload, codec) do
    case Core.Field.introspect(mod) do
      nil ->
        codec.dump(payload)

      fields ->
        places = Core.Field.personal_places(fields, [], key: :name)
        dump_fields(fields, payload, places, [], codec)
    end
  end

  defp dump_fields(fields, struct, places, path, codec) do
    Map.new(fields, fn %Core.Field{} = field ->
      {field.wire, dump_field(field, Map.fetch!(struct, field.name), places, path, codec)}
    end)
  end

  defp dump_field(%Core.Field{personal: true} = field, value, _places, _path, codec),
    do: dump_place(field.spec, value, codec)

  defp dump_field(%Core.Field{} = field, value, places, path, codec),
    do: dump_value(field.spec, value, places, path ++ [field.name], codec)

  defp dump_value(_spec, nil, _places, _path, _codec), do: nil

  defp dump_value(spec, value, places, path, codec) do
    if Enum.any?(places, &(&1.path == path)),
      do: dump_place(spec, value, codec),
      else: dump_open(spec, value, places, path, codec)
  end

  defp dump_place(_spec, %Destroyed{}, _codec), do: %{"$destroyed" => true}
  defp dump_place(_spec, nil, _codec), do: nil
  defp dump_place(spec, value, codec), do: dump_plain(spec, value, codec)

  defp dump_open({:personal, inner}, value, places, path, codec),
    do: dump_value(inner, value, places, path, codec)

  defp dump_open({:personal_false, inner}, value, places, path, codec),
    do: dump_value(inner, value, places, path, codec)

  defp dump_open({:entity, mod}, value, places, path, codec) do
    case Core.Field.introspect(mod) do
      nil -> codec.dump(value)
      fields -> dump_fields(fields, value, places, path, codec)
    end
  end

  defp dump_open({:list, inner}, list, places, path, codec) when is_list(list),
    do: Enum.map(list, &dump_value(inner, &1, places, path ++ [:each], codec))

  defp dump_open({:set, inner}, set, _places, _path, codec),
    do: Core.Codec.Helper.set_wire(Enum.map(set, &dump_plain(inner, &1, codec)))

  defp dump_open({:map, key, value}, map, places, path, codec) when is_map(map) do
    Map.new(map, fn {k, v} ->
      {dump_key(key, k, codec), dump_value(value, v, places, path ++ [:each], codec)}
    end)
  end

  defp dump_open(spec, value, _places, _path, codec), do: dump_plain(spec, value, codec)

  defp dump_plain(_spec, nil, _codec), do: nil
  defp dump_plain({:personal, inner}, value, codec), do: dump_plain(inner, value, codec)
  defp dump_plain({:personal_false, inner}, value, codec), do: dump_plain(inner, value, codec)
  defp dump_plain({:prim, _mod}, value, codec), do: codec.dump(value)
  defp dump_plain({:entity, _mod}, value, codec), do: codec.dump(value)
  defp dump_plain({:union, _family}, value, codec), do: codec.dump(value)
  defp dump_plain({:list, inner}, list, codec) when is_list(list), do: Enum.map(list, &dump_plain(inner, &1, codec))

  defp dump_plain({:set, inner}, set, codec),
    do: Core.Codec.Helper.set_wire(Enum.map(set, &dump_plain(inner, &1, codec)))

  defp dump_plain({:map, key, value}, map, codec) when is_map(map) do
    Map.new(map, fn {k, v} -> {dump_key(key, k, codec), dump_plain(value, v, codec)} end)
  end

  defp dump_plain(_spec, value, _codec), do: value

  defp dump_key({:enum, _mod}, key, _codec), do: Core.Codec.Helper.enum_key(key)
  defp dump_key(spec, key, codec), do: dump_plain(spec, key, codec)

  defp by(dumped, _by, _refs, nil), do: dumped

  defp by(dumped, by, refs, user_dump) when is_function(user_dump, 2),
    do: user_dump.(dumped, Details.name!(refs, by, "автор события"))
end
