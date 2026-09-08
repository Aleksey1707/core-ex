defmodule Core.Validator do
  @moduledoc """
  Контракт и диспетчер валидаторов Prim.

  Спецификация валидатора — `{Module, opts}`, `fun/1`, `fun/2` или `nil`; `run/3`
  выбирает форму. Результат — `:ok` либо `{:error, {code, detail}}`, который `Prim`
  заворачивает в `%Error{kind: :domain}`.

  Зеркало `Core.Mutator`: формы спецификации у них одни и те же, а список любой из
  форм разворачивает `Core.Prim`.
  """

  @type code :: atom()
  @type detail :: String.t()
  @type result :: :ok | {:error, {code(), detail()}}
  @type validate_spec ::
          {module(), keyword()}
          | (term() -> result())
          | (term(), keyword() -> result())
          | nil

  @callback validate(value :: term(), opts :: keyword()) :: result()

  @doc "Запустить валидатор (модуль, функция или nil)."
  @spec run(validate_spec(), term(), keyword()) :: result()

  def run({module, opts}, value, _opts) when is_atom(module) do
    module.validate(value, opts)
  end

  def run(fun, value, opts) when is_function(fun, 2) do
    fun.(value, opts)
  end

  def run(fun, value, _opts) when is_function(fun, 1) do
    fun.(value)
  end

  def run(nil, _value, _opts), do: :ok
end
