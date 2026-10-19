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
  | вид | строкой: `"text"`, `"number"`, `"date"`, `"datetime"`, `"user"`, `"ref"`, `"group"`, `"list"`, `"change"`, `"destroyed"` |
  | `:number` | строкой с десятичной точкой: integer — `Integer.to_string/1`, decimal и float — нормальная запись |
  | `:text`, `:date`, `:datetime` | Prim — дампом `codec:`, строка — как есть |
  | `:ref` | `%{entity, id, name}`: вид записи — camelCase атома, id — дампом `codec:`, имя — из словаря ссылок |
  | `:user` | результат `dump:` от дампа id и имени из словаря ссылок — той же формы, что `by` |
  | `:group`, `:list` | сведения и элементы — рекурсивно |
  | `:change` | `%{label, kind: "change", old, new}` |

  Строка, которую отдал кодек (`decimal: :string`), выходит как есть. У элемента списка и стороны
  изменения `label` нет; значения нет — `value: nil`.

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
  `Number`, `Date`, `DateTime`, `User`, `Ref`, `Group`, `List`, `Change`, `Destroyed` (`<Имя>DetailText`,
  …). Сведения группы, списка и стороны изменения ссылаются на схему сведений, значение вида `user` — на
  `schema:` из `user_ref:`; у вида `destroyed` значения нет. Без `open_api_spex` модуль — только дамп, и
  `schema:` не требуется.

  Сборку ломают: нет `codec:`, `codec:` без `dump/1`, неизвестная опция, `user_ref:` без `dump:` или с
  неизвестной опцией, `dump:` не захватом функции арности 2, `labels:` не boolean, `labels: true` без
  `user_ref:`; при `open_api_spex` — `user_ref:` без `schema:` или `schema:` без `schema/0`.

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

  @typedoc "Сведение для JSON: у элемента списка и стороны изменения `label` нет, у вида `destroyed` нет `value`."
  @type detail ::
          %{optional(:label) => String.t(), required(:kind) => String.t(), required(:value) => value()}
          | %{label: String.t(), kind: String.t(), old: detail(), new: detail()}
          | %{optional(:label) => String.t(), required(:kind) => String.t()}

  @typedoc "Значение сведения: дамп кодека, число строкой, ссылка, ссылка на учётную запись, сведения группы."
  @type value :: String.t() | struct() | ref() | map() | [detail()] | nil

  @typedoc "Ссылка на запись."
  @type ref :: %{entity: String.t(), id: term(), name: String.t() | nil}

  @typedoc "Дамп ссылки на учётную запись: дамп id и имя из словаря ссылок → map."
  @type user_dump :: (term(), String.t() | nil -> map())

  @label "Web.Event"
  @required_keys ~w(codec)a
  @optional_keys ~w(user_ref labels)a
  @user_ref_required_keys ~w(dump)a
  @user_ref_optional_keys []
  @user_ref_schema_keys ~w(schema)a

  # Вид сведения → вложенный модуль схемы в `Detail`, суффикс названия, описание.
  @variants [
    text: {quote(do: __MODULE__.Text), "Text", "Текст: строка, подпись значения, «Да» / «Нет»"},
    number: {quote(do: __MODULE__.Number), "Number", "Число строкой с десятичной точкой; единица — в подписи"},
    date: {quote(do: __MODULE__.Date), "Date", "Дата"},
    datetime: {quote(do: __MODULE__.DateTime), "DateTime", "Дата-время"},
    user: {quote(do: __MODULE__.User), "User", "Ссылка на учётную запись"},
    ref: {quote(do: __MODULE__.Ref), "Ref", "Ссылка на запись: вид записи, id и текущее имя"},
    group: {quote(do: __MODULE__.Group), "Group", "Сведения вложенного значения"},
    list: {
      quote(do: __MODULE__.List),
      "List",
      "Элементы одного вида без подписи; у map'ы с id в ключах — группы «ключ — значение»"
    },
    change: {quote(do: __MODULE__.Change), "Change", "Изменение: было и стало — сведения без подписи"},
    destroyed: {
      quote(do: __MODULE__.Destroyed),
      "Destroyed",
      "Уничтоженное ПДн-значение: подпись без значения"
    }
  ]

  # ===== объявление =====

  @doc """
  Объявить дамп события страницы событий: профиль кодека (`codec:`), ссылку на учётную запись
  (`user_ref:`) и подписи (`labels:`); при `open_api_spex` у приложения — и его схему.
  """
  defmacro __using__(opts) do
    case Code.ensure_loaded?(OpenApiSpex) do
      true ->
        quote do
          unquote(wire(opts, true))
          unquote(schemas(opts))
        end

      false ->
        wire(opts, false)
    end
  end

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys

  @doc false
  @spec user_dump!(module(), keyword() | nil, boolean()) :: user_dump() | nil

  def user_dump!(module, nil, schema?) when is_atom(module) and is_boolean(schema?), do: nil

  def user_dump!(module, user_ref, schema?) when is_atom(module) and is_boolean(schema?) do
    where = "#{@label} #{inspect(module)}: user_ref"

    {required, optional} =
      case schema? do
        true -> {@user_ref_required_keys ++ @user_ref_schema_keys, @user_ref_optional_keys}
        false -> {@user_ref_required_keys, @user_ref_optional_keys ++ @user_ref_schema_keys}
      end

    Helper.Opts.validate!(user_ref, required, optional, where)
    Check.capture!(Keyword.fetch!(user_ref, :dump), 2, "#{where}: dump")
  end

  @doc false
  @spec user_schema!(module(), keyword() | nil) :: module() | nil

  def user_schema!(module, nil) when is_atom(module), do: nil

  def user_schema!(module, user_ref) when is_atom(module) and is_list(user_ref),
    do: Helper.Opts.module!(user_ref, :schema, "#{@label} #{inspect(module)}: user_ref", exports: [schema: 0])

  @doc false
  @spec labels!(module(), keyword()) :: boolean()

  def labels!(module, opts) when is_atom(module) and is_list(opts) do
    where = "#{@label} #{inspect(module)}: labels:"

    case {Keyword.get(opts, :labels, false), Keyword.get(opts, :user_ref) != nil} do
      {false, _user_ref?} ->
        false

      {true, true} ->
        true

      {true, false} ->
        raise CompileError,
          description:
            "#{where} true требует user_ref: — автор события и учётная запись в сведениях выходят одной формой"

      {other, _user_ref?} ->
        raise CompileError, description: "#{where} ожидается boolean, получено #{inspect(other)}"
    end
  end

  # ---

  defp wire(opts, schema?) do
    quote generated: true do
      unquote(declaration(opts, schema?))

      case @web_event_labels do
        false -> unquote(plain())
        true -> unquote(labelled())
      end
    end
  end

  defp declaration(opts, schema?) do
    quote bind_quoted: [opts: opts, schema?: schema?], generated: true do
      Core.Helper.Opts.validate!(
        opts,
        Core.Web.Event.required_keys(),
        Core.Web.Event.optional_keys(),
        "Web.Event"
      )

      @web_event_codec Core.Helper.Opts.module!(opts, :codec, "Web.Event", exports: [dump: 1])
      @web_event_user_dump Core.Web.Event.user_dump!(__MODULE__, Keyword.get(opts, :user_ref), schema?)
      @web_event_labels Core.Web.Event.labels!(__MODULE__, opts)
    end
  end

  defp plain do
    quote generated: true do
      @doc "Событие страницы событий для JSON по словарю ссылок страницы."
      @spec to_wire(Core.Es.Event.t(), Core.Labels.Refs.t()) :: Core.Web.Event.t()

      def to_wire(%_{payload: _} = event, refs) when is_map(refs) do
        case Core.Web.Event.to_wire(event, refs, @web_event_codec, @web_event_user_dump, false) do
          %{
            id: id,
            aggregateId: aggregate_id,
            aggregateVersion: aggregate_version,
            type: type,
            payload: payload,
            at: at,
            by: by
          }
          when is_binary(type) and is_integer(aggregate_version) ->
            %{
              id: id,
              aggregateId: aggregate_id,
              aggregateVersion: aggregate_version,
              type: type,
              payload: payload,
              at: at,
              by: by
            }
        end
      end
    end
  end

  defp labelled do
    quote generated: true do
      @doc "Событие страницы событий с названием и сведениями для JSON по словарю ссылок страницы."
      @spec to_wire(Core.Es.Event.t(), Core.Labels.Refs.t()) :: Core.Web.Event.labelled()

      def to_wire(%_{payload: _} = event, refs) when is_map(refs) do
        case Core.Web.Event.to_wire(event, refs, @web_event_codec, @web_event_user_dump, true) do
          %{
            id: id,
            aggregateId: aggregate_id,
            aggregateVersion: aggregate_version,
            type: type,
            payload: payload,
            at: at,
            by: %{} = by,
            title: title,
            details: details
          }
          when is_binary(type) and is_integer(aggregate_version) and is_binary(title) and is_list(details) ->
            %{
              id: id,
              aggregateId: aggregate_id,
              aggregateVersion: aggregate_version,
              type: type,
              payload: payload,
              at: at,
              by: by,
              title: title,
              details: details
            }
        end
      end
    end
  end

  # Модули схем — только в `quote`: на `OpenApiSpex` ссылается код приложения, у которого он есть,
  # а модуль библиотеки собирается и без него (ADR-0064). Не `OpenApiSpex.schema/2`: тот выключает
  # предупреждения всего модуля, а с ним — и порождённой `to_wire/2`.
  defp schemas(opts) do
    quote generated: true do
      web_event_title = List.last(Module.split(__MODULE__))
      web_event_user = Core.Web.Event.user_schema!(__MODULE__, Keyword.get(unquote(opts), :user_ref))

      web_event_labels =
        case @web_event_labels do
          false ->
            %{}

          true ->
            unquote(detail())

            %{
              title: %OpenApiSpex.Schema{type: :string, description: "Название события"},
              details: %OpenApiSpex.Schema{type: :array, items: __MODULE__.Detail, description: "Сведения события"}
            }
        end

      @behaviour OpenApiSpex.Schema

      @web_event_schema OpenApiSpex.build_schema(
                          %{
                            title: web_event_title,
                            description: "Событие страницы событий",
                            type: :object,
                            properties:
                              Map.merge(
                                %{
                                  id: %OpenApiSpex.Schema{type: :string, description: "Идентификатор события"},
                                  aggregateId: %OpenApiSpex.Schema{type: :string, description: "Идентификатор агрегата"},
                                  aggregateVersion: %OpenApiSpex.Schema{
                                    type: :integer,
                                    minimum: 1,
                                    description: "Версия агрегата после события"
                                  },
                                  type: %OpenApiSpex.Schema{type: :string, description: "Тег события"},
                                  payload: %OpenApiSpex.Schema{
                                    nullable: true,
                                    description:
                                      "Нагрузка события, ключи — camelCase; уничтоженное ПДн-значение " <>
                                        ~s(поля — {"$destroyed": true})
                                  },
                                  at: %OpenApiSpex.Schema{
                                    type: :string,
                                    format: :"date-time",
                                    description: "Момент события"
                                  },
                                  by:
                                    case web_event_user do
                                      nil -> %OpenApiSpex.Schema{type: :string, description: "Идентификатор автора"}
                                      user -> user
                                    end
                                },
                                web_event_labels
                              ),
                            required:
                              ~w(id aggregateId aggregateVersion type payload at by)a ++ Map.keys(web_event_labels)
                          },
                          struct?: false
                        )

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

        web_event_detail = %OpenApiSpex.Reference{"$ref": "#/components/schemas/#{web_event_title}Detail"}

        unquote_splicing(Enum.map(@variants, &variant/1))

        @behaviour OpenApiSpex.Schema

        @web_event_schema OpenApiSpex.build_schema(
                            %{
                              title: web_event_title <> "Detail",
                              description: "Сведение события: вид — в `kind`",
                              type: :object,
                              oneOf: unquote(for {_kind, {module, _suffix, _description}} <- @variants, do: module),
                              discriminator: %OpenApiSpex.Discriminator{
                                propertyName: "kind",
                                mapping:
                                  Map.new(
                                    unquote(
                                      for {kind, {_module, suffix, _description}} <- @variants,
                                          do: {"#{kind}", suffix}
                                    ),
                                    fn {kind, suffix} ->
                                      {kind, "#/components/schemas/#{web_event_title}Detail#{suffix}"}
                                    end
                                  )
                              }
                            },
                            struct?: false
                          )

        @doc "OpenAPI-схема сведения события: `oneOf` по видам, дискриминатор `kind`."
        @spec schema() :: OpenApiSpex.Schema.t()

        @impl true
        def schema, do: @web_event_schema
      end
    end
  end

  defp variant({kind, {module, suffix, description}}) do
    quote generated: true do
      defmodule unquote(module) do
        @moduledoc unquote("Сведение события вида `#{kind}`.")

        @behaviour OpenApiSpex.Schema

        @web_event_schema OpenApiSpex.build_schema(
                            %{
                              title: web_event_title <> "Detail" <> unquote(suffix),
                              description: unquote(description),
                              type: :object,
                              properties:
                                Map.merge(
                                  %{
                                    label: %OpenApiSpex.Schema{
                                      type: :string,
                                      description: "Подпись; нет у элемента списка и стороны изменения"
                                    },
                                    kind: %OpenApiSpex.Schema{type: :string, enum: [unquote("#{kind}")]}
                                  },
                                  unquote(properties(kind))
                                ),
                              required: unquote(required(kind))
                            },
                            struct?: false
                          )

        @doc unquote("OpenAPI-схема сведения вида `#{kind}`.")
        @spec schema() :: OpenApiSpex.Schema.t()

        @impl true
        def schema, do: @web_event_schema
      end
    end
  end

  defp properties(:text), do: quote(do: %{value: %OpenApiSpex.Schema{type: :string, nullable: true}})

  defp properties(:number),
    do: quote(do: %{value: %OpenApiSpex.Schema{type: :string, nullable: true, example: "4.5"}})

  defp properties(:date), do: quote(do: %{value: %OpenApiSpex.Schema{type: :string, format: :date, nullable: true}})

  defp properties(:datetime),
    do: quote(do: %{value: %OpenApiSpex.Schema{type: :string, format: :"date-time", nullable: true}})

  defp properties(:user), do: quote(do: %{value: %OpenApiSpex.Schema{allOf: [web_event_user], nullable: true}})

  defp properties(:ref) do
    quote do
      %{
        value: %OpenApiSpex.Schema{
          type: :object,
          nullable: true,
          properties: %{
            entity: %OpenApiSpex.Schema{type: :string, description: "Вид записи, camelCase"},
            id: %OpenApiSpex.Schema{type: :string, description: "Идентификатор записи"},
            name: %OpenApiSpex.Schema{type: :string, nullable: true, description: "Текущее имя записи"}
          },
          required: ~w(entity id name)a
        }
      }
    end
  end

  defp properties(kind) when kind in ~w(group list)a,
    do: quote(do: %{value: %OpenApiSpex.Schema{type: :array, items: web_event_detail, nullable: true}})

  defp properties(:change), do: quote(do: %{old: web_event_detail, new: web_event_detail})
  defp properties(:destroyed), do: quote(do: %{})

  defp required(:change), do: ~w(label kind old new)a
  defp required(:destroyed), do: ~w(kind)a
  defp required(_kind), do: ~w(kind value)a

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
  defp by(dumped, by, refs, user_dump) when is_function(user_dump, 2), do: user_dump.(dumped, name!(refs, by))

  defp name!(refs, by) do
    case refs do
      %{^by => name} ->
        name

      %{} ->
        raise ArgumentError,
              "автор события #{inspect(by)}: нет в словаре ссылок — словарь собирают с той же страницы " <>
                "событий (`Core.Labels.Refs.get/2`)"
    end
  end
end
