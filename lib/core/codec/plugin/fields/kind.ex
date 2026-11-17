defmodule Core.Codec.Plugin.Fields.Kind do
  @moduledoc false

  # Адаптер вида поля: одна строка таблицы на вид — операции плагина по полям (шаблон
  # сопоставления, guard, дамп, загрузка), признак «guard вида пропускает любой struct» и
  # признак «дамп не обходит значение»: `true` — значение уходит как есть, `:nested` — как
  # есть, если и элемент тоже, `false` — обход. Полнота сверяется с allowlist плагина из
  # `Core.Field.Spec` на сборке: вид без строки или без операции — `CompileError`.
  #
  # Вид приходит из общего IR (`Core.Field`); метаданные места ПДн (`{:personal, вид}`) —
  # свойство нагрузки события, а не wire-формы, и снимаются до операции.

  alias Core.Codec.Helper
  alias Core.Error
  alias Core.Result

  require Error

  @label "Codec.Plugin"
  @operations ~w(pattern guard struct dump load as_is)a

  @adapters %{
    prim: %{pattern: :struct, guard: :struct, struct: :never, dump: :codec, load: :codec, as_is: false},
    enum: %{pattern: :value, guard: :atom, struct: :never, dump: :as_is, load: :enum, as_is: true},
    entity: %{pattern: :struct, guard: :struct, struct: :never, dump: :codec, load: :codec, as_is: false},
    union: %{pattern: :value, guard: :struct_any, struct: :any, dump: :codec, load: :codec, as_is: false},
    list: %{pattern: :value, guard: :list, struct: :never, dump: :list, load: :list, as_is: :nested},
    set: %{pattern: :map_set, guard: :map_set, struct: :never, dump: :set, load: :set, as_is: false},
    map: %{pattern: :map, guard: :map, struct: :never, dump: :map, load: :map, as_is: false},
    type: %{pattern: :value, guard: :type, struct: :map_type, dump: :as_is, load: :as_is, as_is: true}
  }

  for kind <- Core.Field.Spec.kinds(:plugin) do
    row = Map.get(@adapters, kind)

    unless is_map(row) and Enum.all?(@operations, &is_atom(Map.get(row, &1))) and
             Map.get(row, :as_is) in [true, false, :nested] do
      raise CompileError,
        description: "#{@label}: вид #{kind}: нет адаптера со всеми операциями"
    end
  end

  # ===== адаптер =====

  @doc false
  @spec pattern(Core.Field.t()) :: Macro.t()

  def pattern(%Core.Field{name: name} = field) do
    value = var(name)
    spec = Core.Field.wire_spec(field.spec)

    if field.optional?, do: value, else: pattern!(tag(spec, :pattern), spec, value)
  end

  @doc false
  @spec guard(Core.Field.t()) :: Macro.t() | true

  def guard(%Core.Field{name: name} = field) do
    value = var(name)
    spec = Core.Field.wire_spec(field.spec)

    cond do
      field.optional? -> quote(generated: true, do: is_nil(unquote(value)) or unquote(value_guard(spec, value)))
      closes?(spec) -> true
      true -> value_guard(spec, value)
    end
  end

  @doc false
  @spec value_guard(Core.Field.spec(), Macro.t()) :: Macro.t()

  def value_guard(spec, value), do: value_guard!(tag(strip(spec), :guard), strip(spec), value)

  # Пропускает ли guard вида любое значение-struct: у `union:` — `is_struct/1`, у `type: :map` —
  # `is_map/1`. Нужен нагрузке события: `%Core.Es.Personal.Destroyed{}` в поле с `subject:` такой
  # guard не ловит.
  @doc false
  @spec admits_struct?(Core.Field.spec()) :: boolean()

  def admits_struct?(spec) do
    spec = strip(spec)

    case tag(spec, :struct) do
      :never -> false
      :any -> true
      :map_type -> match?({:type, :map}, spec)
    end
  end

  @doc false
  @spec dump(Core.Field.t(), Macro.t()) :: Macro.t()

  def dump(%Core.Field{} = field, value) do
    spec = Core.Field.wire_spec(field.spec)

    if as_is?(spec) do
      value
    else
      expr = dump!(tag(spec, :dump), %{field | spec: spec}, value)

      if field.optional?,
        do: quote(generated: true, do: if(is_nil(unquote(value)), do: nil, else: unquote(expr))),
        else: expr
    end
  end

  @doc false
  @spec load(Core.Field.t(), module(), Macro.t()) :: Macro.t()

  # Уничтоженное значение ставит обход ПДн-мест (`Core.Es.Personal.Plan`) ещё до разбора вида: у
  # `union:` — до выбора варианта, ручной Codec не вызывается. Здесь оно просто проходит насквозь.
  def load(field, type, raw) do
    raw_var = Macro.var(:load_raw, __MODULE__)

    quote generated: true do
      unquote(raw_var) = unquote(raw)

      case unquote(raw_var) do
        %Core.Es.Personal.Destroyed{} -> {:ok, unquote(raw_var)}
        _value -> unquote(load_value(field, type, raw_var))
      end
    end
  end

  @doc false
  @spec var(atom()) :: Macro.t()

  def var(name) when is_atom(name), do: Macro.var(name, :fields_value)

  @doc false
  @spec codec_var() :: Macro.t()

  def codec_var, do: Macro.var(:codec, __MODULE__)

  # ---

  defp load_value(%Core.Field{optional?: true} = field, type, raw) do
    spec = Core.Field.wire_spec(field.spec)

    case tag(spec, :load) do
      :as_is ->
        quote(generated: true, do: {:ok, unquote(raw)})

      :codec ->
        quote(generated: true, do: Helper.load_optional(unquote(elem(spec, 1)), unquote(raw), unquote(codec_var())))

      :enum ->
        quote(generated: true, do: unquote(elem(spec, 1)).cast_optional(unquote(raw)))

      operation ->
        nullable_load(operation, field, type, raw)
    end
  end

  defp load_value(%Core.Field{} = field, type, raw) do
    spec = Core.Field.wire_spec(field.spec)
    load!(tag(spec, :load), %{field | spec: spec}, type, raw)
  end

  defp pattern!(:value, _spec, value), do: value
  defp pattern!(:map, _spec, value), do: quote(generated: true, do: %{} = unquote(value))
  defp pattern!(:map_set, _spec, value), do: quote(generated: true, do: %MapSet{} = unquote(value))

  defp pattern!(:struct, {_kind, mod}, value),
    do: quote(generated: true, do: %unquote(mod){} = unquote(value))

  defp value_guard!(:struct, {_kind, mod}, value),
    do: quote(generated: true, do: is_struct(unquote(value), unquote(mod)))

  defp value_guard!(:struct_any, _spec, value), do: quote(generated: true, do: is_struct(unquote(value)))

  defp value_guard!(:atom, _spec, value),
    do: quote(generated: true, do: is_atom(unquote(value)) and not is_nil(unquote(value)))

  defp value_guard!(:list, _spec, value), do: quote(generated: true, do: is_list(unquote(value)))

  defp value_guard!(:map_set, _spec, value),
    do: quote(generated: true, do: is_struct(unquote(value), MapSet))

  defp value_guard!(:map, _spec, value),
    do: quote(generated: true, do: is_map(unquote(value)) and not is_struct(unquote(value)))

  defp value_guard!(:type, {_kind, type}, value), do: type_guard(type, value)

  defp type_guard(:string, value), do: quote(generated: true, do: is_binary(unquote(value)))
  defp type_guard(:boolean, value), do: quote(generated: true, do: is_boolean(unquote(value)))
  defp type_guard(:integer, value), do: quote(generated: true, do: is_integer(unquote(value)))
  defp type_guard(:map, value), do: quote(generated: true, do: is_map(unquote(value)))

  defp type_guard(:pos_integer, value),
    do: quote(generated: true, do: is_integer(unquote(value)) and unquote(value) > 0)

  defp type_guard(:non_neg_integer, value),
    do: quote(generated: true, do: is_integer(unquote(value)) and unquote(value) >= 0)

  # Голова закрывает вид паттерном: отдельный guard к нему ничего не добавляет.
  defp closes?(spec), do: tag(spec, :pattern) in ~w(struct map_set)a

  defp dump!(:codec, _field, value), do: quote(generated: true, do: unquote(codec_var()).dump(unquote(value)))

  defp dump!(:list, %Core.Field{spec: {:list, inner}} = field, value) do
    item = item_var()

    quote generated: true do
      Enum.map(unquote(value), fn unquote(item) -> unquote(dump(nested(field, inner), item)) end)
    end
  end

  defp dump!(:set, %Core.Field{spec: {:set, inner}} = field, value) do
    item = item_var()

    quote generated: true do
      Helper.set_wire(Enum.map(unquote(value), fn unquote(item) -> unquote(dump(nested(field, inner), item)) end))
    end
  end

  defp dump!(:map, %Core.Field{spec: {:map, key, inner}} = field, value) do
    key_item = key_var()
    item = item_var()

    quote generated: true do
      Map.new(unquote(value), fn {unquote(key_item), unquote(item)} ->
        {unquote(dump_key(nested(field, key), key_item)), unquote(dump(nested(field, inner), item))}
      end)
    end
  end

  defp dump_key(%Core.Field{spec: {:enum, _mod}}, key),
    do: quote(generated: true, do: Helper.enum_key(unquote(key)))

  defp dump_key(field, key), do: dump(field, key)

  # Дамп без обхода: у `enum` и `type` значение уже wire-формы, у `list:` — если и элемент
  # такой. `set` и `map` обходятся всегда: их форма — не список и не map значения поля.
  defp as_is?(spec) do
    case tag(spec, :as_is) do
      :nested -> Enum.all?(Core.Field.Spec.children(spec), &as_is?/1)
      flag -> flag
    end
  end

  defp load!(:as_is, _field, _type, raw), do: quote(generated: true, do: {:ok, unquote(raw)})

  defp load!(:codec, %Core.Field{spec: {_kind, mod}}, _type, raw),
    do: quote(generated: true, do: unquote(codec_var()).load(unquote(mod), unquote(raw)))

  defp load!(:enum, %Core.Field{spec: {_kind, mod}}, _type, raw),
    do: quote(generated: true, do: unquote(mod).cast(unquote(raw)))

  defp load!(:list, %Core.Field{spec: {:list, inner}, name: name} = field, type, raw) do
    item = item_var()

    quote generated: true do
      Core.Codec.Plugin.Fields.Kind.load_list(
        unquote(type),
        unquote(name),
        unquote(raw),
        fn unquote(item) -> unquote(load(nested(field, inner), type, item)) end
      )
    end
  end

  defp load!(:set, %Core.Field{spec: {:set, inner}, name: name} = field, type, raw) do
    item = item_var()

    quote generated: true do
      Core.Codec.Plugin.Fields.Kind.load_set(
        unquote(type),
        unquote(name),
        unquote(raw),
        fn unquote(item) -> unquote(load(nested(field, inner), type, item)) end
      )
    end
  end

  defp load!(:map, %Core.Field{spec: {:map, key, inner}, name: name} = field, type, raw) do
    key_item = key_var()
    item = item_var()

    quote generated: true do
      Core.Codec.Plugin.Fields.Kind.load_map(
        unquote(type),
        unquote(name),
        unquote(raw),
        fn unquote(key_item) -> unquote(load(nested(field, key), type, key_item)) end,
        fn unquote(item) -> unquote(load(nested(field, inner), type, item)) end
      )
    end
  end

  defp nullable_load(operation, field, type, raw) do
    raw_var = Macro.var(:raw, __MODULE__)
    field = %{field | optional?: false}

    quote generated: true do
      case unquote(raw) do
        nil -> {:ok, nil}
        unquote(raw_var) -> unquote(load!(operation, field, type, raw_var))
      end
    end
  end

  # Операция берётся из строки таблицы один раз: второй разбор вида — только через `tag/2`.
  defp tag(spec, operation) do
    kind = elem(spec, 0)

    case Map.fetch(@adapters, kind) do
      {:ok, row} -> Map.fetch!(row, operation)
      :error -> raise CompileError, description: "#{@label}: вид #{kind}: нет адаптера"
    end
  end

  defp nested(field, spec), do: %{field | spec: strip(spec), optional?: false}

  defp strip(spec), do: Core.Field.wire_spec(spec)

  defp item_var, do: Macro.var(:item, __MODULE__)
  defp key_var, do: Macro.var(:key, __MODULE__)

  # ===== загрузка коллекций =====

  @doc false
  @spec load_list(module(), atom(), term(), (term() -> Result.t())) :: Result.t([term()])

  def load_list(type, name, raw, fun) when is_list(raw) and is_function(fun, 1) do
    raw
    |> Enum.with_index()
    |> Result.traverse(fn {item, index} ->
      Result.map_error(fun.(item), &item_error(type, name, {:index, index}, "элемент", &1))
    end)
  end

  def load_list(type, name, _raw, _fun) when is_atom(type) and is_atom(name) do
    {:error,
     Error.domain(type,
       code: :invalid_value,
       ns: :codec,
       message: "#{inspect(type)}: поле #{name} — ожидается список",
       detail: %{field: name}
     )}
  end

  @doc false
  @spec load_set(module(), atom(), term(), (term() -> Result.t())) :: Result.t(MapSet.t())

  def load_set(type, name, raw, fun) when is_list(raw) and is_function(fun, 1),
    do: Result.map(load_list(type, name, raw, fun), &MapSet.new/1)

  def load_set(type, name, _raw, _fun) when is_atom(type) and is_atom(name) do
    {:error,
     Error.domain(type,
       code: :invalid_value,
       ns: :codec,
       message: "#{inspect(type)}: поле #{name} — ожидается список элементов множества",
       detail: %{field: name}
     )}
  end

  @doc false
  @spec load_map(module(), atom(), term(), (term() -> Result.t()), (term() -> Result.t())) ::
          Result.t(map())

  def load_map(type, name, raw, key_fun, value_fun)
      when is_map(raw) and not is_struct(raw) and is_function(key_fun, 1) and is_function(value_fun, 1) do
    raw
    |> Map.to_list()
    |> Result.traverse(fn {key, value} ->
      with {:ok, loaded} <- Result.map_error(key_fun.(key), &item_error(type, name, {:key, key}, "ключ", &1)),
           {:ok, item} <- Result.map_error(value_fun.(value), &item_error(type, name, {:key, key}, "значение", &1)),
           do: {:ok, {key, loaded, item}}
    end)
    |> Result.and_then(&collect_pairs(type, name, &1))
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

  # ---

  # Prim ключа нормализует значение (UUID с дефисами и без): два wire-ключа дали бы один ключ, и
  # значение одного из них молча пропало бы.
  defp collect_pairs(type, name, pairs) do
    pairs
    |> Enum.reduce_while({%{}, %{}}, fn {key, loaded, item}, {map, wires} ->
      case Map.fetch(wires, loaded) do
        {:ok, first} -> {:halt, {:error, key_clash(type, name, key, first)}}
        :error -> {:cont, {Map.put(map, loaded, item), Map.put(wires, loaded, key)}}
      end
    end)
    |> case do
      {:error, error} -> {:error, error}
      {map, _wires} -> {:ok, map}
    end
  end

  defp key_clash(type, name, key, first) do
    Error.domain(type,
      code: :invalid_value,
      ns: :codec,
      message:
        "#{inspect(type)}: поле #{name}[#{inspect(key)}] — ключ совпал после загрузки с ключом #{inspect(first)}",
      detail: %{field: name, key: key}
    )
  end

  # Путь — имя поля, индекс элемента и wire-ключ словаря: ПДн в нём нет (персональный ключ словаря
  # запрещён сборкой), и редакция ошибки поля с `subject:` его не снимает.
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
