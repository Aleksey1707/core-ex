defmodule Core.Codec.Plugin.Fields do
  @moduledoc """
  Генерация клауз `dump/2` / `load/3` Codec-плагина по спеке полей (`use Core.Codec.Plugin, fields:`).

  Спеку нормализует `Core.Codec.Field`: поле объявляется keyword-спекой с ровно одним kind-ключом и
  необязательными `optional: true`, `wire: "ключ"` и `default:`. Ключи спеки сверяются с полями
  struct типа (без `__struct__` и `events`) — расхождение в любую сторону даёт `CompileError`.

  | Вид | Дамп | Загрузка |
  |---|---|---|
  | `prim: Prim` | `codec.dump/1` | `codec.load(Prim, raw)` |
  | `enum: Enum` | атом как есть | `Enum.cast/1` (`cast_optional/1` при `optional:`) |
  | `entity: Mod` | `codec.dump/1` | `codec.load(Mod, raw)` |
  | `union: Family` | `codec.dump/1` | `codec.load(Family, raw)` |
  | `list: спека` | поэлементно по спеке | поэлементно по спеке; не список — ошибка |
  | `set: спека` | список, отсортированный по wire | `MapSet` поэлементно; повторы схлопываются, не список — ошибка |
  | `map: [key: спека, value: спека]` | объект `{"<wire ключа>": <wire значения>}` | map по видам ключа и значения; не объект — ошибка |
  | `type: скаляр` | как есть | как есть |

  Множество (`set:`) даёт один wire на одно значение: порядок списка — порядок термов wire
  элементов, а не обход `MapSet` (ADR-0091). Ошибку элемента множества загрузка оборачивает
  ошибкой поля с `detail: %{field: поле, index: индекс элемента в wire}`.

  Словарь (`map:`) — соответствие ключа значению, у каждого свой вид; `type: :map` — map без спеки
  ключа и значения, загрузка отдаёт её как есть. Ключ словаря — вид с wire-строкой: Prim со
  строковой базой (`Prim.String`, `Prim.UUID`, `Prim.Compose` над ними), `enum:` (wire — строка
  значения) или `type: :string`; иное и Prim `personal: true` / `sensitive:` — `CompileError`
  (ADR-0091). Порядок ключей объекта не гарантируется. Ошибку ключа или значения загрузка
  оборачивает ошибкой поля с `detail: %{field: поле, key: wire-ключ}`.

  `default:` — wire-литерал, который загрузка подставляет вместо отсутствующего ключа или
  `nil` и грузит как записанный (у `set:` — `[]`, у `map:` — `%{}`). Голова `dump/2` закрывает
  Prim, сущность, множество (`%MapSet{}`) и словарь (`%{}`, не struct) поля паттерном, а
  вариант семейства (`union:`) — только `is_struct`: варианты знает плагин семейства, а не этот
  (ADR-0058). Загрузка собирает struct литералом после успешной загрузки
  всех полей; первая ошибка поля — итог, лишние ключи wire игнорируются.

  Нагрузка события (`Core.Es.Event.Payload`) говорит на той же спеке и собирает свои клаузы из
  поштучных блоков значения поля этого модуля.
  """

  alias Core.Codec.Field
  alias Core.Error
  alias Core.Result

  require Error

  @facade_kinds ~w(prim entity union)a
  @pattern_kinds ~w(prim entity)a
  @collection_kinds ~w(list set)a

  # ===== dump =====

  @doc false
  @spec dump_args(module(), [Field.t()]) :: [Macro.t()]

  def dump_args(type, fields) do
    pairs = Enum.map(fields, &dump_pattern/1)

    [quote(generated: true, do: %unquote(type){unquote_splicing(pairs)}), codec_var()]
  end

  @doc false
  @spec dump_guard([Field.t()]) :: Macro.t()

  def dump_guard(fields),
    do: and_guards([quote(generated: true, do: is_atom(unquote(codec_var()))) | field_guards(fields)])

  @doc false
  @spec dump_body([Field.t()]) :: Macro.t()

  def dump_body(fields), do: quote(generated: true, do: %{unquote_splicing(dump_pairs(fields))})

  @doc false
  @spec dump_pairs([Field.t()]) :: [{String.t(), Macro.t()}]

  def dump_pairs(fields),
    do:
      Enum.map(fields, fn %Field{name: name, spec: spec, optional?: optional?, wire: wire} ->
        {wire, dump_value(spec, var(name), optional?)}
      end)

  @doc false
  @spec new_args([Field.t()]) :: [Macro.t()]

  def new_args(fields), do: Enum.map(fields, &elem(dump_pattern(&1), 1))

  @doc false
  @spec new_guard([Field.t()]) :: Macro.t()

  def new_guard(fields), do: and_guards(field_guards(fields))

  @doc false
  @spec new_body(module(), [Field.t()]) :: Macro.t()

  def new_body(type, fields) do
    pairs = Enum.map(fields, fn %Field{name: name} -> {name, var(name)} end)

    quote(generated: true, do: %unquote(type){unquote_splicing(pairs)})
  end

  # ---

  defp field_guards(fields), do: Enum.flat_map(fields, &field_guard/1)

  # ===== блоки дампа значения поля =====

  @doc false
  @spec and_guards([Macro.t()]) :: Macro.t()

  def and_guards([]), do: true

  def and_guards([first | rest]) do
    Enum.reduce(rest, first, fn guard, acc -> quote(generated: true, do: unquote(acc) and unquote(guard)) end)
  end

  @doc false
  @spec dump_pattern(Field.t()) :: {atom(), Macro.t()}

  def dump_pattern(%Field{name: name, spec: {kind, mod}, optional?: false}) when kind in @pattern_kinds,
    do: {name, quote(generated: true, do: %unquote(mod){} = unquote(var(name)))}

  def dump_pattern(%Field{name: name, spec: {:set, _inner}, optional?: false}),
    do: {name, quote(generated: true, do: %MapSet{} = unquote(var(name)))}

  def dump_pattern(%Field{name: name, spec: {:map, _key, _value}, optional?: false}),
    do: {name, quote(generated: true, do: %{} = unquote(var(name)))}

  def dump_pattern(%Field{name: name}), do: {name, var(name)}

  @doc false
  @spec field_guard(Field.t()) :: [Macro.t()]

  def field_guard(%Field{spec: {kind, _mod}, optional?: false}) when kind in @pattern_kinds, do: []
  def field_guard(%Field{spec: {:set, _inner}, optional?: false}), do: []

  def field_guard(%Field{name: name, spec: {:map, _key, _value}, optional?: false}),
    do: [quote(generated: true, do: not is_struct(unquote(var(name))))]

  def field_guard(%Field{name: name, spec: spec, optional?: false}), do: [value_guard(spec, var(name))]

  def field_guard(%Field{name: name, spec: spec, optional?: true}) do
    value = var(name)

    [quote(generated: true, do: is_nil(unquote(value)) or unquote(value_guard(spec, value)))]
  end

  @doc false
  @spec value_guard(Field.spec(), Macro.t()) :: Macro.t()

  def value_guard({kind, mod}, value) when kind in @pattern_kinds,
    do: quote(generated: true, do: is_struct(unquote(value), unquote(mod)))

  def value_guard({:union, _family}, value), do: quote(generated: true, do: is_struct(unquote(value)))

  def value_guard({:enum, _mod}, value),
    do: quote(generated: true, do: is_atom(unquote(value)) and not is_nil(unquote(value)))

  def value_guard({:list, _inner}, value), do: quote(generated: true, do: is_list(unquote(value)))
  def value_guard({:set, _inner}, value), do: quote(generated: true, do: is_struct(unquote(value), MapSet))

  def value_guard({:map, _key, _value}, value),
    do: quote(generated: true, do: is_map(unquote(value)) and not is_struct(unquote(value)))

  def value_guard({:type, :string}, value), do: quote(generated: true, do: is_binary(unquote(value)))
  def value_guard({:type, :boolean}, value), do: quote(generated: true, do: is_boolean(unquote(value)))
  def value_guard({:type, :integer}, value), do: quote(generated: true, do: is_integer(unquote(value)))
  def value_guard({:type, :map}, value), do: quote(generated: true, do: is_map(unquote(value)))

  def value_guard({:type, :pos_integer}, value),
    do: quote(generated: true, do: is_integer(unquote(value)) and unquote(value) > 0)

  def value_guard({:type, :non_neg_integer}, value),
    do: quote(generated: true, do: is_integer(unquote(value)) and unquote(value) >= 0)

  @doc false
  @spec dump_value(Field.spec(), Macro.t(), boolean()) :: Macro.t()

  def dump_value(spec, value, optional?) do
    cond do
      as_is?(spec) ->
        value

      optional? ->
        quote(generated: true, do: if(is_nil(unquote(value)), do: nil, else: unquote(dump_expr(spec, value))))

      true ->
        dump_expr(spec, value)
    end
  end

  # ---

  defp dump_expr({kind, _mod}, value) when kind in @facade_kinds,
    do: quote(generated: true, do: unquote(codec_var()).dump(unquote(value)))

  defp dump_expr({:list, inner}, value) do
    item = item_var()

    quote(
      generated: true,
      do: Enum.map(unquote(value), fn unquote(item) -> unquote(dump_value(inner, item, false)) end)
    )
  end

  # Порядок обхода `MapSet` зависит от числа элементов и не совпадает с порядком их wire: одно
  # значение давало бы разный список (ADR-0091).
  defp dump_expr({:set, inner}, value),
    do: quote(generated: true, do: Enum.sort(unquote(dump_expr({:list, inner}, value))))

  defp dump_expr({:map, key, inner}, value) do
    key_item = key_var()
    item = item_var()

    quote generated: true do
      Map.new(unquote(value), fn {unquote(key_item), unquote(item)} ->
        {unquote(dump_key(key, key_item)), unquote(dump_value(inner, item, false))}
      end)
    end
  end

  # Ключ объекта — строка: атом enum `Jason` записал бы строкой только при кодировании.
  defp dump_key({:enum, _mod}, key), do: quote(generated: true, do: Atom.to_string(unquote(key)))
  defp dump_key(spec, key), do: dump_value(spec, key, false)

  defp as_is?({kind, _}) when kind in ~w(enum type)a, do: true
  defp as_is?({:list, inner}), do: as_is?(inner)
  defp as_is?({:set, _inner}), do: false
  defp as_is?({:map, _key, _value}), do: false
  defp as_is?({_kind, _mod}), do: false

  # ===== load =====

  @doc false
  @spec load_args(module()) :: [Macro.t()]

  def load_args(type), do: [type, wire_var(), codec_var()]

  @doc false
  @spec load_guard() :: Macro.t()

  def load_guard, do: quote(generated: true, do: is_map(unquote(wire_var())) and is_atom(unquote(codec_var())))

  @doc false
  @spec load_body(module(), [Field.t()]) :: Macro.t()

  def load_body(type, fields) do
    steps = Enum.map(fields, &load_step(type, &1))
    pairs = Enum.map(fields, fn %Field{name: name} -> {name, var(name)} end)

    ok = quote(generated: true, do: {:ok, %unquote(type){unquote_splicing(pairs)}})
    error = quote(generated: true, do: ({:error, reason} -> {:error, reason}))

    {:with, [generated: true], steps ++ [[do: ok, else: error]]}
  end

  # ---

  defp load_step(type, %Field{name: name, spec: spec, optional?: optional?, wire: wire, default: default}) do
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

  # ===== блок загрузки значения поля =====

  @doc false
  @spec load_value(module(), atom(), Field.spec(), Macro.t(), boolean()) :: Macro.t()

  def load_value(_type, _name, {:type, _scalar}, raw, _optional?), do: quote(generated: true, do: {:ok, unquote(raw)})

  def load_value(_type, _name, {kind, mod}, raw, true) when kind in @facade_kinds,
    do: quote(generated: true, do: Core.Codec.Helper.load_optional(unquote(mod), unquote(raw), unquote(codec_var())))

  def load_value(_type, _name, {:enum, mod}, raw, true),
    do: quote(generated: true, do: unquote(mod).cast_optional(unquote(raw)))

  def load_value(type, name, spec, raw, true) do
    quote generated: true do
      case unquote(raw) do
        nil -> {:ok, nil}
        raw -> unquote(load_value(type, name, spec, quote(generated: true, do: raw), false))
      end
    end
  end

  def load_value(_type, _name, {kind, mod}, raw, false) when kind in @facade_kinds,
    do: quote(generated: true, do: unquote(codec_var()).load(unquote(mod), unquote(raw)))

  def load_value(_type, _name, {:enum, mod}, raw, false),
    do: quote(generated: true, do: unquote(mod).cast(unquote(raw)))

  def load_value(type, name, {kind, inner}, raw, false) when kind in @collection_kinds do
    item = item_var()

    quote generated: true do
      Core.Codec.Plugin.Fields.unquote(loader(kind))(unquote(type), unquote(name), unquote(raw), fn unquote(item) ->
        unquote(load_value(type, name, inner, item, false))
      end)
    end
  end

  def load_value(type, name, {:map, key, inner}, raw, false) do
    key_item = key_var()
    item = item_var()

    quote generated: true do
      Core.Codec.Plugin.Fields.load_map(
        unquote(type),
        unquote(name),
        unquote(raw),
        fn unquote(key_item) -> unquote(load_value(type, name, key, key_item, false)) end,
        fn unquote(item) -> unquote(load_value(type, name, inner, item, false)) end
      )
    end
  end

  # ---

  defp loader(:list), do: :load_list
  defp loader(:set), do: :load_set

  # ===== wire-ключ =====

  # `field/2` читает и атомарный, и строковый ключ, но принимает атом: wire-ключ — литерал
  # спеки в коде плагина, а не внешние данные, и таблицу атомов не засоряет.
  @doc false
  @spec wire_key(String.t()) :: atom()

  # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
  def wire_key(wire) when is_binary(wire), do: String.to_atom(wire)

  # ===== загрузка списка =====

  @doc false
  @spec load_list(module(), atom(), term(), (term() -> Result.t())) :: Result.t([term()])

  def load_list(_type, _name, raw, fun) when is_list(raw) and is_function(fun, 1), do: Result.traverse(raw, fun)

  def load_list(type, name, _raw, _fun) when is_atom(type) and is_atom(name) do
    {:error,
     Error.domain(type,
       code: :invalid_value,
       ns: :codec,
       message: "#{inspect(type)}: поле #{name} — ожидается список"
     )}
  end

  # ===== загрузка множества =====

  @doc false
  @spec load_set(module(), atom(), term(), (term() -> Result.t())) :: Result.t(MapSet.t())

  def load_set(type, name, raw, fun) when is_list(raw) and is_function(fun, 1) do
    raw
    |> Enum.with_index()
    |> Result.traverse(fn {item, index} ->
      Result.map_error(fun.(item), &item_error(type, name, {:index, index}, "элемент", &1))
    end)
    |> Result.map(&MapSet.new/1)
  end

  def load_set(type, name, _raw, _fun) when is_atom(type) and is_atom(name) do
    {:error,
     Error.domain(type,
       code: :invalid_value,
       ns: :codec,
       message: "#{inspect(type)}: поле #{name} — ожидается список элементов множества",
       detail: %{field: name}
     )}
  end

  # ===== загрузка словаря =====

  @doc false
  @spec load_map(module(), atom(), term(), (term() -> Result.t()), (term() -> Result.t())) :: Result.t(map())

  def load_map(type, name, raw, key_fun, value_fun)
      when is_map(raw) and not is_struct(raw) and is_function(key_fun, 1) and is_function(value_fun, 1) do
    raw
    |> Map.to_list()
    |> Result.traverse(fn {key, value} ->
      with {:ok, loaded} <- Result.map_error(key_fun.(key), &item_error(type, name, {:key, key}, "ключ", &1)),
           {:ok, item} <- Result.map_error(value_fun.(value), &item_error(type, name, {:key, key}, "значение", &1)),
           do: {:ok, {loaded, item}}
    end)
    |> Result.map(&Map.new/1)
  end

  def load_map(type, name, _raw, _key_fun, _value_fun) when is_atom(type) and is_atom(name) do
    {:error,
     Error.domain(type,
       code: :invalid_value,
       ns: :codec,
       message: "#{inspect(type)}: поле #{name} — ожидается объект словаря",
       detail: %{field: name}
     )}
  end

  # ===== переменные =====

  # Поля — в своём контексте: поле с именем `codec` или `wire` не перекрывает аргумент функции.
  @doc false
  @spec var(atom()) :: Macro.t()

  def var(name) when is_atom(name), do: Macro.var(name, Core.Codec.Plugin.Fields.Value)

  @doc false
  @spec codec_var() :: Macro.t()

  def codec_var, do: Macro.var(:codec, __MODULE__)

  @doc false
  @spec wire_var() :: Macro.t()

  def wire_var, do: Macro.var(:wire, __MODULE__)

  # ===== общее =====

  defp item_var, do: Macro.var(:item, __MODULE__)
  defp key_var, do: Macro.var(:key, __MODULE__)

  # Путь — место в wire: индекс элемента множества (у `MapSet` порядка нет) или wire-ключ словаря.
  defp item_error(type, name, {segment, at}, what, %Error{} = reason) do
    Error.domain(type,
      code: :invalid_value,
      ns: :codec,
      message: "#{inspect(type)}: поле #{name}[#{inspect(at)}] — #{what} не загружается",
      detail: %{:field => name, segment => at},
      parent: reason
    )
  end
end
