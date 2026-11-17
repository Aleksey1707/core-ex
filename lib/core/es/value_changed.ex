defmodule Core.Es.ValueChanged do
  @moduledoc """
  Базовый builder struct'а «значение изменено» (old/new).

  Обязательная опция: `type:` — модуль типа значения: Prim, `Core.Enum` или struct сущности.
  Опционально: `nilable:` (default `false`) — допускает `nil` для old и new.

  Порождаются `@enforce_keys`, `defstruct`, `@type t` и `new/2`, чья голова закрывает вид
  значения: `%Type{}` у Prim и сущности, атом у enum, `nil` при `nilable: true`.

  `__es_value_changed__/0` отдаёт `type:` и `nilable:`: по ним `Core.Es.Event.Codec` выводит
  клаузы нагрузки события с такой нагрузкой — map
  `%{"old_value" => …, "new_value" => …}`, значения по виду типа (`fields/2`). `__core_fields__/0` —
  та же декларация в едином IR (`Core.Field`), внутренняя.

  ПДн-план применяется к `old_value` и `new_value` независимо: сторона с персональным типом —
  ПДн-место с субъектом `:aggregate_id` (тип чтения допускает `%Core.Es.Personal.Destroyed{}`,
  `new/2` его не принимает).

  Макрос занимает в модуле имя `@es_value_changed`: `type:` и `nilable:` модуля, который ещё
  собирается, отдаёт `declared/1` — по нему `use Core.Labels.Fields, change:` ниже берёт вид значения
  изменения.

  ## Опции

  Все опции — литералы (`docs/rules/20-agreements.md`, «Опции `use`»): атрибут или вызов
  функции в опции — `CompileError` «ожидается литерал». Модуль `type:` проверяется при раскрытии
  и MUST NOT быть вложен в вызывающего.
  """

  alias Core.Codec.Field
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

      @es_value_changed [type: unquote(type_mod), nilable: unquote(nilable?)]

      @core_fields unquote(Macro.escape(fields))

      @doc false
      @spec __es_value_changed__() :: [type: module(), nilable: boolean()]

      def __es_value_changed__, do: @es_value_changed

      @type t :: %__MODULE__{unquote_splicing(read_types)}
      @type write_t :: %__MODULE__{unquote_splicing(write_types)}

      @doc false
      @spec __core_fields__() :: [Core.Field.t()]

      def __core_fields__, do: @core_fields

      @doc "Создать запись изменения значения."
      @spec new(unquote_splicing(Keyword.values(write_types))) :: t()

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

  # ===== интроспекция =====

  @doc false
  @spec declared(module()) :: [type: module(), nilable: boolean()] | nil

  def declared(module) when is_atom(module), do: Module.get_attribute(module, :es_value_changed)

  # Синтетическая декларация `old_value` / `new_value` в IR: у нагрузки нет своей спеки полей, вид
  # задаёт `type:`, но обходчику ПДн и типам нужен тот же состав, что у нагрузки события.
  @doc false
  @spec core_fields(module(), boolean()) :: [Core.Field.t()]

  def core_fields(type, nilable?) when is_atom(type) and is_boolean(nilable?) do
    fields = Core.Field.normalize!(fields(type, nilable?), :payload, "Es.ValueChanged")

    Core.Es.Personal.Plan.entries!(fields, "Es.ValueChanged", uuid_prim: &Core.Es.Event.Payload.uuid_prim?/1)

    fields
  end

  @doc """
  Спека полей `old_value` / `new_value` по типу значения: Prim → `prim:`, `Core.Enum` → `enum:`,
  иначе `entity:`; `nilable: true` → `optional: true`.
  """
  @spec fields(module(), boolean()) :: [Field.t()]

  def fields(type, nilable?) when is_atom(type) and is_boolean(nilable?) do
    {kind, mod} = Field.value_spec(type, "Es.ValueChanged: type")

    Field.normalize!(
      for(name <- ~w(old_value new_value)a, do: {name, [{kind, mod}, optional: nilable?]}),
      :plugin,
      "Es.ValueChanged"
    )
  end
end
