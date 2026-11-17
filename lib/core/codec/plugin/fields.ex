defmodule Core.Codec.Plugin.Fields do
  @moduledoc """
  Генерация клауз `dump/2` / `load/3` Codec-плагина по общей декларации типа (`__core_fields__/0`,
  `Core.Field`) — и для типов `types:`, и для декларативных вариантов семейства.

  Поля приходят единым IR: вид, wire-ключ, `optional:` и типизированный `default:` уже
  нормализованы. Проекция IR на грамматику `Core.Codec.Field` (`grammar/1`) нужна адаптеру вида
  (`Core.Codec.Plugin.Fields.Kind`); вложенное ПДн-место (`{:personal, вид}`) wire-форму не меняет.
  Блоки поштучного значения поля (`dump_value/3`, `load_value/5`, `new_args/1`) переиспользует
  нагрузка события (`Core.Es.Event.Payload`).

  | Вид | Дамп | Загрузка |
  |---|---|---|
  | `prim: Prim` | `codec.dump/1` | `codec.load(Prim, raw)` |
  | `enum: Enum` | атом как есть | `Enum.cast/1` (`cast_optional/1` при `optional:`) |
  | `entity: Mod` | `codec.dump/1` | `codec.load(Mod, raw)` |
  | `union: Family` | `codec.dump/1` | `codec.load(Family, raw)` |
  | `list: спека` | поэлементно по спеке | поэлементно по спеке; не список — ошибка |
  | `set: спека` | список по JSON-кодировке wire элемента, без повторов | `MapSet` поэлементно; повторы схлопываются, не список — ошибка |
  | `map: [key: спека, value: спека]` | объект `{"<wire ключа>": <wire значения>}` | map по видам ключа и значения; не объект — ошибка |
  | `type: скаляр` | как есть | как есть |

  Множество (`set:`) даёт один wire на одно значение: порядок списка — по JSON-кодировке wire
  элемента (`Jason.encode!/1`), а не по обходу `MapSet` и не по терму (`%Date{}` и `%Decimal{}` как
  термы сравниваются по полям struct); элементы с равным wire схлопываются (ADR-0091). Тот же порядок
  пишут пере-дамп (`Core.Codec.Redump`) и `Core.View`. Ошибку элемента списка и множества загрузка
  оборачивает ошибкой поля с `detail: %{field: поле, index: индекс элемента в wire}`.

  Словарь (`map:`) — соответствие ключа значению, у каждого свой вид; `type: :map` — map без спеки
  ключа и значения, загрузка отдаёт её как есть. Ключ словаря — вид с wire-строкой: Prim со
  строковой базой (`Prim.String`, `Prim.UUID`, `Prim.Compose` над ними), `enum:` (wire — строка
  значения) или `type: :string`; иное и Prim `personal: true` / `sensitive:` — `CompileError`
  (ADR-0091). Порядок ключей объекта не гарантируется. Ошибку ключа или значения загрузка
  оборачивает ошибкой поля с `detail: %{field: поле, key: wire-ключ}`; два wire-ключа, которые
  после загрузки дали один ключ (Prim ключа нормализует значение), — такая же ошибка без причины.

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
  alias Core.Codec.Plugin.Fields.Kind
  alias Core.Error

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
    do: Enum.map(fields, &{&1.wire, Kind.dump(&1, var(&1.name))})

  # Декларативная структура (`Core.Field`) отдаёт поля единым IR: поля, wire-ключи и вид берутся из
  # `__core_fields__/0`, а `default:` — типизированное значение поля, не wire-литерал.
  @doc false
  @spec dump_args_ir(module(), [map()]) :: [Macro.t()]

  def dump_args_ir(type, fields) do
    pairs = Enum.map(fields, &{&1.name, Kind.pattern(grammar(&1))})

    [quote(generated: true, do: %unquote(type){unquote_splicing(pairs)}), codec_var()]
  end

  @doc false
  @spec dump_guard_ir([map()]) :: Macro.t()

  def dump_guard_ir(fields) do
    guards =
      Enum.flat_map(fields, fn field ->
        case Kind.guard(grammar(field)) do
          true -> []
          guard -> [guard]
        end
      end)

    and_guards([quote(generated: true, do: is_atom(unquote(codec_var()))) | guards])
  end

  @doc false
  @spec dump_pairs_ir([map()]) :: [{String.t(), Macro.t()}]

  def dump_pairs_ir(fields), do: Enum.map(fields, &{&1.wire, Kind.dump(grammar(&1), var(&1.name))})

  @doc false
  @spec dump_body_ir([map()]) :: Macro.t()

  def dump_body_ir(fields), do: quote(generated: true, do: %{unquote_splicing(dump_pairs_ir(fields))})

  @doc false
  @spec new_args([Field.t()]) :: [Macro.t()]

  def new_args(fields), do: Enum.map(fields, &elem(dump_pattern(&1), 1))

  # Аргумент `new/N` — шаблон вида поля: голова закрывает Prim, сущность, множество и словарь, как
  # у плагина по полям.
  @doc false
  @spec new_args_ir([map()]) :: [Macro.t()]

  def new_args_ir(fields), do: Enum.map(fields, &Kind.pattern(grammar(&1)))

  @doc false
  @spec new_guard_ir([map()]) :: Macro.t()

  def new_guard_ir(fields), do: and_guards(Enum.flat_map(fields, &field_guard_ir/1))

  @doc false
  @spec new_body_ir(module(), [map()]) :: Macro.t()

  def new_body_ir(type, fields) do
    pairs = Enum.map(fields, &{&1.name, var(&1.name)})

    quote(generated: true, do: %unquote(type){unquote_splicing(pairs)})
  end

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

  def dump_pattern(%Field{name: name} = field), do: {name, Kind.pattern(field)}

  @doc false
  @spec dump_pattern_ir(map()) :: {atom(), Macro.t()}

  def dump_pattern_ir(field), do: {field.name, Kind.pattern(grammar(field))}

  @doc false
  @spec field_guard_ir(map()) :: [Macro.t()]

  def field_guard_ir(field) do
    case Kind.guard(grammar(field)) do
      true -> []
      guard -> [guard]
    end
  end

  @doc false
  @spec field_guard(Field.t()) :: [Macro.t()]

  def field_guard(%Field{} = field) do
    case Kind.guard(field) do
      true -> []
      guard -> [guard]
    end
  end

  @doc false
  @spec value_guard(Field.spec(), Macro.t()) :: Macro.t()

  def value_guard(spec, value), do: Kind.value_guard(spec, value)

  @doc false
  @spec admits_struct?(Field.spec()) :: boolean()

  def admits_struct?(spec), do: Kind.admits_struct?(spec)

  @doc false
  @spec dump_value(Field.spec(), Macro.t(), boolean()) :: Macro.t()

  def dump_value(spec, value, optional?), do: Kind.dump(spec_field(spec, optional?), value)

  @doc false
  @spec dump_value_ir(Core.Field.spec(), Macro.t(), boolean()) :: Macro.t()

  def dump_value_ir(spec, value, optional?),
    do: Kind.dump(spec_field(grammar_spec(spec), optional?), value)

  @doc false
  @spec value_guard_ir(Core.Field.spec(), Macro.t()) :: Macro.t()

  def value_guard_ir(spec, value), do: Kind.value_guard(grammar_spec(spec), value)

  @doc false
  @spec admits_struct_ir(Core.Field.spec()) :: boolean()

  def admits_struct_ir(spec), do: Kind.admits_struct?(grammar_spec(spec))

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

  @doc false
  @spec load_body_ir(module(), [map()]) :: Macro.t()

  def load_body_ir(type, fields) do
    entries = Macro.var(:personal_entries, __MODULE__)
    steps = Enum.map(fields, &ir_load_step(type, &1, entries))
    pairs = Enum.map(fields, fn field -> {field.name, var(field.name)} end)

    ok = quote(generated: true, do: {:ok, %unquote(type){unquote_splicing(pairs)}})
    error = quote(generated: true, do: ({:error, reason} -> {:error, reason}))
    with_ast = {:with, [generated: true], steps ++ [[do: ok, else: error]]}

    quote generated: true do
      unquote(entries) = Core.Es.Personal.Plan.entries(unquote(Macro.escape(fields)))
      unquote(with_ast)
    end
  end

  # ---

  defp ir_load_step(type, %{name: name, wire: wire, default: :none} = field, entries) do
    raw = quote(generated: true, do: Core.Helper.Map.field(unquote(wire_var()), unquote(wire_key(wire))))

    quote(generated: true, do: {:ok, unquote(var(name))} <- unquote(placed_load(type, field, raw, entries)))
  end

  # `default:` декларации — типизированное значение поля: при отсутствующем ключе оно подставляется
  # как есть, явный `null` его не заменяет и грузится как записанное.
  defp ir_load_step(type, %{name: name, wire: wire, default: {:default, value}} = field, entries) do
    raw_var = Macro.var(:ir_raw, __MODULE__)

    quote generated: true do
      {:ok, unquote(var(name))} <-
        case Core.Helper.Map.fetch(unquote(wire_var()), unquote(wire_key(wire))) do
          {:ok, unquote(raw_var)} -> unquote(placed_load(type, field, raw_var, entries))
          :error -> {:ok, unquote(Macro.escape(value))}
        end
    end
  end

  # Разбор ПДн-мест поля до разбора вида: `{"$pd": null}` на месте → `%Destroyed{}`, оставшийся
  # маркер — отказ; ошибка под местом редактируется, путь ошибки остаётся.
  defp placed_load(type, field, raw, entries) do
    raw_var = Macro.var(:place_raw, __MODULE__)

    quote generated: true do
      personal = Core.Es.Personal.Plan.under(unquote(entries), unquote(wire_key(field.wire)))

      with {:ok, unquote(raw_var)} <-
             Core.Es.Personal.Plan.load(unquote(raw), personal, unquote(type), unquote(field.name)) do
        Core.Es.Event.Payload.redacted_result(unquote(Kind.load(grammar(field), type, raw_var)), personal != [])
      end
    end
  end

  defp load_step(type, %Field{name: name, wire: wire, default: default} = field) do
    raw =
      with_default(
        quote(generated: true, do: Core.Helper.Map.field(unquote(wire_var()), unquote(wire_key(wire)))),
        default
      )

    quote(generated: true, do: {:ok, unquote(var(name))} <- unquote(Kind.load(field, type, raw)))
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

  def load_value(type, name, spec, raw, optional?), do: Kind.load(spec_field(spec, optional?, name), type, raw)

  @doc false
  @spec load_value_ir(module(), atom(), Core.Field.spec(), Macro.t(), boolean()) :: Macro.t()

  def load_value_ir(type, name, spec, raw, optional?),
    do: Kind.load(spec_field(grammar_spec(spec), optional?, name), type, raw)

  # ===== wire-ключ =====

  # `field/2` читает и атомарный, и строковый ключ, но принимает атом: wire-ключ — литерал
  # спеки в коде плагина, а не внешние данные, и таблицу атомов не засоряет.
  @doc false
  @spec wire_key(String.t()) :: atom()

  # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
  def wire_key(wire) when is_binary(wire), do: String.to_atom(wire)

  # ===== путь ошибки =====

  # Путь — имя поля, индекс элемента и wire-ключ словаря: ПДн в нём нет (персональный ключ словаря
  # запрещён сборкой), и редакция ошибки поля с `subject:` его не снимает.
  @doc false
  @spec path_error?(Error.t()) :: boolean()

  def path_error?(%Error{ns: :codec, detail: %{field: name} = detail}) when is_atom(name),
    do: Map.keys(detail) -- ~w(field index key)a == []

  def path_error?(%Error{}), do: false

  # ===== переменные =====

  # Поля — в своём контексте: поле с именем `codec` или `wire` не перекрывает аргумент функции.
  @doc false
  @spec var(atom()) :: Macro.t()

  def var(name) when is_atom(name), do: Kind.var(name)

  @doc false
  @spec codec_var() :: Macro.t()

  def codec_var, do: Kind.codec_var()

  @doc false
  @spec wire_var() :: Macro.t()

  def wire_var, do: Macro.var(:wire, __MODULE__)

  # ===== проекция IR =====

  @doc false
  @spec grammar_spec(Core.Field.spec()) :: Core.Codec.Field.spec()

  def grammar_spec({:personal, inner}), do: grammar_spec(inner)
  def grammar_spec({:personal_false, inner}), do: grammar_spec(inner)
  def grammar_spec({kind, inner}) when kind in ~w(list set)a, do: {kind, grammar_spec(inner)}
  def grammar_spec({:map, key, value}), do: {:map, grammar_spec(key), grammar_spec(value)}
  def grammar_spec(spec), do: spec

  # Проекция IR на грамматику спеки: адаптер вида (`Core.Codec.Plugin.Fields.Kind`) знает только
  # `%Core.Codec.Field{}`, а вложенное ПДн-место (`{:personal, вид}`) wire-форму не меняет.
  @doc false
  @spec to_grammar(map()) :: Field.t()

  def to_grammar(field), do: grammar(field)

  # ===== общее =====

  # Поле-путь для спеки без собственной строки спеки: имя и `optional:` нужны операциям адаптера.
  defp spec_field(spec, optional?, name \\ :value) do
    %Field{
      name: name,
      spec: spec,
      optional?: optional?,
      wire: "",
      default: :none,
      subject: nil
    }
  end

  defp grammar(%{name: name, spec: spec, optional?: optional?, wire: wire} = field) do
    %Field{
      name: name,
      spec: grammar_spec(spec),
      optional?: optional?,
      wire: wire,
      default: :none,
      subject: legacy_subject(Map.get(field, :subject)),
      personal: Map.get(field, :personal)
    }
  end

  # Форма `%Core.Codec.Field{}` до тикета 10: адрес субъекта — имя поля нагрузки, без тега.
  defp legacy_subject({_tag, name}), do: name
  defp legacy_subject(subject), do: subject
end
