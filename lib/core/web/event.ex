defmodule Core.Web.Event do
  @moduledoc """
  Событие страницы событий: событие и словарь ссылок страницы → map для JSON (ADR-0066).

  Подключается модулем приложения; свою часть формы — профиль кодека, ссылку на учётную запись и
  подписи — приложение задаёт опциями:

      defmodule MyAppWeb.Schemas.Event do
        use Core.Web.Event,
          codec: MyApp.Codec.External,
          user_ref: [dump: &MyAppWeb.Presenters.User.ref/2],
          labels: true
      end

  | Опция | Обязательность | Что задаёт |
  |---|---|---|
  | `codec:` | обязательна | внешний профиль кодека приложения (модуль с `dump/1`): им дампятся конверт события и значения сведений |
  | `user_ref:` | необязательна | ссылку на учётную запись: `dump:` — захват функции «дамп id, имя → map» арности 2 |
  | `labels:` | необязательна, `false` | `true` — название и сведения события (`Core.Labels.Details`) в `title` и `details`; требует `user_ref:` |

  Порождает `to_wire/2`: событие и словарь ссылок страницы (`Core.Labels.Refs.get/2`) → map.

  | Поле | На wire |
  |---|---|
  | `id`, `aggregateId`, `type`, `at` | поля конверта дампом `codec:` |
  | `version` | версия агрегата после события |
  | `payload` | нагрузка конверта, ключи — camelCase; id в ней — строки дампа, без подмены ссылками |
  | `by` | без `user_ref:` — дамп id; с ним — результат `dump:` от дампа id и имени из словаря ссылок |
  | `title` | при `labels: true` — название события |
  | `details` | при `labels: true` — сведения события (таблица ниже) |

  | Сведение | На wire |
  |---|---|
  | вид | строкой: `"text"`, `"number"`, `"date"`, `"datetime"`, `"user"`, `"ref"`, `"group"`, `"list"`, `"change"` |
  | `:number` | строкой с десятичной точкой: integer — `Integer.to_string/1`, decimal — нормальная запись |
  | `:text`, `:date`, `:datetime` | Prim — дампом `codec:`, строка — как есть |
  | `:ref` | `%{entity, id, name}`: вид записи — camelCase атома, id — дампом `codec:`, имя — из словаря ссылок |
  | `:user` | результат `dump:` от дампа id и имени из словаря ссылок — той же формы, что `by` |
  | `:group`, `:list` | сведения и элементы — рекурсивно |
  | `:change` | `%{label, kind: "change", old, new}` |

  Строка, которую отдал кодек (`decimal: :string`), выходит как есть. У элемента списка и стороны
  изменения `label` нет; значения нет — `value: nil`.

  Автор или id сведений, которых нет в словаре ссылок при `user_ref:`, — `ArgumentError`: словарь
  собирают с той же страницы событий. Без `user_ref:` словарь не читается — подходит и пустой.

  Точечная правка — дело приложения: `%{MyEvent.to_wire(event, refs) | payload: nil}`.

  Сборку ломают: нет `codec:`, `codec:` без `dump/1`, неизвестная опция, `user_ref:` без `dump:` или с
  неизвестной опцией, `dump:` не захватом функции арности 2, `labels:` не boolean, `labels: true` без
  `user_ref:`.

  Макрос занимает в модуле имя `to_wire/2`.
  """

  alias Core.Es
  alias Core.Helper
  alias Core.Labels.Check
  alias Core.Web.Event.Details

  @typedoc "Событие страницы событий для JSON."
  @type t :: %{
          id: String.t(),
          aggregateId: String.t(),
          version: pos_integer(),
          type: String.t(),
          payload: term(),
          at: String.t(),
          by: String.t() | map()
        }

  @typedoc "Событие страницы событий для JSON с названием и сведениями (`labels: true`)."
  @type labelled :: %{
          id: String.t(),
          aggregateId: String.t(),
          version: pos_integer(),
          type: String.t(),
          payload: term(),
          at: String.t(),
          by: map(),
          title: String.t(),
          details: [detail()]
        }

  @typedoc "Сведение для JSON; у элемента списка и стороны изменения `label` нет."
  @type detail ::
          %{optional(:label) => String.t(), required(:kind) => String.t(), required(:value) => value()}
          | %{label: String.t(), kind: String.t(), old: detail(), new: detail()}

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

  # ===== объявление =====

  @doc """
  Объявить дамп события страницы событий: профиль кодека (`codec:`), ссылку на учётную запись
  (`user_ref:`) и подписи (`labels:`).
  """
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts], generated: true do
      Core.Helper.Opts.validate!(
        opts,
        Core.Web.Event.required_keys(),
        Core.Web.Event.optional_keys(),
        "Web.Event"
      )

      @web_event_codec Core.Helper.Opts.module!(opts, :codec, "Web.Event", exports: [dump: 1])
      @web_event_user_dump Core.Web.Event.user_dump!(__MODULE__, Keyword.get(opts, :user_ref))
      @web_event_labels Core.Web.Event.labels!(__MODULE__, opts)

      case @web_event_labels do
        false ->
          @doc "Событие страницы событий для JSON по словарю ссылок страницы."
          @spec to_wire(Core.Es.Event.t(), Core.Labels.Refs.t()) :: Core.Web.Event.t()

          def to_wire(%_{payload: _} = event, refs) when is_map(refs) do
            case Core.Web.Event.to_wire(event, refs, @web_event_codec, @web_event_user_dump, false) do
              %{id: id, aggregateId: aggregate_id, version: version, type: type, payload: payload, at: at, by: by}
              when is_binary(type) and is_integer(version) ->
                %{id: id, aggregateId: aggregate_id, version: version, type: type, payload: payload, at: at, by: by}
            end
          end

        true ->
          @doc "Событие страницы событий с названием и сведениями для JSON по словарю ссылок страницы."
          @spec to_wire(Core.Es.Event.t(), Core.Labels.Refs.t()) :: Core.Web.Event.labelled()

          def to_wire(%_{payload: _} = event, refs) when is_map(refs) do
            case Core.Web.Event.to_wire(event, refs, @web_event_codec, @web_event_user_dump, true) do
              %{
                id: id,
                aggregateId: aggregate_id,
                version: version,
                type: type,
                payload: payload,
                at: at,
                by: %{} = by,
                title: title,
                details: details
              }
              when is_binary(type) and is_integer(version) and is_binary(title) and is_list(details) ->
                %{
                  id: id,
                  aggregateId: aggregate_id,
                  version: version,
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
  end

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys

  @doc false
  @spec user_dump!(module(), keyword() | nil) :: user_dump() | nil

  def user_dump!(module, nil) when is_atom(module), do: nil

  def user_dump!(module, user_ref) when is_atom(module) do
    where = "#{@label} #{inspect(module)}: user_ref"

    Helper.Opts.validate!(user_ref, @user_ref_required_keys, @user_ref_optional_keys, where)
    Check.capture!(Keyword.fetch!(user_ref, :dump), 2, "#{where}: dump:")
  end

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

  # ===== дамп =====

  @doc false
  @spec to_wire(struct(), Core.Labels.Refs.t(), module(), user_dump() | nil, boolean()) :: t() | labelled()

  def to_wire(%_{by: by} = event, refs, codec, user_dump, labels?)
      when is_map(refs) and is_atom(codec) and is_boolean(labels?) do
    fields = Es.Event.Codec.to_fields(codec.dump(event))

    wire = %{
      id: fields.id,
      aggregateId: fields.aggregate_id,
      version: fields.aggregate_version,
      type: fields.type,
      payload: Helper.Keys.camelize(fields.payload),
      at: fields.at,
      by: by(fields.by, by, refs, user_dump)
    }

    case labels? do
      false -> wire
      true -> Map.merge(wire, Details.to_wire(event, refs, codec, user_dump))
    end
  end

  # ---

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
