defmodule Core.Web.Event do
  @moduledoc """
  Событие страницы событий: событие и словарь ссылок страницы → map для JSON (ADR-0066).

  Подключается модулем приложения; свою часть формы — профиль кодека и ссылку на учётную запись —
  приложение задаёт опциями:

      defmodule MyAppWeb.Schemas.Event do
        use Core.Web.Event,
          codec: MyApp.Codec.External,
          user_ref: [dump: &MyAppWeb.Presenters.User.ref/2]
      end

  | Опция | Обязательность | Что задаёт |
  |---|---|---|
  | `codec:` | обязательна | внешний профиль кодека приложения (модуль с `dump/1`): им дампится конверт события |
  | `user_ref:` | необязательна | ссылку на учётную запись: `dump:` — захват функции «дамп id, имя → map» арности 2 |

  Порождает `to_wire/2`: событие и словарь ссылок страницы (`Core.Labels.Refs.get/2`) → map.

  | Поле | На wire |
  |---|---|
  | `id`, `aggregateId`, `type`, `at` | поля конверта дампом `codec:` |
  | `version` | версия агрегата после события |
  | `payload` | нагрузка конверта, ключи — camelCase; id в ней — строки дампа, без подмены ссылками |
  | `by` | без `user_ref:` — дамп id; с ним — результат `dump:` от дампа id и имени из словаря ссылок |

  Автор, которого нет в словаре ссылок при `user_ref:`, — `ArgumentError`: словарь собирают с той же
  страницы событий. Без `user_ref:` словарь не читается — подходит и пустой.

  Точечная правка — дело приложения: `%{MyEvent.to_wire(event, refs) | payload: nil}`.

  Сборку ломают: нет `codec:`, `codec:` без `dump/1`, неизвестная опция, `user_ref:` без `dump:` или с
  неизвестной опцией, `dump:` не захватом функции арности 2.

  Макрос занимает в модуле имя `to_wire/2`.
  """

  alias Core.Es
  alias Core.Helper
  alias Core.Labels.Check

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

  @typedoc "Дамп ссылки на учётную запись: дамп id и имя из словаря ссылок → map."
  @type user_dump :: (term(), String.t() | nil -> map())

  @label "Web.Event"
  @required_keys ~w(codec)a
  @optional_keys ~w(user_ref)a
  @user_ref_required_keys ~w(dump)a
  @user_ref_optional_keys []

  # ===== объявление =====

  @doc "Объявить дамп события страницы событий: профиль кодека (`codec:`) и ссылку на учётную запись (`user_ref:`)."
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

      @doc "Событие страницы событий для JSON по словарю ссылок страницы."
      @spec to_wire(Core.Es.Event.t(), Core.Labels.Refs.t()) :: Core.Web.Event.t()

      def to_wire(%_{payload: _} = event, refs) when is_map(refs) do
        case Core.Web.Event.to_wire(event, refs, @web_event_codec, @web_event_user_dump) do
          %{id: id, aggregateId: aggregate_id, version: version, type: type, payload: payload, at: at, by: by}
          when is_binary(type) and is_integer(version) ->
            %{id: id, aggregateId: aggregate_id, version: version, type: type, payload: payload, at: at, by: by}
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

  # ===== дамп =====

  @doc false
  @spec to_wire(struct(), Core.Labels.Refs.t(), module(), user_dump() | nil) :: t()

  def to_wire(%_{by: by} = event, refs, codec, user_dump) when is_map(refs) and is_atom(codec) do
    fields = Es.Event.Codec.to_fields(codec.dump(event))

    %{
      id: fields.id,
      aggregateId: fields.aggregate_id,
      version: fields.aggregate_version,
      type: fields.type,
      payload: Helper.Keys.camelize(fields.payload),
      at: fields.at,
      by: by(fields.by, by, refs, user_dump)
    }
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
