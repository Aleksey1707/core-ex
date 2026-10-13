defmodule Core.Web.Labels do
  @moduledoc """
  Wire сведений события: название и сведения (`Core.Labels.Details`) → `%{title, details}` для JSON
  и OpenAPI-схема этого JSON (ADR-0063, ADR-0064).

  Подключается модулем приложения; свою часть формы — профиль кодека и ссылку на учётную запись —
  приложение задаёт опциями:

      defmodule MyAppWeb.Schemas.EventDetail do
        use Core.Web.Labels,
          codec: MyApp.Codec.External,
          user_ref: [
            dump: &MyAppWeb.Presenters.User.ref/2,
            schema: MyAppWeb.Schemas.UserRef
          ]
      end

  | Опция | Что задаёт |
  |---|---|
  | `codec:` | внешний профиль кодека приложения (модуль с `dump/1`): им дампятся Prim-значения и id |
  | `user_ref:` | ссылку на учётную запись: `dump:` — захват функции «дамп id, имя → map» арности 2 |

  `user_ref: [schema:]` — модуль схемы OpenApiSpex map'ы, которую отдаёт `dump:`; обязателен при
  `open_api_spex` у приложения (см. «Схема»).

  Порождает `to_wire/2`: событие и словарь ссылок страницы (`Core.Labels.Refs.get/2`) →
  `%{title: String.t(), details: [map()]}`. Презентер события вставляет их рядом со своими машинными
  полями; подмена строк-id в машинной нагрузке и дамп самого события остаются у приложения.

  | Сведение | На wire |
  |---|---|
  | вид | строкой: `"text"`, `"number"`, `"date"`, `"datetime"`, `"user"`, `"ref"`, `"group"`, `"list"`, `"change"` |
  | `:number` | строкой с десятичной точкой: integer — `Integer.to_string/1`, decimal — нормальная запись |
  | `:text`, `:date`, `:datetime` | Prim — дампом `codec:`, строка — как есть |
  | `:ref` | `%{entity, id, name}`: вид записи — camelCase атома, id — дампом `codec:`, имя — из словаря ссылок |
  | `:user` | результат `dump:` от дампа id и имени из словаря ссылок |
  | `:group`, `:list` | сведения и элементы — рекурсивно |
  | `:change` | `%{label, kind: "change", old, new}` |

  Строка, которую отдал кодек (`decimal: :string`), выходит как есть. У элемента списка и стороны
  изменения `label` нет; значения нет — `value: nil`. Id, которого нет в
  словаре ссылок, — `ArgumentError`: словарь собирают с той же страницы событий.

  ## Схема

  Если у приложения есть `open_api_spex` (проверка — при раскрытии `use`), модуль становится
  схемой семейства сведений: `schema/0` — `oneOf` по видам с дискриминатором `kind`. Схемы видов —
  вложенные модули `KindText`, `KindNumber`, `KindDate`, `KindDateTime`, `KindUser`, `KindRef`,
  `KindGroup`, `KindList`, `KindChange`; названия — от последнего сегмента имени модуля
  (`EventDetail`, `EventDetailText`, …). Сведения группы, списка и стороны изменения ссылаются на
  схему семейства, значение вида `user` — на `schema:` из `user_ref:`. Без `open_api_spex` модуль —
  только дамп, и `schema:` не требуется.

  Сборку ломают: нет `codec:` или `user_ref:`, `codec:` без `dump/1`, `user_ref:` без `dump:` или с
  неизвестной опцией, `dump:` не захватом функции арности 2; при `open_api_spex` — `user_ref:` без
  `schema:` или `schema:` без `schema/0`.

  Макрос занимает в модуле имя `to_wire/2`, при `open_api_spex` — ещё `schema/0` и имена вложенных
  модулей схем видов.
  """

  alias Core.Helper
  alias Core.Labels.Check
  alias Core.Labels.Details

  @typedoc "Название и сведения события для JSON."
  @type t :: %{title: String.t(), details: [detail()]}

  @typedoc "Сведение для JSON; у элемента списка и стороны изменения `label` нет."
  @type detail ::
          %{optional(:label) => String.t(), required(:kind) => String.t(), required(:value) => value()}
          | %{label: String.t(), kind: String.t(), old: detail(), new: detail()}

  @typedoc "Значение сведения: дамп кодека, число строкой, ссылка, ссылка на учётную запись, сведения группы."
  @type value :: String.t() | struct() | ref() | map() | [detail()] | nil

  @typedoc "Ссылка на запись."
  @type ref :: %{entity: String.t(), id: term(), name: String.t() | nil}

  @label "Web.Labels"
  @required_keys ~w(codec user_ref)a
  @optional_keys []
  @user_ref_required_keys ~w(dump)a
  @user_ref_optional_keys []
  @user_ref_schema_keys ~w(schema)a

  # Вид → вложенный модуль схемы, суффикс названия, описание.
  @variants [
    text: {quote(do: __MODULE__.KindText), "Text", "Текст: строка, подпись значения, «Да» / «Нет»"},
    number: {quote(do: __MODULE__.KindNumber), "Number", "Число строкой с десятичной точкой; единица — в подписи"},
    date: {quote(do: __MODULE__.KindDate), "Date", "Дата"},
    datetime: {quote(do: __MODULE__.KindDateTime), "DateTime", "Дата-время"},
    user: {quote(do: __MODULE__.KindUser), "User", "Ссылка на учётную запись"},
    ref: {quote(do: __MODULE__.KindRef), "Ref", "Ссылка на запись: вид записи, id и текущее имя"},
    group: {quote(do: __MODULE__.KindGroup), "Group", "Сведения вложенного значения"},
    list: {
      quote(do: __MODULE__.KindList),
      "List",
      "Элементы одного вида без подписи; у map'ы с id в ключах — группы «ключ — значение»"
    },
    change: {quote(do: __MODULE__.KindChange), "Change", "Изменение: было и стало — сведения без подписи"}
  ]

  # ===== объявление =====

  @doc """
  Объявить дамп сведений: профиль кодека (`codec:`) и ссылку на учётную запись (`user_ref:`); при
  `open_api_spex` у приложения — и их схему.
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
  @spec user_dump!(module(), term(), boolean()) :: (term(), String.t() | nil -> map())

  def user_dump!(module, user_ref, schema?) when is_atom(module) and is_boolean(schema?) do
    where = "#{@label} #{inspect(module)}: user_ref"

    {required, optional} =
      case schema? do
        true -> {@user_ref_required_keys ++ @user_ref_schema_keys, @user_ref_optional_keys}
        false -> {@user_ref_required_keys, @user_ref_optional_keys ++ @user_ref_schema_keys}
      end

    Helper.Opts.validate!(user_ref, required, optional, where)
    Check.capture!(Keyword.fetch!(user_ref, :dump), 2, "#{where}: dump:")
  end

  @doc false
  @spec user_schema!(module(), keyword()) :: module()

  def user_schema!(module, user_ref) when is_atom(module) and is_list(user_ref),
    do: Helper.Opts.module!(user_ref, :schema, "#{@label} #{inspect(module)}: user_ref", exports: [schema: 0])

  # ---

  defp wire(opts, schema?) do
    quote bind_quoted: [opts: opts, schema?: schema?], generated: true do
      Core.Helper.Opts.validate!(
        opts,
        Core.Web.Labels.required_keys(),
        Core.Web.Labels.optional_keys(),
        "Web.Labels"
      )

      @web_labels_codec Core.Helper.Opts.module!(opts, :codec, "Web.Labels", exports: [dump: 1])
      @web_labels_user_dump Core.Web.Labels.user_dump!(__MODULE__, Keyword.fetch!(opts, :user_ref), schema?)

      @doc "Название и сведения события для JSON по словарю ссылок страницы."
      @spec to_wire(Core.Es.Event.t(), Core.Labels.Refs.t()) :: Core.Web.Labels.t()

      def to_wire(%_{payload: _} = event, refs) when is_map(refs) do
        case Core.Web.Labels.to_wire(event, refs, @web_labels_codec, @web_labels_user_dump) do
          %{title: title, details: details} when is_binary(title) and is_list(details) ->
            %{title: title, details: details}
        end
      end
    end
  end

  # Модули схем — только в `quote`: на `OpenApiSpex` ссылается код приложения, у которого он есть,
  # а модуль библиотеки собирается и без него (ADR-0064). Не `OpenApiSpex.schema/2`: тот выключает
  # предупреждения всего модуля, а с ним — и порождённой `to_wire/2`.
  defp schemas(opts) do
    quote generated: true do
      web_labels_title = List.last(Module.split(__MODULE__))
      web_labels_user = Core.Web.Labels.user_schema!(__MODULE__, Keyword.fetch!(unquote(opts), :user_ref))
      web_labels_detail = %OpenApiSpex.Reference{"$ref": "#/components/schemas/#{web_labels_title}"}

      unquote_splicing(Enum.map(@variants, &variant/1))

      @behaviour OpenApiSpex.Schema

      @web_labels_schema OpenApiSpex.build_schema(
                           %{
                             title: web_labels_title,
                             description: "Сведение события: вид — в `kind`",
                             type: :object,
                             oneOf: unquote(for {_kind, {module, _suffix, _description}} <- @variants, do: module),
                             discriminator: %OpenApiSpex.Discriminator{
                               propertyName: "kind",
                               mapping:
                                 Map.new(
                                   unquote(
                                     for {kind, {_module, suffix, _description}} <- @variants, do: {"#{kind}", suffix}
                                   ),
                                   fn {kind, suffix} -> {kind, "#/components/schemas/#{web_labels_title}#{suffix}"} end
                                 )
                             }
                           },
                           struct?: false
                         )

      @doc "OpenAPI-схема сведения события: `oneOf` по видам, дискриминатор `kind`."
      @spec schema() :: OpenApiSpex.Schema.t()

      @impl true
      def schema, do: @web_labels_schema
    end
  end

  defp variant({kind, {module, suffix, description}}) do
    quote generated: true do
      defmodule unquote(module) do
        @moduledoc unquote("Сведение события вида `#{kind}`.")

        @behaviour OpenApiSpex.Schema

        @web_labels_schema OpenApiSpex.build_schema(
                             %{
                               title: web_labels_title <> unquote(suffix),
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
        def schema, do: @web_labels_schema
      end
    end
  end

  defp properties(:text), do: quote(do: %{value: %OpenApiSpex.Schema{type: :string, nullable: true}})

  defp properties(:number),
    do: quote(do: %{value: %OpenApiSpex.Schema{type: :string, nullable: true, example: "4.5"}})

  defp properties(:date), do: quote(do: %{value: %OpenApiSpex.Schema{type: :string, format: :date, nullable: true}})

  defp properties(:datetime),
    do: quote(do: %{value: %OpenApiSpex.Schema{type: :string, format: :"date-time", nullable: true}})

  defp properties(:user), do: quote(do: %{value: %OpenApiSpex.Schema{allOf: [web_labels_user], nullable: true}})

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
    do: quote(do: %{value: %OpenApiSpex.Schema{type: :array, items: web_labels_detail, nullable: true}})

  defp properties(:change), do: quote(do: %{old: web_labels_detail, new: web_labels_detail})

  defp required(:change), do: ~w(label kind old new)a
  defp required(_kind), do: ~w(kind value)a

  # ===== дамп =====

  @doc false
  @spec to_wire(struct(), %{struct() => String.t() | nil}, module(), (term(), String.t() | nil -> map())) :: t()

  def to_wire(%_{payload: _} = event, refs, codec, user_dump)
      when is_map(refs) and is_atom(codec) and is_function(user_dump, 2) do
    {title, details} = Details.build(event)
    env = %{refs: refs, codec: codec, user_dump: user_dump}

    %{title: title, details: Enum.map(details, &detail(&1, env))}
  end

  # ---

  defp detail(%{kind: :change, old: old, new: new} = detail, env),
    do: labelled(detail, %{kind: "change", old: detail(old, env), new: detail(new, env)})

  defp detail(%{kind: kind, value: value} = detail, env),
    do: labelled(detail, %{kind: Atom.to_string(kind), value: value(detail, value, env)})

  defp labelled(%{label: label}, dumped), do: Map.put(dumped, :label, label)
  defp labelled(%{}, dumped), do: dumped

  defp value(_detail, nil, _env), do: nil
  defp value(%{kind: kind}, details, env) when kind in ~w(group list)a, do: Enum.map(details, &detail(&1, env))
  defp value(%{kind: :user}, id, env), do: env.user_dump.(env.codec.dump(id), name!(env.refs, id))

  defp value(%{kind: :ref, entity: entity}, id, env),
    do: %{entity: Helper.Keys.camelize_key(entity), id: env.codec.dump(id), name: name!(env.refs, id)}

  defp value(%{kind: :number}, number, env), do: number(dump(number, env))
  defp value(%{kind: kind}, value, env) when kind in ~w(text date datetime)a, do: dump(value, env)

  defp name!(refs, id) do
    case refs do
      %{^id => name} ->
        name

      %{} ->
        raise ArgumentError,
              "#{inspect(id)}: нет в словаре ссылок — словарь собирают с той же страницы событий " <>
                "(`Core.Labels.Refs.get/2`)"
    end
  end

  defp dump(%_{} = prim, env), do: env.codec.dump(prim)
  defp dump(value, _env), do: value

  # Число — строкой с десятичной точкой, как `Decimal` на wire: без потери точности.
  defp number(number) when is_binary(number), do: number
  defp number(number) when is_integer(number), do: Integer.to_string(number)
  defp number(%Decimal{} = number), do: Decimal.to_string(number, :normal)
end
