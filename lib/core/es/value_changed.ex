defmodule Core.Es.ValueChanged do
  @moduledoc """
  Базовый builder struct'а «значение изменено» (old/new).

  Обязательная опция: `type:` — модуль типа значения: Prim, `Core.Enum` или struct сущности.
  Опционально: `nilable:` (default `false`) — допускает `nil` для old и new.

  Порождаются `@enforce_keys`, `defstruct`, `@type t` и `new/2`, чья голова закрывает вид
  значения: `%Type{}` у Prim и сущности, атом у enum, `nil` при `nilable: true`.

  `__core_fields__/0` — декларация `old_value` / `new_value` в едином IR (`Core.Field`), внутренняя:
  по ней `Core.Es.Event.Codec` выводит клаузы нагрузки события — map
  `%{"old_value" => …, "new_value" => …}`, значения по виду типа (`fields/2`).
  `__core_payload_role__/0` — роль нагрузки (`:fields`): builder объявляет её, чтобы кодек выводил
  wire по декларации, а не по конструктору.

  ПДн-план применяется к `old_value` и `new_value` независимо: сторона с персональным типом —
  ПДн-место с субъектом `:aggregate_id` (тип чтения допускает `%Core.Es.Personal.Destroyed{}`,
  `new/2` его не принимает). Субъект ПДн-места — `:aggregate_id`.

  ## Опции

  Все опции — литералы (`docs/rules/20-agreements.md`, «Опции `use`»): атрибут или вызов
  функции в опции — `CompileError` «ожидается литерал». Модуль `type:` проверяется при раскрытии
  и MUST NOT быть вложен в вызывающего.
  """

  alias Core.Helper

  @label "Es.ValueChanged"
  @required_keys ~w(type)a
  @optional_keys ~w(nilable)a
  @expression_keys ~w()a

  # ===== объявление =====

  @doc "Объявить struct old/new (`type:` / опционально `nilable:`)."
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    opts = Helper.Opts.literal!(opts, @expression_keys, @label)

    type_mod = Helper.Opts.module!(opts, :type, @label)
    nilable? = nilable!(opts)
    fields = core_fields(type_mod, nilable?)
    read_types = Core.Field.read_typespec(fields)
    write_types = Core.Field.write_typespec(fields)

    quote do
      @enforce_keys ~w(old_value new_value)a
      defstruct @enforce_keys

      @core_fields unquote(Macro.escape(fields))
      @core_payload_role :fields

      @type t :: %__MODULE__{unquote_splicing(read_types)}
      @type write_t :: %__MODULE__{unquote_splicing(write_types)}

      @doc false
      @spec __core_fields__() :: [Core.Field.t()]

      def __core_fields__, do: @core_fields

      @doc false
      @spec __core_payload_role__() :: :fields

      def __core_payload_role__, do: @core_payload_role

      @doc "Создать запись изменения значения."
      @spec new(unquote_splicing(Keyword.values(write_types))) :: write_t()

      def new(unquote_splicing(Core.Codec.Plugin.Fields.new_args_ir(fields)))
          when unquote(Core.Es.Event.Payload.new_guard(fields)),
          do: unquote(Core.Es.Event.Payload.new_body(__CALLER__.module, fields))
    end
  end

  # ---

  defp nilable!(opts) do
    case Keyword.get(opts, :nilable, false) do
      nilable? when is_boolean(nilable?) -> nilable?
      other -> Helper.Opts.reject!("#{@label}: nilable", "ожидается boolean, получено #{inspect(other)}")
    end
  end

  # ===== декларация =====

  # Синтетическая декларация `old_value` / `new_value` в IR: у нагрузки нет своей спеки полей, вид
  # задаёт `type:`, но обходчику ПДн и типам нужен тот же состав, что у нагрузки события.
  @doc false
  @spec core_fields(module(), boolean()) :: [Core.Field.t()]

  def core_fields(type, nilable?) when is_atom(type) and is_boolean(nilable?) do
    fields = fields(type, nilable?)

    Core.Es.Personal.Plan.entries!(fields, "Es.ValueChanged", uuid_prim: &Core.Es.Event.Payload.uuid_prim?/1)

    fields
  end

  @doc """
  Спека полей `old_value` / `new_value` по типу значения: Prim → `prim:`, `Core.Enum` → `enum:`,
  иначе `entity:`; `nilable: true` → `optional: true`.
  """
  @spec fields(module(), boolean()) :: [Core.Field.t()]

  def fields(type, nilable?) when is_atom(type) and is_boolean(nilable?) do
    {kind, mod} = Core.Field.value_spec(type, "Es.ValueChanged: type")

    Core.Field.declare!(
      for(name <- ~w(old_value new_value)a, do: {name, [{kind, mod}, optional: nilable?]}),
      :payload,
      "Es.ValueChanged"
    )
  end
end
