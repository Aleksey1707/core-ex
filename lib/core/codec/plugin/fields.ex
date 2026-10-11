defmodule Core.Codec.Plugin.Fields do
  @moduledoc """
  Спека полей Codec-плагина (`use Core.Codec.Plugin, fields:`): валидация и генерация
  клауз `dump/2` / `load/3` по ней.

  Поле объявляется keyword-спекой с ровно одним kind-ключом и необязательными
  `optional: true`, `wire: "ключ"` и `default:`. Ключи спеки сверяются с полями struct типа
  (без `__struct__` и `events`) — расхождение в любую сторону даёт `CompileError`.

  | Вид | Дамп | Загрузка |
  |---|---|---|
  | `prim: Prim` | `codec.dump/1` | `codec.load(Prim, raw)` |
  | `enum: Enum` | атом как есть | `Enum.cast/1` (`cast_optional/1` при `optional:`) |
  | `entity: Mod` | `codec.dump/1` | `codec.load(Mod, raw)` |
  | `union: Family` | `codec.dump/1` | `codec.load(Family, raw)` |
  | `list: спека` | поэлементно по спеке | поэлементно по спеке; не список — ошибка |
  | `type: скаляр` | как есть | как есть |

  `default:` — wire-литерал, который загрузка подставляет вместо отсутствующего ключа или
  `nil` и грузит как записанный. Голова `dump/2` закрывает Prim и сущность поля паттерном, а
  вариант семейства (`union:`) — только `is_struct`: варианты знает плагин семейства, а не этот
  (ADR-0058). Загрузка собирает struct литералом после успешной загрузки
  всех полей; первая ошибка поля — итог, лишние ключи wire игнорируются.
  """

  alias Core.Error
  alias Core.Helper.FieldCheck
  alias Core.Prim
  alias Core.Result

  require Error

  @label "Codec.Plugin"
  @kind_keys ~w(prim enum entity union list type)a
  @extra_keys ~w(optional wire default)a
  @skipped_keys ~w(__struct__ events)a
  @facade_kinds ~w(prim entity union)a
  @pattern_kinds ~w(prim entity)a
  @type_values FieldCheck.type_values()

  @typedoc "Нормализованная спека значения поля."
  @type spec ::
          {:prim, module()}
          | {:enum, module()}
          | {:entity, module()}
          | {:union, module()}
          | {:list, spec()}
          | {:type, atom()}

  @typedoc "Значение `default:`: нет или wire-литерал."
  @type default :: :none | {:default, term()}

  @typedoc "Нормализованное поле: имя, спека значения, признак необязательности, wire-ключ, `default:`."
  @type field :: {atom(), spec(), boolean(), String.t(), default()}

  # ===== спека =====

  @doc false
  @spec fields!(module(), term(), boolean()) :: [{module(), [field()]}]

  def fields!(_plugin, nil, _loadable?), do: []

  def fields!(plugin, fields, loadable?) when is_list(fields) do
    pairs = Enum.map(fields, &pair!(plugin, &1))
    check_unique!(Enum.map(pairs, &elem(&1, 0)), "#{@label} #{inspect(plugin)}: fields: — типы объявлены дважды")

    Enum.map(pairs, fn {type, spec} ->
      {type, type_fields!(type, spec, [], loadable?, "#{@label} #{inspect(plugin)}: fields:, тип #{inspect(type)}")}
    end)
  end

  def fields!(plugin, other, _loadable?) do
    raise CompileError,
      description: "#{@label} #{inspect(plugin)}: fields: — список пар {Тип, спека}, задано #{inspect(other)}"
  end

  @doc false
  @spec payload_fields!(module(), term()) :: [field()]

  def payload_fields!(payload, spec) when is_atom(payload) do
    where = "Es.Event.Payload #{inspect(payload)}: fields:"

    case defaults(spec) do
      [] ->
        spec_fields!(spec, true, where)

      names ->
        raise CompileError,
          description:
            "#{where} — default: у нагрузки события нет (поля #{inspect(names)}): " <>
              "развитие события — новый тег и апкаст"
    end
  end

  @doc false
  @spec variant_fields!(module(), term(), [atom()], String.t()) :: [field()]

  def variant_fields!(type, spec, skipped, where) when is_atom(type) and is_list(skipped),
    do: type_fields!(type, spec, skipped, true, where)

  @doc false
  @spec struct_module!(module(), String.t()) :: :ok

  def struct_module!(mod, where) do
    FieldCheck.module!(mod, where)

    if not function_exported?(mod, :__struct__, 0) do
      raise CompileError, description: "#{where}: #{inspect(mod)} не struct"
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

  # ---

  defp pair!(_plugin, {type, spec}) when is_atom(type) and not is_nil(type), do: {type, spec}

  defp pair!(plugin, other) do
    raise CompileError,
      description: "#{@label} #{inspect(plugin)}: fields: — ожидается пара {Тип, спека}, задано #{inspect(other)}"
  end

  defp defaults(spec) do
    if Keyword.keyword?(spec),
      do: for({name, opts} <- spec, Keyword.keyword?(opts), Keyword.has_key?(opts, :default), do: name),
      else: []
  end

  defp type_fields!(type, spec, skipped, loadable?, where) do
    fields = spec_fields!(spec, loadable?, where)
    check_struct!(type, Keyword.keys(spec), skipped, where)

    fields
  end

  defp spec_fields!(spec, loadable?, where) do
    if not Keyword.keyword?(spec) or spec == [] do
      raise CompileError, description: "#{where} — непустой keyword-список полей"
    end

    check_unique!(Keyword.keys(spec), "#{where}: поля повторяются")
    fields = Enum.map(spec, fn {name, opts} -> field!(name, opts, loadable?, "#{where}, поле #{name}") end)
    check_unique!(Enum.map(fields, &elem(&1, 3)), "#{where}: wire-ключи повторяются")

    fields
  end

  defp field!(name, opts, loadable?, where) do
    if not Keyword.keyword?(opts) do
      raise CompileError, description: "#{where} — keyword-спека"
    end

    case Keyword.keys(opts) -- (@kind_keys ++ @extra_keys) do
      [] -> :ok
      unknown -> raise CompileError, description: "#{where}: неизвестные ключи #{inspect(unknown)}"
    end

    spec = spec!(opts, where)
    optional? = optional!(opts, where)

    {name, spec, optional?, wire!(name, opts, where), default!(opts, spec, optional?, loadable?, where)}
  end

  defp spec!(opts, where) do
    case Keyword.take(opts, @kind_keys) do
      [{kind, value}] ->
        kind_spec!(kind, value, where)

      other ->
        raise CompileError,
          description:
            "#{where}: нужен ровно один из #{Enum.map_join(@kind_keys, "/", &"#{&1}:")}, задано #{inspect(other)}"
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
      function_exported?(mod, :__struct__, 0) ->
        raise CompileError,
          description: "#{where}: union: #{inspect(mod)} — struct, а не семейство; нужен entity: или prim:"

      Core.Enum.enum?(mod) ->
        raise CompileError, description: "#{where}: union: #{inspect(mod)} — Core.Enum, а не семейство; нужен enum:"

      true ->
        {:union, mod}
    end
  end

  defp kind_spec!(:list, inner, where) do
    if not Keyword.keyword?(inner) do
      raise CompileError, description: "#{where}: list: — keyword-спека элемента"
    end

    if Keyword.has_key?(inner, :optional) do
      raise CompileError, description: "#{where}: optional: задаётся у самого поля, не в list:"
    end

    case Keyword.keys(inner) -- @kind_keys do
      [] -> {:list, spec!(inner, where)}
      unknown -> raise CompileError, description: "#{where}: list: — неизвестные ключи #{inspect(unknown)}"
    end
  end

  defp kind_spec!(:type, type, _where) when type in @type_values, do: {:type, type}

  defp kind_spec!(:type, type, where) do
    raise CompileError,
      description: "#{where}: неизвестный type: #{inspect(type)}, ожидается один из #{inspect(@type_values)}"
  end

  defp optional!(opts, where) do
    case Keyword.get(opts, :optional, false) do
      optional? when is_boolean(optional?) -> optional?
      other -> raise CompileError, description: "#{where}: optional: — boolean, задано #{inspect(other)}"
    end
  end

  defp wire!(name, opts, where) do
    case Keyword.fetch(opts, :wire) do
      :error -> Atom.to_string(name)
      {:ok, wire} when is_binary(wire) and wire != "" -> wire
      {:ok, other} -> raise CompileError, description: "#{where}: wire: — непустая строка, задано #{inspect(other)}"
    end
  end

  defp default!(opts, spec, optional?, loadable?, where) do
    case {Keyword.fetch(opts, :default), optional?, loadable?} do
      {:error, _optional?, _loadable?} ->
        :none

      {{:ok, _default}, true, _loadable?} ->
        raise CompileError, description: "#{where}: default: и optional: true — два ответа на один nil"

      {{:ok, _default}, false, false} ->
        raise CompileError, description: "#{where}: default: при loadable: false не применяется — загрузки нет"

      {{:ok, default}, false, true} ->
        check_default!(spec, default, where)
        {:default, default}
    end
  end

  # Загрузку Prim и сущности без фасада не повторить, а `cast` enum — чистая функция модуля:
  # опечатка в `default:` всплыла бы только на строке, записанной до появления поля.
  defp check_default!({:enum, mod}, default, where) do
    case mod.cast(default) do
      {:ok, _value} ->
        :ok

      {:error, _reason} ->
        raise CompileError, description: "#{where}: default: #{inspect(default)} не загружается #{inspect(mod)}"
    end
  end

  defp check_default!(_spec, _default, _where), do: :ok

  defp check_struct!(type, names, skipped, where) do
    struct_module!(type, where)

    struct_keys = Map.keys(type.__struct__()) -- (@skipped_keys ++ skipped)

    case {struct_keys -- names, names -- struct_keys} do
      {[], []} ->
        :ok

      {missing, extra} ->
        raise CompileError,
          description:
            "#{where}: спека расходится со struct — поля struct без спеки #{inspect(Enum.sort(missing))}, " <>
              "поля спеки без struct #{inspect(Enum.sort(extra))}"
    end
  end

  defp check_unique!(items, message) do
    case items -- Enum.uniq(items) do
      [] -> :ok
      dupes -> raise CompileError, description: "#{message}: #{inspect(Enum.uniq(dupes))}"
    end
  end

  # ===== dump =====

  @doc false
  @spec dump_args(module(), [field()]) :: [Macro.t()]

  def dump_args(type, fields) do
    pairs = Enum.map(fields, &dump_pattern/1)

    [quote(generated: true, do: %unquote(type){unquote_splicing(pairs)}), codec_var()]
  end

  @doc false
  @spec dump_guard([field()]) :: Macro.t()

  def dump_guard(fields),
    do: and_guards([quote(generated: true, do: is_atom(unquote(codec_var()))) | field_guards(fields)])

  @doc false
  @spec dump_body([field()]) :: Macro.t()

  def dump_body(fields), do: quote(generated: true, do: %{unquote_splicing(dump_pairs(fields))})

  @doc false
  @spec dump_pairs([field()]) :: [{String.t(), Macro.t()}]

  def dump_pairs(fields),
    do:
      Enum.map(fields, fn {name, spec, optional?, wire, _default} -> {wire, dump_value(spec, var(name), optional?)} end)

  @doc false
  @spec new_args([field()]) :: [Macro.t()]

  def new_args(fields), do: Enum.map(fields, &elem(dump_pattern(&1), 1))

  @doc false
  @spec new_guard([field()]) :: Macro.t()

  def new_guard(fields) do
    case field_guards(fields) do
      [] -> true
      guards -> and_guards(guards)
    end
  end

  @doc false
  @spec new_body(module(), [field()]) :: Macro.t()

  def new_body(type, fields) do
    pairs = Enum.map(fields, fn {name, _spec, _optional?, _wire, _default} -> {name, var(name)} end)

    quote(generated: true, do: %unquote(type){unquote_splicing(pairs)})
  end

  # ---

  defp field_guards(fields), do: Enum.flat_map(fields, &field_guard/1)

  defp and_guards([first | rest]) do
    Enum.reduce(rest, first, fn guard, acc -> quote(generated: true, do: unquote(acc) and unquote(guard)) end)
  end

  defp dump_pattern({name, {kind, mod}, false, _wire, _default}) when kind in @pattern_kinds,
    do: {name, quote(generated: true, do: %unquote(mod){} = unquote(var(name)))}

  defp dump_pattern({name, _spec, _optional?, _wire, _default}), do: {name, var(name)}

  defp field_guard({_name, {kind, _mod}, false, _wire, _default}) when kind in @pattern_kinds, do: []

  defp field_guard({name, spec, false, _wire, _default}), do: [value_guard(spec, var(name))]

  defp field_guard({name, spec, true, _wire, _default}) do
    value = var(name)

    [quote(generated: true, do: is_nil(unquote(value)) or unquote(value_guard(spec, value)))]
  end

  defp value_guard({kind, mod}, value) when kind in @pattern_kinds,
    do: quote(generated: true, do: is_struct(unquote(value), unquote(mod)))

  defp value_guard({:union, _family}, value), do: quote(generated: true, do: is_struct(unquote(value)))

  defp value_guard({:enum, _mod}, value),
    do: quote(generated: true, do: is_atom(unquote(value)) and not is_nil(unquote(value)))

  defp value_guard({:list, _inner}, value), do: quote(generated: true, do: is_list(unquote(value)))
  defp value_guard({:type, :string}, value), do: quote(generated: true, do: is_binary(unquote(value)))
  defp value_guard({:type, :boolean}, value), do: quote(generated: true, do: is_boolean(unquote(value)))
  defp value_guard({:type, :integer}, value), do: quote(generated: true, do: is_integer(unquote(value)))
  defp value_guard({:type, :map}, value), do: quote(generated: true, do: is_map(unquote(value)))

  defp value_guard({:type, :pos_integer}, value),
    do: quote(generated: true, do: is_integer(unquote(value)) and unquote(value) > 0)

  defp value_guard({:type, :non_neg_integer}, value),
    do: quote(generated: true, do: is_integer(unquote(value)) and unquote(value) >= 0)

  defp dump_value(spec, value, optional?) do
    cond do
      as_is?(spec) ->
        value

      optional? ->
        quote(generated: true, do: if(is_nil(unquote(value)), do: nil, else: unquote(dump_expr(spec, value))))

      true ->
        dump_expr(spec, value)
    end
  end

  defp dump_expr({kind, _mod}, value) when kind in @facade_kinds,
    do: quote(generated: true, do: unquote(codec_var()).dump(unquote(value)))

  defp dump_expr({:list, inner}, value) do
    item = item_var()

    quote(
      generated: true,
      do: Enum.map(unquote(value), fn unquote(item) -> unquote(dump_value(inner, item, false)) end)
    )
  end

  defp as_is?({kind, _}) when kind in ~w(enum type)a, do: true
  defp as_is?({:list, inner}), do: as_is?(inner)
  defp as_is?({_kind, _mod}), do: false

  # ===== тип =====

  @doc false
  @spec typespec([field()]) :: keyword(Macro.t())

  def typespec(fields) do
    Enum.map(fields, fn
      {name, spec, false, _wire, _default} -> {name, spec_type(spec)}
      {name, spec, true, _wire, _default} -> {name, quote(do: unquote(spec_type(spec)) | nil)}
    end)
  end

  # ---

  defp spec_type({:union, _family}), do: quote(do: struct())
  defp spec_type({kind, mod}) when kind in ~w(prim enum entity)a, do: quote(do: unquote(mod).t())
  defp spec_type({:list, inner}), do: quote(do: [unquote(spec_type(inner))])
  defp spec_type({:type, :string}), do: quote(do: String.t())
  defp spec_type({:type, scalar}), do: quote(do: unquote(scalar)())

  # ===== load =====

  @doc false
  @spec load_args(module()) :: [Macro.t()]

  def load_args(type), do: [type, wire_var(), codec_var()]

  @doc false
  @spec load_guard() :: Macro.t()

  def load_guard, do: quote(generated: true, do: is_map(unquote(wire_var())) and is_atom(unquote(codec_var())))

  @doc false
  @spec load_body(module(), [field()]) :: Macro.t()

  def load_body(type, fields) do
    steps = Enum.map(fields, &load_step(type, &1))
    pairs = Enum.map(fields, fn {name, _spec, _optional?, _wire, _default} -> {name, var(name)} end)

    ok = quote(generated: true, do: {:ok, %unquote(type){unquote_splicing(pairs)}})
    error = quote(generated: true, do: ({:error, reason} -> {:error, reason}))

    {:with, [generated: true], steps ++ [[do: ok, else: error]]}
  end

  # ---

  defp load_step(type, {name, spec, optional?, wire, default}) do
    raw =
      with_default(
        quote(generated: true, do: Core.Helper.Map.field(unquote(wire_var()), unquote(wire_key(wire)))),
        default
      )

    quote(generated: true, do: {:ok, unquote(var(name))} <- unquote(load_value(type, name, spec, raw, optional?)))
  end

  defp with_default(raw, :none), do: raw

  defp with_default(raw, {:default, default}) do
    quote generated: true do
      case unquote(raw) do
        nil -> unquote(Macro.escape(default))
        raw -> raw
      end
    end
  end

  defp load_value(_type, _name, {:type, _scalar}, raw, _optional?), do: quote(generated: true, do: {:ok, unquote(raw)})

  defp load_value(_type, _name, {kind, mod}, raw, true) when kind in @facade_kinds,
    do: quote(generated: true, do: Core.Codec.Helper.load_optional(unquote(mod), unquote(raw), unquote(codec_var())))

  defp load_value(_type, _name, {:enum, mod}, raw, true),
    do: quote(generated: true, do: unquote(mod).cast_optional(unquote(raw)))

  defp load_value(type, name, spec, raw, true) do
    quote generated: true do
      case unquote(raw) do
        nil -> {:ok, nil}
        raw -> unquote(load_value(type, name, spec, quote(generated: true, do: raw), false))
      end
    end
  end

  defp load_value(_type, _name, {kind, mod}, raw, false) when kind in @facade_kinds,
    do: quote(generated: true, do: unquote(codec_var()).load(unquote(mod), unquote(raw)))

  defp load_value(_type, _name, {:enum, mod}, raw, false),
    do: quote(generated: true, do: unquote(mod).cast(unquote(raw)))

  defp load_value(type, name, {:list, inner}, raw, false) do
    item = item_var()

    quote generated: true do
      Core.Codec.Plugin.Fields.load_list(unquote(type), unquote(name), unquote(raw), fn unquote(item) ->
        unquote(load_value(type, name, inner, item, false))
      end)
    end
  end

  defp wire_var, do: Macro.var(:wire, __MODULE__)

  # ===== wire-ключ =====

  # `field/2` читает и атомарный, и строковый ключ, но принимает атом: wire-ключ — литерал
  # спеки в коде плагина, а не внешние данные, и таблицу атомов не засоряет.
  @doc false
  @spec wire_key(String.t()) :: atom()

  # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
  def wire_key(wire) when is_binary(wire), do: String.to_atom(wire)

  # ===== загрузка списка =====

  @doc false
  @spec load_list(module(), atom(), term(), (term() -> Result.t(term()))) :: Result.t([term()])

  def load_list(_type, _name, raw, fun) when is_list(raw) and is_function(fun, 1), do: Result.traverse(raw, fun)

  def load_list(type, name, _raw, _fun) when is_atom(type) and is_atom(name) do
    {:error,
     Error.domain(type,
       code: :invalid_value,
       ns: :codec,
       message: "#{inspect(type)}: поле #{name} — ожидается список"
     )}
  end

  # ===== общее =====

  # Поля — в своём контексте: поле с именем `codec` или `wire` не перекрывает аргумент функции.
  defp var(name), do: Macro.var(name, Core.Codec.Plugin.Fields.Value)

  defp codec_var, do: Macro.var(:codec, __MODULE__)

  defp item_var, do: Macro.var(:item, __MODULE__)
end
