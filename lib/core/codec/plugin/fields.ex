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

  Нагрузка события (`Core.Es.Event.Payload`) говорит на той же спеке и добавляет к полю
  `subject:` — субъекта ПДн-значения; её клаузы генерируют функции `payload_*` (ADR-0073).
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

  @typedoc """
  Субъект ПДн-поля нагрузки события (`subject:`): `:aggregate_id` или имя поля той же нагрузки;
  `nil` — поле без `subject:`. У плагина всегда `nil`.
  """
  @type subject :: atom() | nil

  @typedoc "Нормализованное поле: имя, спека значения, необязательность, wire-ключ, `default:`, субъект."
  @type field :: {atom(), spec(), boolean(), String.t(), default(), subject()}

  # ===== спека =====

  @doc false
  @spec fields!(module(), term(), boolean()) :: [{module(), [field()]}]

  def fields!(_plugin, nil, _loadable?), do: []

  def fields!(plugin, fields, loadable?) when is_list(fields) do
    pairs = Enum.map(fields, &pair!(plugin, &1))
    check_unique!(Enum.map(pairs, &elem(&1, 0)), "#{@label} #{inspect(plugin)}: fields: типы объявлены дважды")

    Enum.map(pairs, fn {type, spec} ->
      {type, type_fields!(type, spec, [], loadable?, "#{@label} #{inspect(plugin)}: fields, тип #{inspect(type)}")}
    end)
  end

  def fields!(plugin, other, _loadable?) do
    raise CompileError,
      description: "#{@label} #{inspect(plugin)}: fields: список пар {Тип, спека}, задано #{inspect(other)}"
  end

  @doc false
  @spec payload_fields!(module(), term()) :: [field()]

  def payload_fields!(payload, spec) when is_atom(payload) do
    where = "Es.Event.Payload #{inspect(payload)}: fields"

    case defaults(spec) do
      [] ->
        spec
        |> spec_fields!(true, true, where)
        |> check_payload!(where)

      names ->
        raise CompileError,
          description:
            "#{where}: default: у нагрузки события нет (поля #{inspect(names)}): " <>
              "развитие события — новый тег и апкаст"
    end
  end

  # Служебный вход для подсистем библиотеки, которые говорят на языке спеки полей (`Core.Labels.Fields`):
  # struct'а и его сверки здесь нет — их проверяет сама подсистема.
  @doc false
  @spec normalize!(term(), String.t()) :: [field()]

  def normalize!(spec, where) when is_binary(where), do: spec_fields!(spec, true, false, where)

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

  @doc "Поля нагрузки события с `subject:`: `[{поле, субъект}]` в порядке объявления."
  @spec subjects([field()]) :: [{atom(), atom()}]

  def subjects(fields) when is_list(fields),
    do: for({name, _spec, _optional?, _wire, _default, subject} <- fields, not is_nil(subject), do: {name, subject})

  # Prim — `Prim.UUID` или `Prim.Compose` над ним: только такое значение бывает субъектом ПДн-поля
  # нагрузки. `kind:` у UUID-Prim бывает свой, поэтому обёртку узнаёт `format/2` — его порождает только
  # `use Core.Prim.UUID`.
  @doc false
  @spec uuid_prim?(module()) :: boolean()

  def uuid_prim?(mod) when is_atom(mod), do: Prim.prim?(mod) and uuid_leaf?(leaf(mod))

  # ---

  defp pair!(_plugin, {type, spec}) when is_atom(type) and not is_nil(type), do: {type, spec}

  defp pair!(plugin, other) do
    raise CompileError,
      description: "#{@label} #{inspect(plugin)}: fields: ожидается пара {Тип, спека}, задано #{inspect(other)}"
  end

  defp leaf(mod), do: if(Prim.composed?(mod), do: leaf(mod.__domain_base__()), else: mod)

  defp uuid_leaf?(mod), do: Code.ensure_loaded?(mod) and function_exported?(mod, :format, 2)

  defp defaults(spec) do
    if Keyword.keyword?(spec),
      do: for({name, opts} <- spec, Keyword.keyword?(opts), Keyword.has_key?(opts, :default), do: name),
      else: []
  end

  defp type_fields!(type, spec, skipped, loadable?, where) do
    fields = spec_fields!(spec, loadable?, false, where)
    check_struct!(type, Keyword.keys(spec), skipped, where)

    fields
  end

  defp spec_fields!(spec, loadable?, payload?, where) do
    if not Keyword.keyword?(spec) or spec == [] do
      raise CompileError, description: "#{where}: непустой keyword-список полей"
    end

    check_unique!(Keyword.keys(spec), "#{where}: поля повторяются")
    fields = Enum.map(spec, fn {name, opts} -> field!(name, opts, loadable?, payload?, "#{where}, поле #{name}") end)
    check_unique!(Enum.map(fields, &elem(&1, 3)), "#{where}: wire-ключи повторяются")

    fields
  end

  defp field!(name, opts, loadable?, payload?, where) do
    if not Keyword.keyword?(opts) do
      raise CompileError, description: "#{where}: keyword-спека"
    end

    case Keyword.keys(opts) -- (@kind_keys ++ @extra_keys ++ if(payload?, do: [:subject], else: [])) do
      [] -> :ok
      unknown -> raise CompileError, description: "#{where}: неизвестные ключи #{inspect(unknown)}"
    end

    spec = spec!(opts, where)
    optional? = optional!(opts, where)

    {name, spec, optional?, wire!(name, opts, where), default!(opts, spec, optional?, loadable?, where),
     subject!(opts, where)}
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
      raise CompileError, description: "#{where}: list: keyword-спека элемента"
    end

    if Keyword.has_key?(inner, :optional) do
      raise CompileError, description: "#{where}: optional: задаётся у самого поля, не в list:"
    end

    case Keyword.keys(inner) -- @kind_keys do
      [] -> {:list, spec!(inner, where)}
      unknown -> raise CompileError, description: "#{where}: list: неизвестные ключи #{inspect(unknown)}"
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
      other -> raise CompileError, description: "#{where}: optional: boolean, задано #{inspect(other)}"
    end
  end

  defp wire!(name, opts, where) do
    case Keyword.fetch(opts, :wire) do
      :error -> Atom.to_string(name)
      {:ok, wire} when is_binary(wire) and wire != "" -> wire
      {:ok, other} -> raise CompileError, description: "#{where}: wire: непустая строка, задано #{inspect(other)}"
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

  defp subject!(opts, where) do
    case Keyword.fetch(opts, :subject) do
      :error ->
        nil

      {:ok, subject} when is_atom(subject) and subject not in [nil, true, false] ->
        subject

      {:ok, other} ->
        raise CompileError,
          description: "#{where}: subject: атом — :aggregate_id или имя поля нагрузки, задано #{inspect(other)}"
    end
  end

  # Нагрузка события: wire-ключ на `$` совпал бы с зарезервированной формой `{"$pd": …}`, а ПДн
  # без субъекта ушло бы в неизменяемую историю открытым (ADR-0073).
  defp check_payload!(fields, where) do
    by_name = Map.new(fields, &{elem(&1, 0), &1})

    Enum.each(fields, fn {name, spec, optional?, wire, _default, subject} ->
      field = "#{where}, поле #{name}"

      check_wire!(wire, field)
      check_subject!({name, spec, optional?, subject}, by_name, field)
    end)

    fields
  end

  defp check_wire!("$" <> _rest = wire, where) do
    raise CompileError,
      description: "#{where}: wire-ключ #{inspect(wire)} начинается с $ — форма {\"$pd\": …} зарезервирована"
  end

  defp check_wire!(_wire, _where), do: :ok

  defp check_subject!({_name, spec, _optional?, nil}, _by_name, where) do
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

  defp check_subject!({_name, _spec, _optional?, :aggregate_id}, _by_name, _where), do: :ok

  defp check_subject!({name, _spec, _optional?, name}, _by_name, where) do
    raise CompileError, description: "#{where}: subject: #{inspect(name)} — поле не бывает своим субъектом"
  end

  defp check_subject!({_name, _spec, optional?, subject}, by_name, where) do
    case Map.fetch(by_name, subject) do
      :error ->
        raise CompileError, description: "#{where}: subject: #{inspect(subject)} — нет такого поля нагрузки"

      {:ok, {_subject, spec, subject_optional?, _wire, _default, nil}} ->
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
      Enum.map(fields, fn {name, spec, optional?, wire, _default, _subject} ->
        {wire, dump_value(spec, var(name), optional?)}
      end)

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
    pairs = Enum.map(fields, fn {name, _spec, _optional?, _wire, _default, _subject} -> {name, var(name)} end)

    quote(generated: true, do: %unquote(type){unquote_splicing(pairs)})
  end

  @doc """
  Аргументы клаузы дампа нагрузки события `type` у события `event`.

  Поле с `subject:` голова не закрывает struct'ом своего вида: на его месте законно стоит
  `%Core.Es.Personal.Destroyed{}`. `aggregate_id` события связывается, когда он субъект хоть
  одного поля.
  """
  @spec payload_dump_args(module(), module(), [field()]) :: [Macro.t()]

  def payload_dump_args(event, type, fields) do
    pairs = Enum.map(fields, &payload_dump_pattern/1)
    payload = quote(generated: true, do: %unquote(type){unquote_splicing(pairs)})

    event_pairs =
      if Enum.any?(subjects(fields), &match?({_name, :aggregate_id}, &1)),
        do: [payload: payload, aggregate_id: aggregate_id_var()],
        else: [payload: payload]

    [quote(generated: true, do: %unquote(event){unquote_splicing(event_pairs)}), codec_var()]
  end

  @doc """
  Guard клаузы дампа нагрузки события: вид каждого поля, у поля с `subject:` — ещё
  `%Core.Es.Personal.Destroyed{}`; непустое ПДн-значение при `nil` в поле-субъекте — мимо клаузы.
  """
  @spec payload_dump_guard([field()]) :: Macro.t()

  def payload_dump_guard(fields) do
    guards = Enum.flat_map(fields, &payload_dump_field_guard/1) ++ subject_guards(fields) ++ aggregate_guards(fields)

    and_guards([quote(generated: true, do: is_atom(unquote(codec_var()))) | guards])
  end

  @doc "Тело дампа нагрузки события: на месте значения поля с `subject:` — `%Core.Es.Personal.Marker{}`."
  @spec payload_dump_body([field()]) :: Macro.t()

  def payload_dump_body(fields) do
    pairs =
      Enum.map(fields, fn
        {name, spec, optional?, wire, _default, nil} -> {wire, dump_value(spec, var(name), optional?)}
        {name, spec, optional?, wire, _default, subject} -> {wire, marker(spec, var(name), optional?, subject)}
      end)

    quote(generated: true, do: %{unquote_splicing(pairs)})
  end

  @doc """
  Guard `new/N` нагрузки события: как у `new_guard/1`, плюс отказ `%Core.Es.Personal.Destroyed{}`
  в поле, чей вид его пропустил бы (`union:`, `type: :map`), и непустого ПДн-значения при `nil` в
  поле-субъекте.
  """
  @spec payload_new_guard([field()]) :: Macro.t()

  def payload_new_guard(fields) do
    destroyed =
      for {name, {kind, _value}, _optional?, _wire, _default, subject} <- fields,
          not is_nil(subject) and kind in ~w(union type)a,
          do: quote(generated: true, do: not is_struct(unquote(var(name)), Core.Es.Personal.Destroyed))

    case field_guards(fields) ++ destroyed ++ subject_guards(fields) do
      [] -> true
      guards -> and_guards(guards)
    end
  end

  # ---

  defp payload_dump_pattern({_name, _spec, _optional?, _wire, _default, nil} = field),
    do: dump_pattern(field)

  defp payload_dump_pattern({name, _spec, _optional?, _wire, _default, _subject}), do: {name, var(name)}

  defp payload_dump_field_guard({_name, _spec, _optional?, _wire, _default, nil} = field), do: field_guard(field)

  defp payload_dump_field_guard({name, spec, optional?, _wire, _default, _subject}) do
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
    optional = for {name, _spec, true, _wire, _default, _subject} <- fields, into: MapSet.new(), do: name

    for {name, _spec, _optional?, _wire, _default, subject} <- fields, MapSet.member?(optional, subject) do
      quote(generated: true, do: is_nil(unquote(var(name))) or not is_nil(unquote(var(subject))))
    end
  end

  # Событие, собранное литералом мимо `new`, — без идентификатора агрегата: ПДн-значение с субъектом
  # `:aggregate_id` без него не дампится.
  defp aggregate_guards(fields) do
    for {name, :aggregate_id} <- subjects(fields),
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

  defp dump_pattern({name, {kind, mod}, false, _wire, _default, _subject}) when kind in @pattern_kinds,
    do: {name, quote(generated: true, do: %unquote(mod){} = unquote(var(name)))}

  defp dump_pattern({name, _spec, _optional?, _wire, _default, _subject}), do: {name, var(name)}

  defp field_guard({_name, {kind, _mod}, false, _wire, _default, _subject}) when kind in @pattern_kinds, do: []

  defp field_guard({name, spec, false, _wire, _default, _subject}), do: [value_guard(spec, var(name))]

  defp field_guard({name, spec, true, _wire, _default, _subject}) do
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
      {name, spec, false, _wire, _default, _subject} -> {name, spec_type(spec)}
      {name, spec, true, _wire, _default, _subject} -> {name, quote(do: unquote(spec_type(spec)) | nil)}
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

  def load_body(type, fields), do: load_body(type, fields, &load_step(type, &1))

  @doc """
  Тело загрузки нагрузки события: перед загрузкой поля — разбор `{"$pd": …}` (ADR-0074).

  - `{"$pd": null}` в поле с `subject:` → `%Core.Es.Personal.Destroyed{}` на месте поля целиком;
  - `{"$pd": null}` в поле без `subject:` → `:invalid_value`, `{"$pd": "<строка>"}` в любом поле →
    `:sealed_personal_value` (`ns: :codec`);
  - ошибка загрузки поля с `subject:` — с отредактированным `detail` по всей цепочке.
  """
  @spec payload_load_body(module(), [field()]) :: Macro.t()

  def payload_load_body(type, fields), do: load_body(type, fields, &payload_load_step(type, &1))

  # ---

  defp load_body(type, fields, step) do
    steps = Enum.map(fields, step)
    pairs = Enum.map(fields, fn {name, _spec, _optional?, _wire, _default, _subject} -> {name, var(name)} end)

    ok = quote(generated: true, do: {:ok, %unquote(type){unquote_splicing(pairs)}})
    error = quote(generated: true, do: ({:error, reason} -> {:error, reason}))

    {:with, [generated: true], steps ++ [[do: ok, else: error]]}
  end

  defp load_step(type, {name, spec, optional?, wire, default, _subject}) do
    raw =
      with_default(
        quote(generated: true, do: Core.Helper.Map.field(unquote(wire_var()), unquote(wire_key(wire)))),
        default
      )

    quote(generated: true, do: {:ok, unquote(var(name))} <- unquote(load_value(type, name, spec, raw, optional?)))
  end

  defp payload_load_step(type, {name, spec, optional?, wire, :none, subject}) do
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
