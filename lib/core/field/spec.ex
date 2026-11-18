defmodule Core.Field.Spec do
  @moduledoc false

  # Грамматика спеки поля: виды и allowlist хоста, режимы, проверки и разбор одной декларации в
  # нормализованные спеки значений. Роль-потребитель собирает из них IR (`Core.Field`).
  #
  # Модуль не ссылается на `Core.Field` ни в коде, ни в типах: `Core.Field` вызывает его, и
  # обратная ссылка замкнула бы граф сборки (`make xref`).

  alias Core.Helper
  alias Core.Helper.FieldCheck
  alias Core.Prim

  @base_kinds ~w(prim enum entity union list set map type)a
  # `plugin` — набор видов, которые кодирует Codec-плагин по декларациям типов; полей он больше не
  # объявляет, поэтому разбора в этой роли нет.
  @host_kinds [
    struct: @base_kinds,
    plugin: @base_kinds,
    payload: @base_kinds,
    labels: @base_kinds,
    view: ~w(prim enum type view form list set map jsonb)a
  ]
  @kinds @host_kinds
         |> Keyword.values()
         |> Enum.concat()
         |> Enum.uniq()
  @host_names %{
    struct: "структура по полям",
    plugin: "Codec-плагин по полям",
    payload: "нагрузка события",
    labels: "подписи",
    view: "View"
  }
  # Семантические группы видов для обходов подписей: у видов с модулем значения значение задаёт
  # модуль, у группы оно раскрывается полями struct'а (`entity:` — объект, `union:` — вариант).
  @value_module_kinds ~w(prim enum entity union)a
  @group_kinds ~w(entity union)a
  @extra_keys ~w(optional wire)a
  @type_values FieldCheck.type_values()
  @collection_kinds ~w(list set)a
  @map_keys ~w(key value)a
  @string_kinds ~w(string uuid)a

  @typedoc "Нормализованная спека значения поля."
  @type spec ::
          {:prim, module()}
          | {:enum, module()}
          | {:entity, module()}
          | {:union, module()}
          | {:list, spec()}
          | {:set, spec()}
          | {:map, spec(), spec()}
          | {:type, atom()}
          | {:view, module()}
          | {:form, atom()}
          | {:jsonb, module() | {module(), atom()}}

  @typedoc """
  Значение `default:`: нет; у структуры — типизированное значение поля (его ставит `Core.Struct`
  уже после разбора).
  """
  @type default :: :none | {:default, term()}

  @typedoc """
  Разобранное поле до реестра метаданных: имя, вид, `optional:`, wire-ключ, `default:`, объявленный
  субъект и объявленный флаг ПДн-места.
  """
  @type declaration :: %{
          name: atom(),
          spec: spec(),
          optional?: boolean(),
          wire: String.t(),
          default: default(),
          subject: term(),
          personal: boolean() | nil
        }

  @typedoc """
  Режим разбора: `:payload` — нагрузка события (`subject:` разрешён, `default:` — нет), `:labels` —
  подписи, `:struct` — структура по полям (`default:` ставит `Core.Struct` уже после разбора).
  """
  @type mode :: :payload | :labels | :struct

  # ===== таблица видов =====

  @doc false
  @spec kinds() :: [atom()]

  def kinds, do: @kinds

  @doc false
  @spec kinds(atom()) :: [atom()]

  def kinds(host) when is_atom(host), do: kinds!(host)

  @doc false
  @spec check_kinds!(atom(), [atom()], [atom()], String.t()) :: :ok

  # Набор, который свитч обязан обработать: allowlist хоста плюс явные host-extra виды.
  # Сравнение в обе стороны: пропущенный вид — ошибка сборки, лишний — мёртвая клауза.
  def check_kinds!(host, handled, extras, where)
      when is_atom(host) and is_list(handled) and is_list(extras) and is_binary(where) do
    expected = Enum.uniq(kinds!(host) ++ extras)
    handled = Enum.uniq(handled)
    missing = Enum.sort(expected -- handled)
    extra = Enum.sort(handled -- expected)

    case {missing, extra} do
      {[], []} -> :ok
      {missing, extra} -> Helper.Opts.reject!(where, gaps_text(missing, extra))
    end
  end

  @doc false
  @spec value_module_kinds() :: [atom()]

  def value_module_kinds, do: @value_module_kinds

  @doc false
  @spec group_kinds() :: [atom()]

  def group_kinds, do: @group_kinds

  @doc false
  @spec kind_key!(keyword(), atom(), String.t()) :: {atom(), term()}

  def kind_key!(opts, host, where) when is_list(opts) and is_atom(host) and is_binary(where) do
    allowed = kinds!(host)
    opts = Keyword.delete(opts, :optional)

    case foreign_kind(Keyword.keys(opts), allowed) do
      nil -> kind_value!(opts, allowed, where)
      kind -> reject_foreign!(kind, host, allowed, where, "")
    end
  end

  # ---

  defp gaps_text(missing, extra) do
    [
      if(missing != [], do: "нет обработки для видов #{inspect(missing)}"),
      if(extra != [], do: "виды вне allowlist: #{inspect(extra)}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("; ")
  end

  defp kinds_text(allowed, other),
    do: "ожидается ровно один из #{Enum.map_join(allowed, "/", &"#{&1}:")}, получено #{inspect(other)}"

  defp kind_value!([{kind, value}], allowed, where) do
    if kind in allowed,
      do: {kind, value},
      else: Helper.Opts.reject!(where, kinds_text(allowed, [{kind, value}]))
  end

  defp kind_value!(other, allowed, where), do: Helper.Opts.reject!(where, kinds_text(allowed, other))

  # ===== разбор =====

  @doc false
  @spec parse!(term(), mode(), String.t()) :: [declaration()]

  def parse!(spec, :payload, where) when is_binary(where) do
    case defaults(spec) do
      [] ->
        spec
        |> spec_fields!(:payload, where)
        |> check_payload_wires!(where)

      names ->
        Helper.Opts.reject!(
          where,
          "default: у нагрузки события нет (поля #{inspect(names)}): развитие события — новый тег и апкаст"
        )
    end
  end

  def parse!(spec, mode, where) when mode in ~w(labels struct)a and is_binary(where),
    do: spec_fields!(spec, mode, where)

  @doc false
  @spec struct_module!(module(), String.t()) :: :ok

  def struct_module!(mod, where) do
    FieldCheck.module!(mod, where)

    if not Core.Helper.Module.exports?(mod, :__struct__, 0) do
      Helper.Opts.reject!(where, "#{inspect(mod)} не struct")
    end

    :ok
  end

  @doc false
  @spec value_spec(module(), String.t()) :: spec()

  def value_spec(mod, where) when is_atom(mod) do
    FieldCheck.module!(mod, where)

    cond do
      Prim.prim?(mod) -> {:prim, mod}
      Core.Enum.enum?(mod) -> {:enum, mod}
      true -> kind_spec!(:entity, mod, :payload, where)
    end
  end

  @doc false
  @spec map_opts!(term(), String.t()) :: {keyword(), keyword()}

  def map_opts!(inner, where) when is_binary(where) do
    if not Keyword.keyword?(inner) or Enum.sort(Keyword.keys(inner)) != @map_keys do
      Helper.Opts.reject!(where, "map: ожидается [key: спека, value: спека], получено #{inspect(inner)}")
    end

    {Keyword.fetch!(inner, :key), Keyword.fetch!(inner, :value)}
  end

  # ---

  defp defaults(spec) do
    if Keyword.keyword?(spec),
      do: for({name, opts} <- spec, Keyword.keyword?(opts), Keyword.has_key?(opts, :default), do: name),
      else: []
  end

  defp spec_fields!(spec, mode, where) do
    if not Keyword.keyword?(spec) or spec == [] do
      Helper.Opts.reject!(where, "ожидается непустой keyword-список полей, получено #{inspect(spec)}")
    end

    FieldCheck.unique!(Keyword.keys(spec), where)
    fields = Enum.map(spec, fn {name, opts} -> field!(name, opts, mode, "#{where}: #{name}") end)
    FieldCheck.unique!(Enum.map(fields, & &1.wire), "#{where}: wire")

    fields
  end

  defp field!(name, opts, mode, where) do
    if not Keyword.keyword?(opts) do
      Helper.Opts.reject!(where, "ожидается keyword-спека, получено #{inspect(opts)}")
    end

    reject_destroyable!(opts, where)

    extra = @extra_keys ++ if(mode in ~w(payload struct)a, do: [:subject], else: []) ++ personal_keys(mode)

    case Keyword.keys(opts) -- (@kinds ++ extra) do
      [] -> :ok
      unknown -> Helper.Opts.reject!(where, "неизвестные ключи #{inspect(unknown)}")
    end

    spec = spec!(opts, mode, extra, where)
    optional? = optional!(opts, where)

    %{
      name: name,
      spec: spec,
      optional?: optional?,
      wire: wire!(name, opts, where),
      default: :none,
      subject: subject!(opts, where),
      personal: personal!(opts, where)
    }
  end

  # `destroyable:` удалён из языка: ПДн-место объявляет `personal: true`, а `Destroyed.t()` на нём
  # даёт тип чтения. Ключ отвергается в любом режиме и на любой глубине спеки.
  defp reject_destroyable!(opts, where) do
    if destroyable_key?(opts) do
      Helper.Opts.reject!(
        where,
        "destroyable: удалён — ПДн-место объявляет personal: true, а уничтоженное значение даёт тип чтения"
      )
    end

    :ok
  end

  defp destroyable_key?(spec) do
    Keyword.keyword?(spec) and
      (Keyword.has_key?(spec, :destroyable) or Enum.any?(Keyword.values(spec), &destroyable_key?/1))
  end

  defp spec!(opts, mode, extra, where) do
    {kind, value} = kind_key!(Keyword.drop(opts, extra), mode, where)
    kind_spec!(kind, value, mode, where)
  end

  defp kind_spec!(:prim, mod, _mode, where) do
    FieldCheck.prim!(mod, where)
    {:prim, mod}
  end

  defp kind_spec!(:enum, mod, _mode, where) do
    FieldCheck.enum!(mod, where)
    {:enum, mod}
  end

  defp kind_spec!(:entity, mod, _mode, where) do
    struct_module!(mod, where)
    {:entity, mod}
  end

  # Семейство struct не имеет: struct здесь — вариант или Prim, а модуль `Core.Enum` — enum, и поле
  # с ними работало бы на одном значении и молча ломалось на остальных.
  defp kind_spec!(:union, mod, _mode, where) do
    FieldCheck.module!(mod, where)

    cond do
      Core.Helper.Module.exports?(mod, :__struct__, 0) ->
        Helper.Opts.reject!(where, "union: #{inspect(mod)} — struct, а не семейство; нужен entity: или prim:")

      Core.Enum.enum?(mod) ->
        Helper.Opts.reject!(where, "union: #{inspect(mod)} — Core.Enum, а не семейство; нужен enum:")

      true ->
        {:union, mod}
    end
  end

  defp kind_spec!(kind, inner, mode, where) when kind in @collection_kinds,
    do: {kind, element_spec!("#{kind}", "элемента", inner, mode, where)}

  defp kind_spec!(:map, inner, mode, where) do
    {key_opts, value_opts} = map_opts!(inner, where)
    key = element_spec!("map: key", "ключа", key_opts, mode, where)
    check_map_key!(key, key_opts, where)

    {:map, key, element_spec!("map: value", "значения", value_opts, mode, where)}
  end

  defp kind_spec!(:type, type, _mode, _where) when type in @type_values, do: {:type, type}

  defp kind_spec!(:type, type, _mode, where) do
    Helper.Opts.reject!(where, "неизвестный type: #{inspect(type)}, ожидается один из #{inspect(@type_values)}")
  end

  defp element_spec!(label, role, inner, mode, where) do
    if not Keyword.keyword?(inner) do
      Helper.Opts.reject!(where, "#{label}: ожидается keyword-спека #{role}, получено #{inspect(inner)}")
    end

    if Keyword.has_key?(inner, :optional) do
      Helper.Opts.reject!(where, "optional: задаётся у самого поля, не в #{label}:")
    end

    allowed = kinds!(mode)

    case foreign_kind(Keyword.keys(inner), allowed) do
      nil ->
        case Keyword.keys(inner) -- allowed do
          [] -> spec!(inner, mode, [], where)
          unknown -> Helper.Opts.reject!(where, "#{label}: неизвестные ключи #{inspect(unknown)}")
        end

      kind ->
        reject_foreign!(kind, mode, allowed, where, "#{label}: ")
    end
  end

  defp optional!(opts, where) do
    case Keyword.get(opts, :optional, false) do
      optional? when is_boolean(optional?) -> optional?
      other -> Helper.Opts.reject!(where, "optional: ожидается boolean, получено #{inspect(other)}")
    end
  end

  # `personal:` — объявленный флаг ПДн-места поля: метаданные разбирает `Core.Field.Meta`, грамматика
  # принимает ключ в ролях, которым он доступен. У плагина флага нет: шифрование — свойство нагрузки
  # события и структуры, а не wire-формы.
  defp personal_keys(mode) when mode in ~w(struct payload labels)a, do: [:personal]
  defp personal_keys(_mode), do: []

  defp personal!(opts, where) do
    case Keyword.fetch(opts, :personal) do
      :error -> nil
      {:ok, personal?} when is_boolean(personal?) -> personal?
      {:ok, other} -> Helper.Opts.reject!(where, "personal: ожидается boolean, получено #{inspect(other)}")
    end
  end

  defp wire!(name, opts, where) do
    case Keyword.fetch(opts, :wire) do
      :error -> Atom.to_string(name)
      {:ok, wire} when is_binary(wire) and wire != "" -> wire
      {:ok, other} -> Helper.Opts.reject!(where, "wire: ожидается непустая строка, получено #{inspect(other)}")
    end
  end

  defp subject!(opts, where) do
    case Keyword.fetch(opts, :subject) do
      :error ->
        nil

      {:ok, subject} when is_atom(subject) and subject not in ~w(nil true false)a ->
        subject

      {:ok, {tag, name}} when tag in ~w(payload local)a and is_atom(name) and name not in ~w(nil true false)a ->
        {tag, name}

      {:ok, other} ->
        Helper.Opts.reject!(
          where,
          "subject: ожидается :aggregate_id или имя поля нагрузки; вложенный адрес субъекта — " <>
            "{:payload, поле} или {:local, поле}; получено #{inspect(other)}"
        )
    end
  end

  # Нагрузка события: wire-ключ на `$` совпал бы с зарезервированной формой `{"$pd": …}` (ADR-0073).
  defp check_payload_wires!(fields, where) do
    Enum.each(fields, fn %{name: name, wire: wire} -> check_wire!(wire, "#{where}: #{name}") end)

    fields
  end

  defp check_wire!("$" <> _rest = wire, where) do
    Helper.Opts.reject!(where, "wire-ключ #{inspect(wire)} начинается с $ — форма {\"$pd\": …} зарезервирована")
  end

  defp check_wire!(_wire, _where), do: :ok

  # ===== ключ словаря =====

  # Ключ объекта — строка: ключ с другим wire пришлось бы переводить в строку и разбирать обратно, а
  # открытый в wire и индексе `jsonb` ключ не зашифровать (ADR-0091). Ключ спеки другого режима
  # (`Core.View`) приходит в его форме: всё, кроме `{:prim, _}`, `{:enum, _}` и `{:type, :string}`, — отказ.
  @doc false
  @spec check_map_key!(term(), keyword(), String.t()) :: :ok

  def check_map_key!({:prim, mod}, key_opts, where) when is_binary(where) do
    cond do
      not string_prim?(mod) ->
        reject_key!(key_opts, where)

      mod.__domain_personal__() or mod.__domain_sensitive__() ->
        Helper.Opts.reject!(
          where,
          "map: key: Prim #{inspect(mod)} с personal: true или sensitive: — ключ лежит в wire открыто"
        )

      true ->
        :ok
    end
  end

  def check_map_key!({:enum, _mod}, _key_opts, where) when is_binary(where), do: :ok
  def check_map_key!({:type, :string}, _key_opts, where) when is_binary(where), do: :ok
  def check_map_key!(_spec, key_opts, where) when is_binary(where), do: reject_key!(key_opts, where)

  # ---

  # Wire Prim задаёт kind: Prim со своим kind (`kind: :slug` над `Prim.String`) кодек дампит своей
  # клаузой `dump_kind/2`, и строка ли это — при сборке неизвестно; такой ключ отвергается.
  defp string_prim?(mod) do
    {links, [leaf]} = Enum.split(Prim.chain(mod), -1)

    Enum.all?(links, &(&1.__domain_kind__() == :composite)) and leaf.__domain_kind__() in @string_kinds
  end

  @spec reject_key!(term(), String.t()) :: no_return()

  defp reject_key!(key_opts, where),
    do: Helper.Opts.reject!(where, "map: key: ожидается вид с wire-строкой, получено #{inspect(key_opts)}")

  # ===== вложенные спеки =====

  # Вложенные спеки вкладываются в той же форме: `{:list, _}`, `{:set, _}`, `{:map, ключ, значение}`;
  # остальные виды вложенных спек не держат.
  @doc false
  @spec children(term()) :: [term()]

  def children({kind, inner}) when kind in @collection_kinds, do: [inner]
  def children({:map, key, value}), do: [key, value]
  def children(_spec), do: []

  # Значение словаря без ключа: ключ — вид с wire-строкой, и обход, которому важно значение
  # (ПДн, вложенный struct, map'а), в ключ не заходит.
  @doc false
  @spec values(term()) :: [term()]

  def values({:map, _key, value}), do: [value]
  def values(spec), do: children(spec)

  # ===== тип =====

  @doc false
  @spec union_type([Macro.t()]) :: Macro.t()

  # Объединение справа (`A | (B | nil)`): так `Macro.to_string/1` печатает тип плоско.
  def union_type(types) do
    [last | rest] = Enum.reverse(Enum.flat_map(types, &alternatives/1))

    Enum.reduce(rest, last, &quote(do: unquote(&1) | unquote(&2)))
  end

  # ---

  defp alternatives({:|, _meta, [left, right]}), do: [left | alternatives(right)]
  defp alternatives(type), do: [type]

  # ===== общее =====

  defp kinds!(:view), do: Keyword.fetch!(@host_kinds, :view)
  defp kinds!(host), do: Keyword.fetch!(@host_kinds, host)

  defp host_name(host), do: Map.fetch!(@host_names, host)

  defp foreign_kind(keys, allowed), do: Enum.find(keys, &(&1 in @kinds and &1 not in allowed))

  @spec reject_foreign!(atom(), atom(), [atom()], String.t(), String.t()) :: no_return()

  defp reject_foreign!(kind, host, allowed, where, prefix) do
    Helper.Opts.reject!(
      where,
      "#{prefix}вид #{kind}: недопустим в хосте «#{host_name(host)}» — ожидается ровно один из " <>
        Enum.map_join(allowed, "/", &"#{&1}:")
    )
  end
end
