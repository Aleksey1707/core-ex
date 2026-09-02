defmodule Core.Es.ValueChanged do
  @moduledoc """
  Базовый builder struct'а «значение изменено» (old/new).

  Обязательная опция: `type:` — модуль типа значения.
  Опционально: `nilable:` (default `false`) — допускает `nil` для old и new.
  """

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
        raise CompileError, description: "option :type must be a module"
      end

      unless is_boolean(nilable?) do
        raise CompileError, description: "option :nilable must be a boolean"
      end

      @enforce_keys ~w(old_value new_value)a
      defstruct @enforce_keys

      value_type =
        if nilable?,
          do: quote(do: unquote(type_mod).t() | nil),
          else: quote(do: unquote(type_mod).t())

      @type t :: %__MODULE__{old_value: unquote(value_type), new_value: unquote(value_type)}

      @doc "Создать запись изменения значения."
      @spec new(unquote(value_type), unquote(value_type)) :: t()

      if nilable? do
        import Core.Guard, only: [is_opt: 2]

        def new(old_value, new_value)
            when is_opt(old_value, unquote(type_mod)) and is_opt(new_value, unquote(type_mod)) do
          %__MODULE__{old_value: old_value, new_value: new_value}
        end
      else
        def new(%unquote(type_mod){} = old_value, %unquote(type_mod){} = new_value) do
          %__MODULE__{old_value: old_value, new_value: new_value}
        end
      end
    end
  end

  @doc false
  @spec required_keys() :: [atom()]

  def required_keys, do: @required_keys

  @doc false
  @spec optional_keys() :: [atom()]

  def optional_keys, do: @optional_keys
end
