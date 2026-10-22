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
  | `type: скаляр` | как есть | как есть |

  `default:` — wire-литерал, который загрузка подставляет вместо отсутствующего ключа или
  `nil` и грузит как записанный. Голова `dump/2` закрывает Prim и сущность поля паттерном, а
  вариант семейства (`union:`) — только `is_struct`: варианты знает плагин семейства, а не этот
  (ADR-0058). Загрузка собирает struct литералом после успешной загрузки
  всех полей; первая ошибка поля — итог, лишние ключи wire игнорируются.

  Нагрузка события (`Core.Es.Event.Payload`) говорит на той же спеке и добавляет к полю
  `subject:` — субъекта ПДн-значения; её клаузы генерируют функции `payload_*` (ADR-0073).
  """

  alias Core.Codec.Field
  alias Core.Error
  alias Core.Prim
  alias Core.Result

  require Error

  @facade_kinds ~w(prim entity union)a
  @pattern_kinds ~w(prim entity)a

  # ===== субъект ПДн-поля =====

  # ПДн без субъекта ушло бы в неизменяемую историю открытым (ADR-0073).
  @doc false
  @spec check_subjects!([Field.t()], module()) :: [Field.t()]

  def check_subjects!(fields, payload) when is_list(fields) and is_atom(payload) do
    by_name = Map.new(fields, fn %Field{name: name} = field -> {name, field} end)

    Enum.each(fields, fn %Field{name: name} = field ->
      check_subject!(field, by_name, "Es.Event.Payload #{inspect(payload)}: fields, поле #{name}")
    end)

    fields
  end

  # Prim — `Prim.UUID` или `Prim.Compose` над ним: только такое значение бывает субъектом ПДн-поля
  # нагрузки. `kind:` у UUID-Prim бывает свой, поэтому обёртку узнаёт `format/2` — его порождает только
  # `use Core.Prim.UUID`.
  @doc false
  @spec uuid_prim?(module()) :: boolean()

  def uuid_prim?(mod) when is_atom(mod), do: Prim.prim?(mod) and uuid_leaf?(leaf(mod))

  # ---

  defp leaf(mod), do: if(Prim.composed?(mod), do: leaf(mod.__domain_base__()), else: mod)

  defp uuid_leaf?(mod), do: Code.ensure_loaded?(mod) and function_exported?(mod, :format, 2)

  defp check_subject!(%Field{spec: spec, subject: nil}, _by_name, where) do
    case personal_prim(spec) do
      nil ->
        :ok

      prim ->
        raise CompileError,
          description:
            "#{where}: персональный Prim #{inspect(prim)} без subject: — объявите субъекта " <>
              "(subject: :aggregate_id или поле нагрузки)"
    end
  end

  defp check_subject!(%Field{subject: :aggregate_id}, _by_name, _where), do: :ok

  defp check_subject!(%Field{name: name, subject: name}, _by_name, where) do
    raise CompileError, description: "#{where}: subject: #{inspect(name)} — поле не бывает своим субъектом"
  end

  defp check_subject!(%Field{optional?: optional?, subject: subject}, by_name, where) do
    case Map.fetch(by_name, subject) do
      :error ->
        raise CompileError, description: "#{where}: subject: #{inspect(subject)} — нет такого поля нагрузки"

      {:ok, %Field{spec: spec, optional?: subject_optional?, subject: nil}} ->
        check_subject_spec!(spec, subject, where)
        check_subject_optional!(optional?, subject_optional?, subject, where)

      {:ok, _outer} ->
        raise CompileError, description: "#{where}: субъект #{subject} сам объявлен с subject:"
    end
  end

  defp check_subject_spec!({:prim, mod}, subject, where) do
    if not uuid_prim?(mod), do: not_uuid!(subject, where)
    :ok
  end

  defp check_subject_spec!(_spec, subject, where), do: not_uuid!(subject, where)

  defp not_uuid!(subject, where) do
    raise CompileError, description: "#{where}: субъект #{subject} — не Prim.UUID и не Prim.Compose над ним"
  end

  defp check_subject_optional!(false, true, subject, where) do
    raise CompileError,
      description:
        "#{where}: обязательное при необязательном субъекте #{subject} — " <>
          "непустое ПДн-значение осталось бы без субъекта"
  end

  defp check_subject_optional!(_optional?, _subject_optional?, _subject, _where), do: :ok

  defp personal_prim({:prim, mod}), do: if(mod.__domain_personal__(), do: mod)
  defp personal_prim({:list, inner}), do: personal_prim(inner)
  defp personal_prim(_spec), do: nil

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

  def new_guard(fields) do
    case field_guards(fields) do
      [] -> true
      guards -> and_guards(guards)
    end
  end

  @doc false
  @spec new_body(module(), [Field.t()]) :: Macro.t()

  def new_body(type, fields) do
    pairs = Enum.map(fields, fn %Field{name: name} -> {name, var(name)} end)

    quote(generated: true, do: %unquote(type){unquote_splicing(pairs)})
  end

  @doc """
  Аргументы клаузы дампа нагрузки события `type` у события `event`.

  Поле с `subject:` голова не закрывает struct'ом своего вида: на его месте законно стоит
  `%Core.Es.Personal.Destroyed{}`. `aggregate_id` события связывается, когда он субъект хоть
  одного поля.
  """
  @spec payload_dump_args(module(), module(), [Field.t()]) :: [Macro.t()]

  def payload_dump_args(event, type, fields) do
    pairs = Enum.map(fields, &payload_dump_pattern/1)
    payload = quote(generated: true, do: %unquote(type){unquote_splicing(pairs)})

    event_pairs =
      if Enum.any?(Field.subjects(fields), &match?({_name, :aggregate_id}, &1)),
        do: [payload: payload, aggregate_id: aggregate_id_var()],
        else: [payload: payload]

    [quote(generated: true, do: %unquote(event){unquote_splicing(event_pairs)}), codec_var()]
  end

  @doc """
  Guard клаузы дампа нагрузки события: вид каждого поля, у поля с `subject:` — ещё
  `%Core.Es.Personal.Destroyed{}`; непустое ПДн-значение при `nil` в поле-субъекте — мимо клаузы.
  """
  @spec payload_dump_guard([Field.t()]) :: Macro.t()

  def payload_dump_guard(fields) do
    guards = Enum.flat_map(fields, &payload_dump_field_guard/1) ++ subject_guards(fields) ++ aggregate_guards(fields)

    and_guards([quote(generated: true, do: is_atom(unquote(codec_var()))) | guards])
  end

  @doc "Тело дампа нагрузки события: на месте значения поля с `subject:` — `%Core.Es.Personal.Marker{}`."
  @spec payload_dump_body([Field.t()]) :: Macro.t()

  def payload_dump_body(fields) do
    pairs =
      Enum.map(fields, fn
        %Field{name: name, spec: spec, optional?: optional?, wire: wire, subject: nil} ->
          {wire, dump_value(spec, var(name), optional?)}

        %Field{name: name, spec: spec, optional?: optional?, wire: wire, subject: subject} ->
          {wire, marker(spec, var(name), optional?, subject)}
      end)

    quote(generated: true, do: %{unquote_splicing(pairs)})
  end

  @doc """
  Guard `new/N` нагрузки события: как у `new_guard/1`, плюс отказ `%Core.Es.Personal.Destroyed{}`
  в поле, чей вид его пропустил бы (`union:`, `type: :map`), и непустого ПДн-значения при `nil` в
  поле-субъекте.
  """
  @spec payload_new_guard([Field.t()]) :: Macro.t()

  def payload_new_guard(fields) do
    destroyed =
      for %Field{name: name, spec: {kind, _value}, subject: subject} <- fields,
          not is_nil(subject) and kind in ~w(union type)a,
          do: quote(generated: true, do: not is_struct(unquote(var(name)), Core.Es.Personal.Destroyed))

    case field_guards(fields) ++ destroyed ++ subject_guards(fields) do
      [] -> true
      guards -> and_guards(guards)
    end
  end

  # ---

  defp payload_dump_pattern(%Field{subject: nil} = field),
    do: dump_pattern(field)

  defp payload_dump_pattern(%Field{name: name}), do: {name, var(name)}

  defp payload_dump_field_guard(%Field{subject: nil} = field), do: field_guard(field)

  defp payload_dump_field_guard(%Field{name: name, spec: spec, optional?: optional?}) do
    value = var(name)
    destroyed = quote(generated: true, do: is_struct(unquote(value), Core.Es.Personal.Destroyed))
    present = quote(generated: true, do: unquote(destroyed) or unquote(value_guard(spec, value)))

    if optional?,
      do: [quote(generated: true, do: is_nil(unquote(value)) or unquote(present))],
      else: [present]
  end

  # Субъект — поле той же нагрузки, а оно необязательно: непустое ПДн-значение без субъекта не
  # проходит. Обязательного субъекта при `nil` не пропускает его же guard.
  defp subject_guards(fields) do
    optional = for %Field{name: name, optional?: true} <- fields, into: MapSet.new(), do: name

    for %Field{name: name, subject: subject} <- fields, MapSet.member?(optional, subject) do
      quote(generated: true, do: is_nil(unquote(var(name))) or not is_nil(unquote(var(subject))))
    end
  end

  # Событие, собранное литералом мимо `new`, — без идентификатора агрегата: ПДн-значение с субъектом
  # `:aggregate_id` без него не дампится.
  defp aggregate_guards(fields) do
    for {name, :aggregate_id} <- Field.subjects(fields),
        do: quote(generated: true, do: is_nil(unquote(var(name))) or not is_nil(unquote(aggregate_id_var())))
  end

  defp marker(spec, value, optional?, subject) do
    subject = quote(generated: true, do: unquote(codec_var()).dump(unquote(subject_var(subject))))

    clauses =
      quote generated: true do
        %Core.Es.Personal.Destroyed{} ->
          %Core.Es.Personal.Marker{subject: unquote(subject), destroyed: true}

        unquote(value) ->
          %Core.Es.Personal.Marker{subject: unquote(subject), value: unquote(dump_value(spec, value, false))}
      end

    clauses = if optional?, do: quote(generated: true, do: (nil -> nil)) ++ clauses, else: clauses

    quote(generated: true, do: case(unquote(value), do: unquote(clauses)))
  end

  defp subject_var(:aggregate_id), do: aggregate_id_var()
  defp subject_var(name), do: var(name)

  defp aggregate_id_var, do: Macro.var(:aggregate_id, __MODULE__)

  defp field_guards(fields), do: Enum.flat_map(fields, &field_guard/1)

  defp and_guards([first | rest]) do
    Enum.reduce(rest, first, fn guard, acc -> quote(generated: true, do: unquote(acc) and unquote(guard)) end)
  end

  defp dump_pattern(%Field{name: name, spec: {kind, mod}, optional?: false}) when kind in @pattern_kinds,
    do: {name, quote(generated: true, do: %unquote(mod){} = unquote(var(name)))}

  defp dump_pattern(%Field{name: name}), do: {name, var(name)}

  defp field_guard(%Field{spec: {kind, _mod}, optional?: false}) when kind in @pattern_kinds, do: []

  defp field_guard(%Field{name: name, spec: spec, optional?: false}), do: [value_guard(spec, var(name))]

  defp field_guard(%Field{name: name, spec: spec, optional?: true}) do
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

  # ===== load =====

  @doc false
  @spec load_args(module()) :: [Macro.t()]

  def load_args(type), do: [type, wire_var(), codec_var()]

  @doc false
  @spec load_guard() :: Macro.t()

  def load_guard, do: quote(generated: true, do: is_map(unquote(wire_var())) and is_atom(unquote(codec_var())))

  @doc false
  @spec load_body(module(), [Field.t()]) :: Macro.t()

  def load_body(type, fields), do: load_body(type, fields, &load_step(type, &1))

  @doc """
  Тело загрузки нагрузки события: перед загрузкой поля — разбор `{"$pd": …}` (ADR-0074).

  - `{"$pd": null}` в поле с `subject:` → `%Core.Es.Personal.Destroyed{}` на месте поля целиком;
  - `{"$pd": null}` в поле без `subject:` → `:invalid_value`, `{"$pd": "<строка>"}` в любом поле →
    `:sealed_personal_value` (`ns: :codec`);
  - ошибка загрузки поля с `subject:` — с отредактированным `detail` по всей цепочке.
  """
  @spec payload_load_body(module(), [Field.t()]) :: Macro.t()

  def payload_load_body(type, fields), do: load_body(type, fields, &payload_load_step(type, &1))

  # ---

  defp load_body(type, fields, step) do
    steps = Enum.map(fields, step)
    pairs = Enum.map(fields, fn %Field{name: name} -> {name, var(name)} end)

    ok = quote(generated: true, do: {:ok, %unquote(type){unquote_splicing(pairs)}})
    error = quote(generated: true, do: ({:error, reason} -> {:error, reason}))

    {:with, [generated: true], steps ++ [[do: ok, else: error]]}
  end

  defp load_step(type, %Field{name: name, spec: spec, optional?: optional?, wire: wire, default: default}) do
    raw =
      with_default(
        quote(generated: true, do: Core.Helper.Map.field(unquote(wire_var()), unquote(wire_key(wire)))),
        default
      )

    quote(generated: true, do: {:ok, unquote(var(name))} <- unquote(load_value(type, name, spec, raw, optional?)))
  end

  defp payload_load_step(
         type,
         %Field{name: name, spec: spec, optional?: optional?, wire: wire, default: :none, subject: subject}
       ) do
    raw = raw_var()
    value = load_value(type, name, spec, raw, optional?)
    value = if is_nil(subject), do: value, else: redacted(value)

    destroyed =
      if is_nil(subject),
        do: [],
        else:
          quote(
            generated: true,
            do: (%{"$pd" => nil} = marker when map_size(marker) == 1 -> {:ok, %Core.Es.Personal.Destroyed{}})
          )

    clauses =
      destroyed ++
        quote generated: true do
          %{"$pd" => sealed} = marker when map_size(marker) == 1 ->
            {:error, Core.Codec.Plugin.Fields.marker_error(unquote(type), unquote(name), sealed)}

          unquote(raw) ->
            unquote(value)
        end

    field = quote(generated: true, do: Core.Helper.Map.field(unquote(wire_var()), unquote(wire_key(wire))))

    quote(generated: true, do: {:ok, unquote(var(name))} <- case(unquote(field), do: unquote(clauses)))
  end

  defp redacted(value) do
    quote generated: true do
      case unquote(value) do
        {:ok, value} -> {:ok, value}
        {:error, reason} -> {:error, Core.Codec.Plugin.Fields.redact(reason)}
      end
    end
  end

  defp raw_var, do: Macro.var(:raw, __MODULE__)

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

  # ===== ПДн-значение при загрузке =====

  @doc false
  @spec marker_error(module(), atom(), term()) :: Error.t()

  def marker_error(type, name, sealed) when is_atom(type) and is_atom(name) and is_binary(sealed) do
    Error.domain(type,
      code: :sealed_personal_value,
      ns: :codec,
      message: "#{inspect(type)}: поле #{name} — ПДн-значение не расшифровано",
      detail: %{field: name}
    )
  end

  def marker_error(type, name, _sealed) when is_atom(type) and is_atom(name) do
    Error.domain(type,
      code: :invalid_value,
      ns: :codec,
      message: "#{inspect(type)}: поле #{name} — маркер ПДн-значения не на месте",
      detail: %{field: name}
    )
  end

  # Ошибку загрузки поля с `subject:` строит Prim, плагин сущности или enum без флага `personal:`, и
  # в её `detail` лежит сырое значение — редактируется вся цепочка.
  @doc false
  @spec redact(term()) :: term()

  def redact(%Error{} = error), do: Prim.redact_error(error)
  def redact(_reason), do: :redacted

  # ===== общее =====

  # Поля — в своём контексте: поле с именем `codec` или `wire` не перекрывает аргумент функции.
  defp var(name), do: Macro.var(name, Core.Codec.Plugin.Fields.Value)

  defp codec_var, do: Macro.var(:codec, __MODULE__)

  defp item_var, do: Macro.var(:item, __MODULE__)
end
