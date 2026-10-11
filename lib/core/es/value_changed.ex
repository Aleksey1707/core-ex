defmodule Core.Es.ValueChanged do
  @moduledoc """
  Базовый builder struct'а «значение изменено» (old/new).

  Обязательная опция: `type:` — модуль типа значения: Prim, `Core.Enum` или struct сущности.
  Опционально: `nilable:` (default `false`) — допускает `nil` для old и new.

  Порождаются `@enforce_keys`, `defstruct`, `@type t` и `new/2`, чья голова закрывает вид
  значения: `%Type{}` у Prim и сущности, атом у enum, `nil` при `nilable: true`.

  `__es_value_changed__/0` отдаёт `type:` и `nilable:`: по ним `Core.Es.Event.Codec` выводит
  клаузы нагрузки события с такой нагрузкой — map
  `%{"old_value" => …, "new_value" => …}`, значения по виду типа (`fields/2`).
  """

  alias Core.Codec.Plugin.Fields
  alias Core.Helper

  @required_keys ~w(type)a
  @optional_keys ~w(nilable)a

  @doc "Объявить struct old/new (`type:` / опционально `nilable:`)."
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Helper.Opts.validate!(
        opts,
        Core.Es.ValueChanged.required_keys(),
        Core.Es.ValueChanged.optional_keys(),
        "Es.ValueChanged"
      )

      type_mod = Keyword.fetch!(opts, :type)
      nilable? = Keyword.get(opts, :nilable, false)

      unless is_atom(type_mod) do
        raise CompileError, description: "Es.ValueChanged: :type должен быть модулем"
      end

      unless is_boolean(nilable?) do
        raise CompileError, description: "Es.ValueChanged: :nilable должен быть boolean"
      end

      fields = Core.Es.ValueChanged.fields(type_mod, nilable?)

      @enforce_keys ~w(old_value new_value)a
      defstruct @enforce_keys

      @type t :: %__MODULE__{unquote_splicing(Core.Codec.Plugin.Fields.typespec(fields))}

      @doc false
      @spec __es_value_changed__() :: [type: module(), nilable: boolean()]

      def __es_value_changed__, do: [type: unquote(type_mod), nilable: unquote(nilable?)]

      @doc "Создать запись изменения значения."
      @spec new(unquote_splicing(Keyword.values(Core.Codec.Plugin.Fields.typespec(fields)))) :: t()

      def new(unquote_splicing(Core.Codec.Plugin.Fields.new_args(fields)))
          when unquote(Core.Codec.Plugin.Fields.new_guard(fields)),
          do: unquote(Core.Codec.Plugin.Fields.new_body(__MODULE__, fields))
    end
  end

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys

  @doc """
  Спека полей `old_value` / `new_value` по типу значения: Prim → `prim:`, `Core.Enum` → `enum:`,
  иначе `entity:`; `nilable: true` → `optional: true`.
  """
  @spec fields(module(), boolean()) :: [Fields.field()]

  def fields(type, nilable?) when is_atom(type) and is_boolean(nilable?) do
    spec = Fields.value_spec(type, "Es.ValueChanged: type:")

    for name <- ~w(old_value new_value)a, do: {name, spec, nilable?, Atom.to_string(name), :none}
  end
end
