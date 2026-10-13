defmodule Core.Web.Labels do
  @moduledoc """
  Wire сведений события: название и сведения (`Core.Labels.Details`) → `%{title, details}` для JSON
  (ADR-0063, ADR-0064).

  Подключается модулем приложения; свою часть формы — профиль кодека и ссылку на учётную запись —
  приложение задаёт опциями:

      defmodule MyAppWeb.Presenters.EventLabels do
        use Core.Web.Labels,
          codec: MyApp.Codec.External,
          user_ref: [dump: &MyAppWeb.Presenters.User.ref/2]
      end

  | Опция | Что задаёт |
  |---|---|
  | `codec:` | внешний профиль кодека приложения (модуль с `dump/1`): им дампятся Prim-значения и id |
  | `user_ref:` | ссылку на учётную запись: `dump:` — захват функции «дамп id, имя → map» арности 2 |

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

  Сборку ломают: нет `codec:` или `user_ref:`, `codec:` без `dump/1`, `user_ref:` без `dump:` или с
  неизвестной опцией, `dump:` не захватом функции арности 2.

  Макрос занимает в модуле имя `to_wire/2`.
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

  # ===== объявление =====

  @doc "Объявить дамп сведений: профиль кодека (`codec:`) и ссылку на учётную запись (`user_ref:`)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts], generated: true do
      Core.Helper.Opts.validate!(
        opts,
        Core.Web.Labels.required_keys(),
        Core.Web.Labels.optional_keys(),
        "Web.Labels"
      )

      @web_labels_codec Core.Helper.Opts.module!(opts, :codec, "Web.Labels", exports: [dump: 1])
      @web_labels_user_dump Core.Web.Labels.user_dump!(__MODULE__, Keyword.fetch!(opts, :user_ref))

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

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys

  @doc false
  @spec user_dump!(module(), term()) :: (term(), String.t() | nil -> map())

  def user_dump!(module, user_ref) when is_atom(module) do
    where = "#{@label} #{inspect(module)}: user_ref"

    Helper.Opts.validate!(user_ref, @user_ref_required_keys, @user_ref_optional_keys, where)
    Check.capture!(Keyword.fetch!(user_ref, :dump), 2, "#{where}: dump:")
  end

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
