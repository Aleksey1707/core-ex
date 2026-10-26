defmodule Core.Es.Event.Payload do
  @moduledoc """
  Билдер нагрузки события по полям: struct, позиционный `new`, `@type t` и спека полей
  из одной декларации.

      defmodule Payload do
        use Core.Es.Event.Payload,
          fields: [
            name: [prim: Account.Name],
            note: [prim: Account.Note, optional: true],
            phone: [prim: Account.Phone, subject: :aggregate_id]
          ]
      end

  Спека полей — та же, что у Codec-плагина (`Core.Codec.Field`), без `default:`:
  событие развивается новым тегом и апкастом (ADR-0010, ADR-0020), а не дефолтом —
  `default:` даёт `CompileError`. `fields:` — литерал (`docs/rules/20-agreements.md`, «Опции `use`»):
  атрибут или вызов функции — `CompileError` «ожидается литерал». Модули спеки проверяются в теле
  нагрузки (`fields!/1`), поэтому MAY быть вложены в неё — выше `use`.

  `subject:` — субъект ПДн-значения поля (ADR-0073): `:aggregate_id` или имя поля той же нагрузки
  с `Prim.UUID` / `Prim.Compose` над ним. `CompileError`:

  - персональный Prim (`personal: true`) на поле `prim:` / `list: [prim:]` без `subject:`;
  - субъект — не `Prim.UUID` и не `Prim.Compose` над ним (у `:aggregate_id` проверяет
    `use Core.Es.Event`), поле с `subject:` в роли субъекта;
  - обязательное поле при необязательном поле-субъекте;
  - `subject:` на несуществующее поле или на само себя;
  - wire-ключ на `$` у любого поля: форма `{"$pd": …}` зарезервирована.

  Порождаются:

  - `@enforce_keys` (все поля, кроме `optional: true`) и `defstruct`;
  - `@type t` по видам полей (`optional:` — `| nil`, `subject:` — `| Core.Es.Personal.Destroyed.t()`);
  - `new/N` — поля позиционно в порядке объявления; голова проверяет вид каждого поля, как
    `dump/2` плагина по полям (вариант семейства `union:` — только `is_struct`), так что нагрузка
    не того вида ловится при сборке вызывающего. `%Core.Es.Personal.Destroyed{}` и непустое
    ПДн-значение при `nil` в поле-субъекте голова не пропускает;
  - `Inspect` без полей с `subject:`;
  - `__es_payload_fields__/0` — внутренняя для `Core.Es.Event.Codec`: нормализованные поля спеки
    (`Core.Codec.Field`), форма поля — не контракт.

  Кодирует такую нагрузку `Core.Es.Event.Codec` события клаузами, которые собирает этот модуль из
  поштучных блоков значения поля `Core.Codec.Plugin.Fields`: на месте поля с `subject:` — маркер
  `{"$pd": …}` (ADR-0073, ADR-0074). В фасаде нагрузка не регистрируется.

  Макрос занимает в модуле нагрузки имя `@es_payload_fields`: поля спеки нагрузки, которая ещё
  собирается, отдаёт `declared_fields/1` — по нему `use Core.Labels.Fields` ниже берёт вид полей.
  """

  alias Core.Codec.Field
  alias Core.Codec.Plugin.Fields
  alias Core.Error
  alias Core.Helper
  alias Core.Prim

  require Error

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
        @es_payload_fields Core.Es.Event.Payload.fields!(unquote(Macro.escape(Keyword.fetch!(opts, :fields))))
      end,
      quote unquote: false do
        case Keyword.keys(Core.Codec.Field.subjects(@es_payload_fields)) do
          [] -> :ok
          hidden -> @derive {Inspect, except: hidden}
        end

        @enforce_keys for %Core.Codec.Field{name: name, optional?: false} <- @es_payload_fields, do: name
        defstruct for %Core.Codec.Field{name: name} <- @es_payload_fields, do: name

        @type t :: %__MODULE__{unquote_splicing(Core.Es.Event.Payload.typespec(@es_payload_fields))}

        @doc false
        @spec __es_payload_fields__() :: [Core.Codec.Field.t()]

        def __es_payload_fields__, do: @es_payload_fields

        @doc "Собрать нагрузку: поля позиционно, в порядке объявления."
        @spec new(unquote_splicing(Keyword.values(Core.Codec.Field.typespec(@es_payload_fields)))) :: t()

        def new(unquote_splicing(Core.Codec.Plugin.Fields.new_args(@es_payload_fields)))
            when unquote(Core.Es.Event.Payload.new_guard(@es_payload_fields)),
            do: unquote(Core.Codec.Plugin.Fields.new_body(__MODULE__, @es_payload_fields))
      end
    ]
  end

  @doc false
  @spec declared_fields(module()) :: [Field.t()] | nil

  def declared_fields(module) when is_atom(module), do: Module.get_attribute(module, :es_payload_fields)

  # Грамматику проверяет `Core.Codec.Field`, смысл `subject:` — эта функция: ПДн без субъекта ушло бы
  # в неизменяемую историю открытым (ADR-0073).
  @doc false
  @spec fields!(term()) :: [Field.t()]

  def fields!(spec) do
    where = "#{@label}: fields"
    fields = Field.normalize!(spec, :payload, where)
    by_name = Map.new(fields, fn %Field{name: name} = field -> {name, field} end)

    Enum.each(fields, fn %Field{name: name} = field -> check_subject!(field, by_name, "#{where}: #{name}") end)

    fields
  end

  # ---

  defp check_subject!(%Field{spec: spec, subject: nil}, _by_name, where) do
    case personal_prim(spec) do
      nil ->
        :ok

      prim ->
        Helper.Opts.reject!(
          where,
          "персональный Prim #{inspect(prim)} без subject: — объявите субъекта " <>
            "(subject: :aggregate_id или поле нагрузки)"
        )
    end
  end

  defp check_subject!(%Field{subject: :aggregate_id}, _by_name, _where), do: :ok

  defp check_subject!(%Field{name: name, subject: name}, _by_name, where) do
    Helper.Opts.reject!(where, "subject: #{inspect(name)} — поле не бывает своим субъектом")
  end

  defp check_subject!(%Field{optional?: optional?, subject: subject}, by_name, where) do
    case Map.fetch(by_name, subject) do
      :error ->
        Helper.Opts.reject!(where, "subject: #{inspect(subject)} — нет такого поля нагрузки")

      {:ok, %Field{spec: spec, optional?: subject_optional?, subject: nil}} ->
        if not uuid_spec?(spec),
          do: Helper.Opts.reject!(where, "субъект #{subject} — не Prim.UUID и не Prim.Compose над ним")

        check_subject_optional!(optional?, subject_optional?, subject, where)

      {:ok, _outer} ->
        Helper.Opts.reject!(where, "субъект #{subject} сам объявлен с subject:")
    end
  end

  defp uuid_spec?({:prim, mod}), do: uuid_prim?(mod)
  defp uuid_spec?(_spec), do: false

  defp check_subject_optional!(false, true, subject, where) do
    Helper.Opts.reject!(
      where,
      "обязательное при необязательном субъекте #{subject} — непустое ПДн-значение осталось бы без субъекта"
    )
  end

  defp check_subject_optional!(_optional?, _subject_optional?, _subject, _where), do: :ok

  defp personal_prim({:prim, mod}), do: if(mod.__domain_personal__(), do: mod)
  defp personal_prim({kind, inner}) when kind in ~w(list set)a, do: personal_prim(inner)
  defp personal_prim({:map, _key, value}), do: personal_prim(value)
  defp personal_prim(_spec), do: nil

  # ===== Prim субъекта =====

  # Prim — `Prim.UUID` или `Prim.Compose` над ним: только такое значение бывает субъектом ПДн-поля
  # нагрузки. `kind:` у UUID-Prim бывает свой, поэтому обёртку узнаёт `format/2` — его порождает только
  # `use Core.Prim.UUID`.
  @doc false
  @spec uuid_prim?(module()) :: boolean()

  def uuid_prim?(mod) when is_atom(mod), do: Prim.prim?(mod) and uuid_leaf?(Prim.leaf(mod))

  # ---

  defp uuid_leaf?(mod), do: Helper.Module.exports?(mod, :format, 2)

  # ===== тип =====

  # Тип чтения шире типа записи (ADR-0074): после `load` в поле с `subject:` бывает уничтоженное
  # значение, а `new/N` его не принимает.
  @doc false
  @spec typespec([Field.t()]) :: keyword(Macro.t())

  def typespec(fields) when is_list(fields) do
    hidden = Keyword.keys(Field.subjects(fields))

    for {name, type} <- Field.typespec(fields) do
      if name in hidden, do: {name, quote(do: unquote(type) | Core.Es.Personal.Destroyed.t())}, else: {name, type}
    end
  end

  # ===== new =====

  @doc """
  Guard `new/N` нагрузки события: вид каждого поля, как у `new/N` плагина по полям, плюс отказ
  `%Core.Es.Personal.Destroyed{}` в поле, чей вид его пропустил бы (`union:`, `type: :map`), и
  непустого ПДн-значения при `nil` в поле-субъекте.
  """
  @spec new_guard([Field.t()]) :: Macro.t()

  def new_guard(fields) do
    destroyed =
      for %Field{name: name, spec: {kind, _value}, subject: subject} <- fields,
          not is_nil(subject) and kind in ~w(union type)a,
          do: quote(generated: true, do: not is_struct(unquote(Fields.var(name)), Core.Es.Personal.Destroyed))

    Fields.and_guards(Enum.flat_map(fields, &Fields.field_guard/1) ++ destroyed ++ subject_guards(fields))
  end

  # ===== dump =====

  @doc """
  Аргументы клаузы дампа нагрузки события `type` у события `event`.

  Поле с `subject:` голова не закрывает struct'ом своего вида: на его месте законно стоит
  `%Core.Es.Personal.Destroyed{}`. `aggregate_id` события связывается, когда он субъект хоть
  одного поля.
  """
  @spec dump_args(module(), module(), [Field.t()]) :: [Macro.t()]

  def dump_args(event, type, fields) do
    pairs = Enum.map(fields, &dump_pattern/1)
    payload = quote(generated: true, do: %unquote(type){unquote_splicing(pairs)})

    event_pairs =
      if Enum.any?(Field.subjects(fields), &match?({_name, :aggregate_id}, &1)),
        do: [payload: payload, aggregate_id: aggregate_id_var()],
        else: [payload: payload]

    [quote(generated: true, do: %unquote(event){unquote_splicing(event_pairs)}), Fields.codec_var()]
  end

  @doc """
  Guard клаузы дампа нагрузки события: вид каждого поля, у поля с `subject:` — ещё
  `%Core.Es.Personal.Destroyed{}`; непустое ПДн-значение при `nil` в поле-субъекте — мимо клаузы.
  """
  @spec dump_guard([Field.t()]) :: Macro.t()

  def dump_guard(fields) do
    guards = Enum.flat_map(fields, &dump_field_guard/1) ++ subject_guards(fields) ++ aggregate_guards(fields)

    Fields.and_guards([quote(generated: true, do: is_atom(unquote(Fields.codec_var()))) | guards])
  end

  @doc "Тело дампа нагрузки события: на месте значения поля с `subject:` — `%Core.Es.Personal.Marker{}`."
  @spec dump_body([Field.t()]) :: Macro.t()

  def dump_body(fields) do
    pairs =
      Enum.map(fields, fn
        %Field{name: name, spec: spec, optional?: optional?, wire: wire, subject: nil} ->
          {wire, Fields.dump_value(spec, Fields.var(name), optional?)}

        %Field{name: name, spec: spec, optional?: optional?, wire: wire, subject: subject} ->
          {wire, marker(spec, Fields.var(name), optional?, subject)}
      end)

    quote(generated: true, do: %{unquote_splicing(pairs)})
  end

  # ---

  defp dump_pattern(%Field{subject: nil} = field), do: Fields.dump_pattern(field)
  defp dump_pattern(%Field{name: name}), do: {name, Fields.var(name)}

  defp dump_field_guard(%Field{subject: nil} = field), do: Fields.field_guard(field)

  defp dump_field_guard(%Field{name: name, spec: spec, optional?: optional?}) do
    value = Fields.var(name)
    destroyed = quote(generated: true, do: is_struct(unquote(value), Core.Es.Personal.Destroyed))
    present = quote(generated: true, do: unquote(destroyed) or unquote(Fields.value_guard(spec, value)))

    if optional?,
      do: [quote(generated: true, do: is_nil(unquote(value)) or unquote(present))],
      else: [present]
  end

  # Событие, собранное литералом мимо `new`, — без идентификатора агрегата: ПДн-значение с субъектом
  # `:aggregate_id` без него не дампится.
  defp aggregate_guards(fields) do
    for {name, :aggregate_id} <- Field.subjects(fields) do
      quote(generated: true, do: is_nil(unquote(Fields.var(name))) or not is_nil(unquote(aggregate_id_var())))
    end
  end

  defp marker(spec, value, optional?, subject) do
    subject = quote(generated: true, do: unquote(Fields.codec_var()).dump(unquote(subject_var(subject))))

    clauses =
      quote generated: true do
        %Core.Es.Personal.Destroyed{} ->
          %Core.Es.Personal.Marker{subject: unquote(subject), destroyed: true}

        unquote(value) ->
          %Core.Es.Personal.Marker{subject: unquote(subject), value: unquote(Fields.dump_value(spec, value, false))}
      end

    clauses = if optional?, do: quote(generated: true, do: (nil -> nil)) ++ clauses, else: clauses

    quote(generated: true, do: case(unquote(value), do: unquote(clauses)))
  end

  defp subject_var(:aggregate_id), do: aggregate_id_var()
  defp subject_var(name), do: Fields.var(name)

  defp aggregate_id_var, do: Macro.var(:aggregate_id, __MODULE__)

  # ===== load =====

  @doc """
  Тело загрузки нагрузки события: перед загрузкой поля — разбор `{"$pd": …}` (ADR-0074).

  - `{"$pd": null}` в поле с `subject:` → `%Core.Es.Personal.Destroyed{}` на месте поля целиком;
  - `{"$pd": null}` в поле без `subject:` → `:invalid_value`, `{"$pd": "<строка>"}` в любом поле →
    `:sealed_personal_value` (`ns: :codec`);
  - ошибка загрузки поля с `subject:` — с отредактированным `detail` по всей цепочке.
  """
  @spec load_body(module(), [Field.t()]) :: Macro.t()

  def load_body(type, fields) do
    steps = Enum.map(fields, &load_step(type, &1))
    pairs = Enum.map(fields, fn %Field{name: name} -> {name, Fields.var(name)} end)

    ok = quote(generated: true, do: {:ok, %unquote(type){unquote_splicing(pairs)}})
    error = quote(generated: true, do: ({:error, reason} -> {:error, reason}))

    {:with, [generated: true], steps ++ [[do: ok, else: error]]}
  end

  # ---

  defp load_step(type, %Field{name: name, spec: spec, optional?: optional?, wire: wire, default: :none} = field) do
    raw = raw_var()
    value = Fields.load_value(type, name, spec, raw, optional?)

    clauses =
      destroyed_clause(field) ++
        quote generated: true do
          %{"$pd" => sealed} = marker when map_size(marker) == 1 ->
            {:error, Core.Es.Event.Payload.marker_error(unquote(type), unquote(name), sealed)}

          unquote(raw) ->
            unquote(redacted(value, field))
        end

    raw_field =
      quote(generated: true, do: Core.Helper.Map.field(unquote(Fields.wire_var()), unquote(Fields.wire_key(wire))))

    quote(generated: true, do: {:ok, unquote(Fields.var(name))} <- case(unquote(raw_field), do: unquote(clauses)))
  end

  defp destroyed_clause(%Field{subject: nil}), do: []

  defp destroyed_clause(%Field{}) do
    quote(
      generated: true,
      do: (%{"$pd" => nil} = marker when map_size(marker) == 1 -> {:ok, %Core.Es.Personal.Destroyed{}})
    )
  end

  defp redacted(value, %Field{subject: nil}), do: value

  defp redacted(value, %Field{}) do
    quote generated: true do
      case unquote(value) do
        {:ok, value} -> {:ok, value}
        {:error, reason} -> {:error, Core.Es.Event.Payload.redact(reason)}
      end
    end
  end

  defp raw_var, do: Macro.var(:raw, __MODULE__)

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

  # Субъект — поле той же нагрузки, а оно необязательно: непустое ПДн-значение без субъекта не
  # проходит. Обязательного субъекта при `nil` не пропускает его же guard.
  defp subject_guards(fields) do
    optional = for %Field{name: name, optional?: true} <- fields, into: MapSet.new(), do: name

    for %Field{name: name, subject: subject} <- fields, MapSet.member?(optional, subject) do
      quote(generated: true, do: is_nil(unquote(Fields.var(name))) or not is_nil(unquote(Fields.var(subject))))
    end
  end
end
