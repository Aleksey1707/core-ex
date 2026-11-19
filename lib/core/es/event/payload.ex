defmodule Core.Es.Event.Payload do
  @moduledoc """
  Билдер нагрузки события по полям: struct, позиционный `new`, типы чтения и записи и спека полей
  из одной декларации.

      defmodule Payload do
        use Core.Es.Event.Payload,
          fields: [
            name: [prim: Account.Name],
            note: [prim: Account.Note, optional: true],
            phone: [prim: Account.Phone, subject: :aggregate_id]
          ]
      end

  Спека полей — та же, что у Codec-плагина (`Core.Field`), без `default:`:
  событие развивается новым тегом и апкастом (ADR-0010, ADR-0020), а не дефолтом —
  `default:` даёт `CompileError`. `fields:` — литерал (`docs/rules/20-agreements.md`, «Опции `use`»):
  атрибут или вызов функции — `CompileError` «ожидается литерал». Модули спеки проверяются в теле
  нагрузки (`fields!/1`), поэтому MAY быть вложены в неё — выше `use`.

  Поле-множество `set:` и поле-словарь `map:` — как у плагина: множество в wire — список по
  JSON-кодировке wire элемента, словарь — объект по wire ключа (ADR-0091).

  ## ПДн-план

  `personal: true` у Prim делает ПДн-местом каждое место с этим Prim, у поля — всё его значение;
  `subject:` выбирает субъект, но ПДн не создаёт: ближайший перекрывает внешний, корневой —
  `:aggregate_id`. Субъект — `:aggregate_id`, поле нагрузки (`{:payload, поле}` или имя) или
  соседнее поле той же структуры (`{:local, поле}`): UUID-Prim или `Prim.Compose` над ним, открытое
  и само не ПДн. `CompileError`:

  - `subject:` в поддереве без ПДн-места и переопределение `subject:` под `personal: true`;
  - субъект — не UUID-Prim, сам объявлен с `subject:` или сам ПДн; нет такого поля;
  - обязательное ПДн-место при необязательном субъекте;
  - непрозрачный тип (`entity:` без `__core_fields__/0`, `union:`, `type: :map`) без
    `personal: true` / `personal: false`;
  - wire-ключ на `$` у любого поля: форма `{"$pd": …}` зарезервирована.

  Порождаются:

  - `@enforce_keys` (все поля, кроме `optional: true`) и `defstruct`;
  - `@type t` — тип чтения: на каждом ПДн-месте `| Core.Es.Personal.Destroyed.t()`;
    `@type write_t` — тип записи, без уничтоженного значения;
  - `new/N` — поля позиционно в порядке объявления; голова проверяет вид каждого поля, как
    `dump/2` плагина по полям (вариант семейства `union:` — только `is_struct`), а тело отвергает
    `%Core.Es.Personal.Destroyed{}` на любом ПДн-месте и непустое ПДн-значение при `nil` субъекте;
  - `Inspect` при непустом плане: ПДн-место — плейсхолдер `%Core.Es.Personal.Hidden{}`, открытые
    поля и открытая часть списка видны;
  - `__core_fields__/0` — внутренняя: состав полей единым IR (`Core.Field`); читает
    `Core.Field.introspect/1`;
  - `__core_payload_role__/0` — внутренняя: роль нагрузки (`:fields`), которую объявляет этот
    builder, а не конструктор; читает `wire_payload?/1`.

  Кодирует такую нагрузку `Core.Es.Event.Codec` клаузами, которые собирает этот модуль из
  поштучных блоков значения поля `Core.Codec.Plugin.Fields`: дамп оставляет значения открытыми,
  затем по `__es_personal__/0` каждое ПДн-место заменяется `%Core.Es.Personal.Marker{}` с
  субъектом и wire-значением (ADR-0073, ADR-0074). Шифрует маркеры `Core.Es.Personal.Wire`.

  Роль нагрузки объявляет builder: `:fields` у нагрузки по полям и у `Core.Es.ValueChanged`.
  По роли `wire_payload?/1` узнаёт нагрузку, чью wire-форму выводит кодек событий; конструктор
  `new/N` роли не объявляет.
  """

  alias Core.Codec.Plugin.Fields
  alias Core.Error
  alias Core.Es.Personal.Plan
  alias Core.Helper
  alias Core.Prim

  @label "Es.Event.Payload"
  @required_keys ~w(fields)a
  @optional_keys ~w()a
  @expression_keys ~w()a

  # ===== спека =====

  @doc "Объявить нагрузку события по полям (`fields:`)."
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    opts = Helper.Opts.literal!(opts, @expression_keys, @label)

    [
      quote do
        @core_fields Core.Es.Event.Payload.fields!(unquote(Macro.escape(Keyword.fetch!(opts, :fields))))
        @core_payload_role :fields
        @es_payload_inspect_places Core.Field.inspect_places(@core_fields)
      end,
      quote unquote: false do
        @enforce_keys for %Core.Field{name: name, optional?: false} <- @core_fields, do: name

        defstruct for %Core.Field{name: name} <- @core_fields, do: name

        @type t :: %__MODULE__{unquote_splicing(Core.Field.read_typespec(@core_fields))}
        @type write_t :: %__MODULE__{unquote_splicing(Core.Field.write_typespec(@core_fields))}

        @doc "Собрать нагрузку: поля позиционно, в порядке объявления."
        @spec new(unquote_splicing(Keyword.values(Core.Field.write_typespec(@core_fields)))) :: write_t()

        def new(unquote_splicing(Fields.new_args_ir(@core_fields)))
            when unquote(Core.Es.Event.Payload.new_guard(@core_fields)),
            do: unquote(Core.Es.Event.Payload.new_body(:self, @core_fields))

        @doc false
        @spec __core_fields__() :: [Core.Field.t()]

        def __core_fields__, do: @core_fields

        @doc false
        @spec __core_payload_role__() :: :fields

        def __core_payload_role__, do: @core_payload_role

        @before_compile Core.Es.Event.Payload
      end
    ]
  end

  # Грамматику проверяет `Core.Field`, смысл ПДн-плана — `Core.Es.Personal.Plan`: ПДн без
  # разметки ушло бы в неизменяемую историю открытым (ADR-0073).
  @doc false
  @spec fields!(term()) :: [Core.Field.t()]

  def fields!(spec) do
    where = "#{@label}: fields"
    fields = Core.Field.declare!(spec, :payload, where)

    Plan.entries!(fields, where, uuid_prim: &uuid_prim?/1)

    fields
  end

  @doc """
  Модуль — нагрузка, чью wire-форму кодек событий выводит по её декларации (`:fields`): роль
  объявляет builder нагрузки, а не конструктор. Нагрузка-сущность с плагином (`Core.Struct` и
  ручной struct), в том числе с ручным `new/N` в размер декларации, и однополевое представление
  (`new/1` у `Core.View`) роль не объявляют: их wire задаёт плагин типа.
  """
  @spec wire_payload?(module()) :: boolean()

  def wire_payload?(module) when is_atom(module), do: payload_role(module) == :fields

  # ---

  # Роль читают на сборке, когда нагрузка MAY быть вложена в событие и ещё открыта. Чтение
  # зеркалит `Core.Field.introspect/1`: собранная функция, иначе атрибут собирающегося модуля.
  defp payload_role(module) do
    if Helper.Module.exports?(module, :__core_payload_role__, 0),
      do: module.__core_payload_role__(),
      else: under_compilation(module)
  end

  defp under_compilation(module) do
    if Module.open?(module), do: Module.get_attribute(module, :core_payload_role)
  rescue
    ArgumentError -> nil
  end

  # ===== Inspect =====

  @doc false
  defmacro __before_compile__(env) do
    case Module.get_attribute(env.module, :es_payload_inspect_places) do
      places when is_map(places) and map_size(places) > 0 ->
        places = Macro.escape(places)

        quote do
          defimpl Inspect, for: unquote(env.module) do
            def inspect(struct, opts), do: Core.Struct.inspect_struct(struct, unquote(places), opts)
          end
        end

      _places ->
        nil
    end
  end

  # ===== Prim субъекта =====

  # Prim — `Prim.UUID` или `Prim.Compose` над ним: только такое значение бывает субъектом ПДн-места.
  # `kind:` у UUID-Prim бывает свой, поэтому обёртку узнаёт `format/2` — его порождает только
  # `use Core.Prim.UUID`.
  @doc false
  @spec uuid_prim?(module()) :: boolean()

  def uuid_prim?(mod) when is_atom(mod), do: Prim.prim?(mod) and uuid_leaf?(Prim.leaf(mod))

  # ---

  defp uuid_leaf?(mod), do: Helper.Module.exports?(mod, :format, 2)

  # ===== new =====

  @doc """
  Guard `new/N` нагрузки события: вид каждого поля, как у `new/N` плагина по полям, плюс отказ
  `%Core.Es.Personal.Destroyed{}` на ПДн-месте, чей вид его пропустил бы (`union:`, `type: :map`),
  и непустого ПДн-значения при `nil` в поле-субъекте.
  """
  @spec new_guard([Core.Field.t()]) :: Macro.t()

  def new_guard(fields) do
    plan = Plan.entries(fields)
    destroyed = destroyed_guards(fields, plan)

    Fields.and_guards(Enum.flat_map(fields, &Fields.field_guard_ir/1) ++ destroyed ++ subject_guards(fields))
  end

  @doc "Тело `new/N`: struct нагрузки и отказ записи по ПДн-плану."
  @spec new_body(module(), [Core.Field.t()]) :: Macro.t()

  def new_body(:self, fields), do: new_body(quote(do: __MODULE__), fields)

  def new_body(type, fields) do
    payload = Macro.var(:payload, __MODULE__)
    struct = quote(generated: true, do: %unquote(type){unquote_splicing(pairs(fields))})

    case Plan.runtime_entries(fields) do
      [] ->
        struct

      entries ->
        quote generated: true do
          unquote(payload) = unquote(struct)
          Core.Es.Personal.Plan.assert_writable!(unquote(payload), unquote(Macro.escape(entries)))
          unquote(payload)
        end
    end
  end

  # ---

  defp destroyed_guards(fields, plan) do
    for %Core.Field{name: name, wire: wire, spec: spec} <- fields,
        Plan.place?(plan, [wire_step(wire)]),
        Fields.admits_struct_ir(spec) do
      quote(generated: true, do: not is_struct(unquote(Fields.var(name)), Core.Es.Personal.Destroyed))
    end
  end

  # ===== dump =====

  @doc """
  Аргументы клаузы дампа нагрузки события `type` у события `event`.

  Поле с `subject:` голова не закрывает struct'ом своего вида: на его месте законно стоит
  `%Core.Es.Personal.Destroyed{}`. `aggregate_id` события связывается, когда он субъект хоть
  одного поля.
  """
  @spec dump_args(module(), module(), [Core.Field.t()]) :: [Macro.t()]

  def dump_args(event, type, fields) do
    pairs = Enum.map(fields, &dump_pattern/1)
    struct = quote(generated: true, do: %unquote(type){unquote_splicing(pairs)})

    payload =
      if Plan.runtime_entries(fields) == [],
        do: struct,
        else: quote(generated: true, do: unquote(struct) = unquote(ir_payload_var()))

    event_pairs =
      if aggregate_subject?(fields),
        do: [payload: payload, aggregate_id: aggregate_id_var()],
        else: [payload: payload]

    [quote(generated: true, do: %unquote(event){unquote_splicing(event_pairs)}), Fields.codec_var()]
  end

  @doc """
  Guard клаузы дампа нагрузки события: вид каждого поля, у поля с `subject:` — ещё
  `%Core.Es.Personal.Destroyed{}`; на прочих ПДн-местах уничтоженное значение — мимо клаузы,
  непустое ПДн-значение при `nil` в поле-субъекте — тоже.
  """
  @spec dump_guard([Core.Field.t()]) :: Macro.t()

  def dump_guard(fields) do
    plan = Plan.entries(fields)
    guards = Enum.flat_map(fields, &dump_field_guard(&1, plan)) ++ subject_guards(fields) ++ aggregate_guards(fields)

    Fields.and_guards([quote(generated: true, do: is_atom(unquote(Fields.codec_var()))) | guards])
  end

  @doc """
  Тело дампа нагрузки события: wire-карта открытых значений, затем маркеры ПДн-мест по плану.

  Значение поля с `subject:`, равное `%Core.Es.Personal.Destroyed{}`, остаётся маркером
  уничтоженного значения: писатель wire падает на нём, а не пишет открытый текст.
  """
  @spec dump_body([Core.Field.t()]) :: Macro.t()

  def dump_body(fields) do
    pairs =
      Enum.map(fields, fn %Core.Field{name: name, spec: spec, optional?: optional?, wire: wire, subject: subject} ->
        {wire, dump_field(spec, Fields.var(name), optional?, subject)}
      end)

    body = quote(generated: true, do: %{unquote_splicing(pairs)})

    case Plan.runtime_entries(fields) do
      [] ->
        body

      entries ->
        allow = for %Core.Field{name: name, subject: subject} <- fields, not is_nil(subject), do: [name]
        aggregate_id = if aggregate_subject?(fields), do: aggregate_id_var(), else: quote(do: :unknown)

        quote generated: true do
          Core.Es.Personal.Plan.assert_writable!(
            unquote(ir_payload_var()),
            unquote(Macro.escape(entries)),
            aggregate_id: unquote(aggregate_id),
            allow: unquote(Macro.escape(allow))
          )

          Core.Es.Personal.Plan.mark!(
            unquote(body),
            unquote(Macro.escape(entries)),
            unquote(marked_aggregate_id(fields))
          )
        end
    end
  end

  # ---

  defp dump_field(spec, value, optional?, nil), do: Fields.dump_value_ir(spec, value, optional?)

  defp dump_field(spec, value, optional?, subject) do
    subject = quote(generated: true, do: unquote(Fields.codec_var()).dump(unquote(subject_var(subject))))

    quote generated: true do
      case unquote(value) do
        %Core.Es.Personal.Destroyed{} ->
          %Core.Es.Personal.Marker{subject: unquote(subject), destroyed: true}

        _ ->
          unquote(Fields.dump_value_ir(spec, value, optional?))
      end
    end
  end

  defp marked_aggregate_id(fields) do
    if aggregate_subject?(fields),
      do: quote(generated: true, do: unquote(Fields.codec_var()).dump(unquote(aggregate_id_var())))
  end

  defp aggregate_subject?(fields),
    do: Enum.any?(Plan.entries(fields), &(&1.subject == :aggregate_id))

  defp dump_pattern(%Core.Field{subject: nil} = field), do: Fields.dump_pattern_ir(field)
  defp dump_pattern(%Core.Field{name: name}), do: {name, Fields.var(name)}

  defp dump_field_guard(%Core.Field{subject: nil, wire: wire} = field, plan) do
    if Plan.place?(plan, [wire_step(wire)]),
      do: place_guard(field.spec, Fields.var(field.name), field.optional?),
      else: Fields.field_guard_ir(field)
  end

  defp dump_field_guard(%Core.Field{name: name, spec: spec, optional?: optional?}, _plan) do
    value = Fields.var(name)
    destroyed = quote(generated: true, do: is_struct(unquote(value), Core.Es.Personal.Destroyed))
    present = quote(generated: true, do: unquote(destroyed) or unquote(Fields.value_guard_ir(spec, value)))

    if optional?,
      do: [quote(generated: true, do: is_nil(unquote(value)) or unquote(present))],
      else: [present]
  end

  defp place_guard(spec, value, optional?) do
    if Fields.admits_struct_ir(spec) do
      present =
        quote generated: true do
          unquote(Fields.value_guard_ir(spec, value)) and
            not is_struct(unquote(value), Core.Es.Personal.Destroyed)
        end

      if optional?,
        do: [quote(generated: true, do: is_nil(unquote(value)) or unquote(present))],
        else: [present]
    else
      []
    end
  end

  # Событие, собранное литералом мимо `new`, — без идентификатора агрегата: ПДн-значение с субъектом
  # `:aggregate_id` без него не дампится.
  defp aggregate_guards(fields) do
    if aggregate_subject?(fields),
      do: [quote(generated: true, do: not is_nil(unquote(aggregate_id_var())))],
      else: []
  end

  defp subject_var(:aggregate_id), do: aggregate_id_var()
  defp subject_var({_tag, name}), do: Fields.var(name)
  defp subject_var(name) when is_atom(name), do: Fields.var(name)

  defp aggregate_id_var, do: Macro.var(:aggregate_id, __MODULE__)

  defp ir_payload_var, do: Macro.var(:ir_payload, __MODULE__)

  # ===== маркеры нагрузки-Prim и нагрузки-сущности =====

  @doc """
  Wire-значение нагрузки-Prim/сущности → маркеры ПДн-мест по плану кодека.

  Корневое место (`path: []`) — сам payload: значение целиком становится маркером. У сущности
  с общей декларацией маркеры ставятся на её поля от корня payload.
  """
  @spec mark_payload(term(), [Core.Es.Personal.Plan.entry()], String.t() | nil) :: term()

  def mark_payload(wire, [%{path: [], subject: :aggregate_id}], aggregate_id) when is_binary(aggregate_id) do
    if is_nil(wire), do: nil, else: %Core.Es.Personal.Marker{subject: aggregate_id, value: wire}
  end

  def mark_payload(wire, entries, aggregate_id) when is_map(wire),
    do: Plan.mark!(wire, entries, aggregate_id)

  def mark_payload(wire, _entries, _aggregate_id), do: wire

  # ===== load =====

  @doc """
  Тело загрузки нагрузки события: перед загрузкой поля — разбор `{"$pd": …}` (ADR-0074).

  - `{"$pd": null}` на ПДн-месте → `%Core.Es.Personal.Destroyed{}` на месте поля целиком;
  - `{"$pd": null}` вне ПДн-места → `:invalid_value`, `{"$pd": "<строка>"}` в любом поле →
    `:sealed_personal_value` (`ns: :codec`);
  - ошибка загрузки ПДн-места — с отредактированным `detail` по цепочке; путь ошибки плагина по
    полям (`detail: %{field:, index:}` / `%{field:, key:}`) остаётся.
  """
  @spec load_body(module(), [Core.Field.t()]) :: Macro.t()

  def load_body(type, fields) do
    plan = Plan.entries(fields)
    steps = Enum.map(fields, &load_step(type, &1, plan))
    ok = quote(generated: true, do: {:ok, %unquote(type){unquote_splicing(pairs(fields))}})
    error = quote(generated: true, do: ({:error, reason} -> {:error, reason}))

    {:with, [generated: true], steps ++ [[do: ok, else: error]]}
  end

  # ---

  defp load_step(type, %Core.Field{name: name, spec: spec, optional?: optional?, wire: wire}, plan) do
    raw = raw_var()
    value = Fields.load_value_ir(type, name, spec, raw, optional?)
    places = Plan.under(plan, wire_step(wire))

    raw_field =
      quote(generated: true, do: Core.Helper.Map.field(unquote(Fields.wire_var()), unquote(Fields.wire_key(wire))))

    quote generated: true do
      {:ok, unquote(Fields.var(name))} <-
        with {:ok, unquote(raw)} <-
               Core.Es.Personal.Plan.load(
                 unquote(raw_field),
                 unquote(Macro.escape(places)),
                 unquote(type),
                 unquote(name)
               ) do
          Core.Es.Event.Payload.redacted_result(unquote(value), unquote(places != []))
        end
    end
  end

  defp raw_var, do: Macro.var(:raw, __MODULE__)

  # ===== ПДн-значение при загрузке =====

  # Ошибку загрузки ПДн-места строит Prim, плагин сущности или enum без флага `personal:`, и в её
  # `detail` лежит сырое значение — редактируется цепочка ниже пути ошибки плагина по полям.
  @doc false
  @spec redact(term()) :: term()

  def redact(%Error{parent: parent} = error) do
    cond do
      not Fields.path_error?(error) -> Prim.redact_error(error)
      is_nil(parent) -> error
      true -> %{error | parent: redact(parent)}
    end
  end

  def redact(_reason), do: :redacted

  # Исход загрузки под ПДн-местом: путь ошибки (поле, индекс, ключ) остаётся, значения — нет.
  @doc false
  @spec redacted_result(Core.Result.t(), boolean()) :: Core.Result.t()

  def redacted_result({:ok, value}, _personal?), do: {:ok, value}
  def redacted_result({:error, reason}, true), do: {:error, redact(reason)}
  def redacted_result({:error, reason}, false), do: {:error, reason}

  # ===== общее =====

  defp pairs(fields), do: Enum.map(fields, &{&1.name, Fields.var(&1.name)})

  # Субъект — поле той же нагрузки, а оно необязательно: непустое ПДн-значение без субъекта не
  # проходит. Обязательного субъекта при `nil` не пропускает его же guard.
  defp subject_guards(fields) do
    optional = for %Core.Field{name: name, optional?: true} <- fields, into: MapSet.new(), do: name

    for %Core.Field{name: name} = field <- fields,
        subject = subject_name(field.subject),
        MapSet.member?(optional, subject) do
      quote(generated: true, do: is_nil(unquote(Fields.var(name))) or not is_nil(unquote(Fields.var(subject))))
    end
  end

  defp subject_name(nil), do: nil
  defp subject_name(:aggregate_id), do: :aggregate_id
  defp subject_name({_tag, name}), do: name

  # Wire-ключи объявления, а не внешние данные: таблицу атомов путь плана не засоряет.
  # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
  defp wire_step(wire) when is_binary(wire), do: String.to_atom(wire)
end
