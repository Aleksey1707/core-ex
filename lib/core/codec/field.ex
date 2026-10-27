defmodule Core.Codec.Field do
  @moduledoc """
  Поле спеки полей и её грамматика: нормализатор keyword-спеки и его проверки.

  Спеку говорят Codec-плагин по полям (`use Core.Codec.Plugin, fields:`), варианты семейства,
  нагрузка события (`Core.Es.Event.Payload`), `Core.Es.ValueChanged` и подписи
  (`Core.Labels.Fields`) и структура по полям (`Core.Struct`). Поле объявляется keyword-спекой с
  ровно одним kind-ключом (`prim:` / `enum:` / `entity:` / `union:` / `list:` / `set:` / `map:` / `type:`)
  и ключами `optional: true` и `wire: "ключ"`; режимные ключи — `default:` у плагина, `subject:` у
  нагрузки (ADR-0056, ADR-0073). У структуры `wire:` и `subject:` нет: кодека у неё нет; `default:` у
  неё — выражение значения поля, а не wire-литерал: его снимает со спеки и ставит в поле `Core.Struct`
  (ADR-0090).

  Ключ словаря (`map: [key:, value:]`) — вид с wire-строкой: Prim со строковой базой (`Prim.String`,
  `Prim.UUID` и `Prim.Compose` над ними, kind встроенный), `enum:` или `type: :string`; ключ объекта
  лежит в wire открыто, поэтому Prim `personal: true` или `sensitive:` ключом не бывает (ADR-0091).

  Новый вид значения разбирают, кроме нормализатора: `dump` / `load` и сверка со структурой —
  `Core.Codec.Plugin.Fields`; пере-дамп — `Core.Codec.Plugin.Redump`, `Core.Codec.Redump`; тип и
  `default:` — `Core.Struct`; ПДн нагрузки — `Core.Es.Event.Payload`; View — `Core.View`,
  `Core.View.Opts`, `Core.View.Dumper`; подписи — `Core.Labels.Fields`, `Core.Labels.Details`,
  `Core.Labels.Refs`, `Core.Labels.CompletenessCase`; виды сведений на странице
  событий — `Core.Web.Event`. Вложенные спеки обходятся через `children/1` / `values/1`.

  Модуль внутренний для библиотеки.
  """

  alias Core.Helper
  alias Core.Helper.FieldCheck
  alias Core.Prim

  @label "Codec.Plugin"
  @kind_keys ~w(prim enum entity union list set map type)a
  @extra_keys ~w(optional wire default)a
  @skipped_keys ~w(__struct__ events)a
  @type_values FieldCheck.type_values()
  @collection_kinds ~w(list set)a
  @map_keys ~w(key value)a
  @string_kinds ~w(string uuid)a
  @checked_defaults ~w(enum set map)a

  @enforce_keys ~w(name spec optional? wire default subject)a
  defstruct @enforce_keys

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

  @typedoc """
  Значение `default:`: нет, wire-литерал у плагина или, у структуры, значение поля, вычисленное в
  теле модуля (`Core.Struct`).
  """
  @type default :: :none | {:default, term()}

  @typedoc """
  Субъект ПДн-поля нагрузки события (`subject:`): `:aggregate_id` или имя поля той же нагрузки;
  `nil` — поле без `subject:`. У плагина всегда `nil`.
  """
  @type subject :: atom() | nil

  @typedoc """
  Режим нормализации: `:plugin` — плагин с загрузкой (`default:` разрешён), `:dump_only` — плагин
  при `loadable: false`, `:payload` — нагрузка события (`subject:` разрешён, `default:` и wire-ключ на
  `$` — нет), `:labels` — подписи, `:struct` — структура по полям (`wire:` и `subject:` — нет,
  `default:` в спеку не приходит).
  """
  @type mode :: :plugin | :dump_only | :payload | :labels | :struct

  @typedoc "Нормализованное поле: имя, спека значения, необязательность, wire-ключ, `default:`, субъект."
  @type t :: %__MODULE__{
          name: atom(),
          spec: spec(),
          optional?: boolean(),
          wire: String.t(),
          default: default(),
          subject: subject()
        }

  # ===== спека =====

  @doc false
  @spec fields!(term(), boolean()) :: [{module(), [t()]}]

  def fields!(nil, _loadable?), do: []

  def fields!(fields, loadable?) when is_list(fields) do
    pairs = Enum.map(fields, &pair!/1)
    FieldCheck.unique!(Enum.map(pairs, &elem(&1, 0)), "#{@label}: fields")
    mode = if loadable?, do: :plugin, else: :dump_only

    Enum.map(pairs, fn {type, spec} ->
      {type, type_fields!(type, spec, [], mode, "#{@label}: fields: #{inspect(type)}")}
    end)
  end

  def fields!(other, _loadable?),
    do: Helper.Opts.reject!("#{@label}: fields", "ожидается список пар {Тип, спека}, получено #{inspect(other)}")

  @doc false
  @spec normalize!(term(), mode(), String.t()) :: [t()]

  def normalize!(spec, :payload, where) when is_binary(where) do
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

  def normalize!(spec, mode, where) when mode in ~w(plugin dump_only labels struct)a and is_binary(where),
    do: spec_fields!(spec, mode, where)

  @doc false
  @spec variant_fields!(module(), term(), [atom()], String.t()) :: [t()]

  def variant_fields!(type, spec, skipped, where) when is_atom(type) and is_list(skipped),
    do: type_fields!(type, spec, skipped, :plugin, where)

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
      true -> kind_spec!(:entity, mod, where)
    end
  end

  @doc false
  @spec struct_fields(module()) :: [t()] | nil

  def struct_fields(module) when is_atom(module),
    do: if(Core.Helper.Module.exports?(module, :__struct_fields__, 0), do: module.__struct_fields__())

  @doc false
  @spec map_opts!(term(), String.t()) :: {keyword(), keyword()}

  def map_opts!(inner, where) when is_binary(where) do
    if not Keyword.keyword?(inner) or Enum.sort(Keyword.keys(inner)) != @map_keys do
      Helper.Opts.reject!(where, "map: ожидается [key: спека, value: спека], получено #{inspect(inner)}")
    end

    {Keyword.fetch!(inner, :key), Keyword.fetch!(inner, :value)}
  end

  # ---

  defp pair!({type, spec}) when is_atom(type) and not is_nil(type), do: {type, spec}

  defp pair!(other),
    do: Helper.Opts.reject!("#{@label}: fields", "ожидается пара {Тип, спека}, получено #{inspect(other)}")

  defp defaults(spec) do
    if Keyword.keyword?(spec),
      do: for({name, opts} <- spec, Keyword.keyword?(opts), Keyword.has_key?(opts, :default), do: name),
      else: []
  end

  defp type_fields!(type, spec, skipped, mode, where) do
    fields = spec_fields!(spec, mode, where)
    check_struct!(type, Keyword.keys(spec), skipped, where)
    check_struct_fields!(type, fields, where)

    fields
  end

  defp check_struct!(type, names, skipped, where) do
    struct_module!(type, where)

    struct_keys = Map.keys(type.__struct__()) -- (@skipped_keys ++ skipped)

    case {struct_keys -- names, names -- struct_keys} do
      {[], []} ->
        :ok

      {missing, extra} ->
        Helper.Opts.reject!(
          where,
          "спека расходится со struct — поля struct без спеки #{inspect(Enum.sort(missing))}, " <>
            "поля спеки без struct #{inspect(Enum.sort(extra))}"
        )
    end
  end

  # Структура по полям объявляет вид каждого поля сама (ADR-0090): ключей мало, иначе плагин
  # молча грузил бы в поле значение другого Prim или `nil` в поле без `optional: true`.
  defp check_struct_fields!(type, fields, where) do
    case struct_fields(type) do
      nil -> :ok
      declared -> check_shapes!(declared, fields, where)
    end
  end

  defp check_shapes!(declared, fields, where) do
    declared = Map.new(declared, fn %__MODULE__{name: name} = field -> {name, shape(field)} end)

    for %__MODULE__{name: name} = field <- fields,
        struct_shape = Map.fetch!(declared, name),
        plugin_shape = shape(field),
        struct_shape != plugin_shape do
      Helper.Opts.reject!(
        "#{where}: #{name}",
        "вид поля расходится со структурой — в структуре #{inspect(struct_shape)}, " <>
          "в плагине #{inspect(plugin_shape)}"
      )
    end

    :ok
  end

  defp shape(%__MODULE__{spec: spec, optional?: false}), do: spec_shape(spec)
  defp shape(%__MODULE__{spec: spec, optional?: true}), do: spec_shape(spec) ++ [optional: true]

  defp spec_shape({kind, inner}) when kind in @collection_kinds, do: [{kind, spec_shape(inner)}]
  defp spec_shape({:map, key, value}), do: [map: [key: spec_shape(key), value: spec_shape(value)]]
  defp spec_shape({kind, value}), do: [{kind, value}]

  defp spec_fields!(spec, mode, where) do
    if not Keyword.keyword?(spec) or spec == [] do
      Helper.Opts.reject!(where, "ожидается непустой keyword-список полей, получено #{inspect(spec)}")
    end

    FieldCheck.unique!(Keyword.keys(spec), where)
    fields = Enum.map(spec, fn {name, opts} -> field!(name, opts, mode, "#{where}: #{name}") end)
    FieldCheck.unique!(Enum.map(fields, fn %__MODULE__{wire: wire} -> wire end), "#{where}: wire")

    fields
  end

  defp field!(name, opts, mode, where) do
    if not Keyword.keyword?(opts) do
      Helper.Opts.reject!(where, "ожидается keyword-спека, получено #{inspect(opts)}")
    end

    if mode == :struct, do: check_struct_keys!(opts, where)

    case Keyword.keys(opts) -- (@kind_keys ++ @extra_keys ++ if(mode == :payload, do: [:subject], else: [])) do
      [] -> :ok
      unknown -> Helper.Opts.reject!(where, "неизвестные ключи #{inspect(unknown)}")
    end

    spec = spec!(opts, where)
    optional? = optional!(opts, where)

    %__MODULE__{
      name: name,
      spec: spec,
      optional?: optional?,
      wire: wire!(name, opts, where),
      default: default!(opts, spec, optional?, mode != :dump_only, where),
      subject: subject!(opts, where)
    }
  end

  defp check_struct_keys!(opts, where) do
    for {key, text} <- [
          wire: "wire: у структуры по полям нет wire — его задаёт Codec-плагин по полям",
          subject: "subject: у структуры по полям нет кодека — субъект ПДн задаёт нагрузка события"
        ],
        Keyword.has_key?(opts, key),
        do: Helper.Opts.reject!(where, text)

    :ok
  end

  defp spec!(opts, where) do
    case Keyword.take(opts, @kind_keys) do
      [{kind, value}] ->
        kind_spec!(kind, value, where)

      other ->
        Helper.Opts.reject!(
          where,
          "ожидается ровно один из #{Enum.map_join(@kind_keys, "/", &"#{&1}:")}, получено #{inspect(other)}"
        )
    end
  end

  defp kind_spec!(:prim, mod, where) do
    FieldCheck.prim!(mod, where)
    {:prim, mod}
  end

  defp kind_spec!(:enum, mod, where) do
    FieldCheck.enum!(mod, where)
    {:enum, mod}
  end

  defp kind_spec!(:entity, mod, where) do
    struct_module!(mod, where)
    {:entity, mod}
  end

  # Семейство struct не имеет: struct здесь — вариант или Prim, а модуль `Core.Enum` — enum, и поле
  # с ними работало бы на одном значении и молча ломалось на остальных.
  defp kind_spec!(:union, mod, where) do
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

  defp kind_spec!(kind, inner, where) when kind in @collection_kinds,
    do: {kind, element_spec!("#{kind}", "элемента", inner, where)}

  defp kind_spec!(:map, inner, where) do
    {key_opts, value_opts} = map_opts!(inner, where)
    key = element_spec!("map: key", "ключа", key_opts, where)
    check_map_key!(key, key_opts, where)

    {:map, key, element_spec!("map: value", "значения", value_opts, where)}
  end

  defp kind_spec!(:type, type, _where) when type in @type_values, do: {:type, type}

  defp kind_spec!(:type, type, where) do
    Helper.Opts.reject!(where, "неизвестный type: #{inspect(type)}, ожидается один из #{inspect(@type_values)}")
  end

  defp element_spec!(label, role, inner, where) do
    if not Keyword.keyword?(inner) do
      Helper.Opts.reject!(where, "#{label}: ожидается keyword-спека #{role}, получено #{inspect(inner)}")
    end

    if Keyword.has_key?(inner, :optional) do
      Helper.Opts.reject!(where, "optional: задаётся у самого поля, не в #{label}:")
    end

    case Keyword.keys(inner) -- @kind_keys do
      [] -> spec!(inner, where)
      unknown -> Helper.Opts.reject!(where, "#{label}: неизвестные ключи #{inspect(unknown)}")
    end
  end

  defp optional!(opts, where) do
    case Keyword.get(opts, :optional, false) do
      optional? when is_boolean(optional?) -> optional?
      other -> Helper.Opts.reject!(where, "optional: ожидается boolean, получено #{inspect(other)}")
    end
  end

  defp wire!(name, opts, where) do
    case Keyword.fetch(opts, :wire) do
      :error -> Atom.to_string(name)
      {:ok, wire} when is_binary(wire) and wire != "" -> wire
      {:ok, other} -> Helper.Opts.reject!(where, "wire: ожидается непустая строка, получено #{inspect(other)}")
    end
  end

  defp default!(opts, spec, optional?, loadable?, where) do
    case {Keyword.fetch(opts, :default), optional?, loadable?} do
      {:error, _optional?, _loadable?} ->
        :none

      {{:ok, _default}, true, _loadable?} ->
        Helper.Opts.reject!(where, "default: и optional: true — два ответа на один nil")

      {{:ok, _default}, false, false} ->
        Helper.Opts.reject!(where, "default: при loadable: false не применяется — загрузки нет")

      {{:ok, default}, false, true} ->
        check_default!(spec, default, where)
        {:default, default}
    end
  end

  defp subject!(opts, where) do
    case Keyword.fetch(opts, :subject) do
      :error ->
        nil

      {:ok, subject} when is_atom(subject) and subject not in ~w(nil true false)a ->
        subject

      {:ok, other} ->
        Helper.Opts.reject!(where, "subject: ожидается :aggregate_id или имя поля нагрузки, получено #{inspect(other)}")
    end
  end

  # Нагрузка события: wire-ключ на `$` совпал бы с зарезервированной формой `{"$pd": …}` (ADR-0073).
  defp check_payload_wires!(fields, where) do
    Enum.each(fields, fn %__MODULE__{name: name, wire: wire} -> check_wire!(wire, "#{where}: #{name}") end)

    fields
  end

  defp check_wire!("$" <> _rest = wire, where) do
    Helper.Opts.reject!(where, "wire-ключ #{inspect(wire)} начинается с $ — форма {\"$pd\": …} зарезервирована")
  end

  defp check_wire!(_wire, _where), do: :ok

  # Загрузку Prim и сущности без фасада не повторить, а `cast` enum — чистая функция модуля:
  # опечатка в `default:` всплыла бы только на строке, записанной до появления поля. У `set:` и
  # `map:` так же проверяются элементы, ключи и значения непустого литерала.
  defp check_default!(spec, default, where) when elem(spec, 0) in @checked_defaults,
    do: check_default_wire!(spec, default, where, "default")

  defp check_default!(_spec, _default, _where), do: :ok

  defp check_default_wire!({:enum, mod}, value, where, label) do
    case mod.cast(value) do
      {:ok, _value} -> :ok
      {:error, _reason} -> Helper.Opts.reject!(where, "#{label}: #{inspect(value)} не загружается #{inspect(mod)}")
    end
  end

  defp check_default_wire!({:type, type}, value, where, label) do
    if not FieldCheck.type_value?(type, value),
      do: Helper.Opts.reject!(where, "#{label}: ожидается #{type}, получено #{inspect(value)}")

    :ok
  end

  # `default:` плагина — wire, а не значение поля: `%MapSet{}` из структуры по полям загрузка не прочла бы.
  defp check_default_wire!({kind, _inner}, value, where, label) when kind in @collection_kinds and not is_list(value),
    do: Helper.Opts.reject!(where, "#{label}: у #{kind}: — wire-литерал списка, получено #{inspect(value)}")

  defp check_default_wire!({kind, inner}, values, where, label) when kind in @collection_kinds,
    do: Enum.each(values, &check_default_wire!(inner, &1, where, label))

  defp check_default_wire!({:map, _key, _value}, value, where, label) when not is_map(value) or is_struct(value),
    do: Helper.Opts.reject!(where, "#{label}: у map: — wire-литерал объекта, получено #{inspect(value)}")

  defp check_default_wire!({:map, key, inner}, values, where, label) do
    Enum.each(values, fn {wire_key, value} ->
      check_default_wire!(key_wire(key), wire_key, where, "#{label}: ключ")
      check_default_wire!(inner, value, where, label)
    end)
  end

  defp check_default_wire!(_spec, _value, _where, _label), do: :ok

  # Wire ключа — строка: у enum — строка значения, у Prim и `type: :string` — сама строка.
  defp key_wire({:enum, _mod} = key), do: key
  defp key_wire(_key), do: {:type, :string}

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

  # Спека другого режима (`Core.View`, `Core.Labels.Fields`) вкладывает спеки в той же форме:
  # `{:list, _}`, `{:set, _}`, `{:map, ключ, значение}`; остальные виды вложенных спек не держат.
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

  # ===== субъекты =====

  @doc "Поля нагрузки события с `subject:`: `[{поле, субъект}]` в порядке объявления."
  @spec subjects([t()]) :: [{atom(), atom()}]

  def subjects(fields) when is_list(fields),
    do: for(%__MODULE__{name: name, subject: subject} <- fields, not is_nil(subject), do: {name, subject})

  # ===== тип =====

  @doc false
  @spec typespec([t()]) :: keyword(Macro.t())

  def typespec(fields) do
    Enum.map(fields, fn
      %__MODULE__{name: name, spec: spec, optional?: false} -> {name, spec_type(spec)}
      %__MODULE__{name: name, spec: spec, optional?: true} -> {name, quote(do: unquote(spec_type(spec)) | nil)}
    end)
  end

  # ---

  defp spec_type({:union, _family}), do: quote(do: struct())
  defp spec_type({kind, mod}) when kind in ~w(prim enum entity)a, do: quote(do: unquote(mod).t())
  defp spec_type({:list, inner}), do: quote(do: [unquote(spec_type(inner))])
  defp spec_type({:set, inner}), do: quote(do: MapSet.t(unquote(spec_type(inner))))

  defp spec_type({:map, key, value}),
    do: quote(do: %{optional(unquote(spec_type(key))) => unquote(spec_type(value))})

  defp spec_type({:type, :string}), do: quote(do: String.t())
  defp spec_type({:type, scalar}), do: quote(do: unquote(scalar)())
end
