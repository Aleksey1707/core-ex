defmodule Core.Mutator do
  @moduledoc """
  Контракт и диспетчер мутаторов Prim.

  Спецификация мутатора — `{Module, opts}`, `fun/1`, `fun/2` или `nil`; `run/3` выбирает
  форму. Результат — новое значение, `{:ok, value}` либо `{:error, {code, detail}}`,
  который `Prim` заворачивает в `%Error{kind: :domain}`.

  Зеркало `Core.Validator`: мутатор меняет значение конвейера, валидатор только проверяет
  его. Формы спецификации у них одни и те же — `mutate:` и `validate:` в `use Prim`
  читаются одинаково, а список любой из форм разворачивает `Core.Prim`.
  """

  @type code :: atom()
  @type detail :: String.t()
  @type result :: term() | {:ok, term()} | {:error, {code(), detail()}}
  @type mutate_spec ::
          {module(), keyword()}
          | (term() -> result())
          | (term(), keyword() -> result())
          | nil

  @callback mutate(value :: term(), opts :: keyword()) :: result()

  @doc "Запустить мутатор (модуль, функция или nil)."
  @spec run(mutate_spec(), term(), keyword()) :: result()

  def run({module, opts}, value, _opts) when is_atom(module) do
    module.mutate(value, opts)
  end

  def run(fun, value, opts) when is_function(fun, 2) do
    fun.(value, opts)
  end

  def run(fun, value, _opts) when is_function(fun, 1) do
    fun.(value)
  end

  def run(nil, value, _opts), do: value
end
