defmodule Core.Option do
  @moduledoc """
  Опциональное значение: `a | nil`.

  Конверсии в Result:
  - `to_result/1` — когда нужен payload (`{:ok, v}`)
  - `to_unit/1` — когда достаточно факта наличия (CQS, `:ok`)
  """

  alias Core.Result

  @doc "Применить функцию к значению; `nil` → `nil`."
  @spec map(nil, (term() -> term())) :: nil
  @spec map(term(), (term() -> term())) :: term()

  def map(nil, fun) when is_function(fun, 1), do: nil
  def map(value, fun) when is_function(fun, 1), do: fun.(value)

  @doc "Значение присутствует (`не nil`)?"
  @spec some?(term() | nil) :: boolean()

  def some?(nil), do: false
  def some?(_value), do: true

  @doc "Значение или `other`, если `nil`."
  @spec or_(a | nil, a | nil) :: a | nil when a: var

  def or_(nil, other), do: other
  def or_(value, _other), do: value

  @doc "Значение или результат `fun`, если `nil`."
  @spec or_else(a | nil, (-> a | nil)) :: a | nil when a: var

  def or_else(nil, fun) when is_function(fun, 0), do: fun.()
  def or_else(value, _fun), do: value

  @doc "Значение или default, если `nil`."
  @spec unwrap_or(a | nil, a) :: a when a: var

  def unwrap_or(nil, default), do: default
  def unwrap_or(value, _default), do: value

  @doc "Значение или результат `fun`, если `nil`."
  @spec unwrap_or_else(a | nil, (-> a)) :: a when a: var

  def unwrap_or_else(nil, fun) when is_function(fun, 0), do: fun.()
  def unwrap_or_else(value, _fun), do: value

  @doc "Извлечь значение; на `nil` — `ArgumentError`."
  @spec unwrap!(a | nil) :: a when a: var

  def unwrap!(nil), do: raise(ArgumentError, "called Option.unwrap!/1 on a nil value")
  def unwrap!(value), do: value

  @doc "Извлечь значение или raise message."
  @spec expect!(a | nil, String.t()) :: a when a: var

  def expect!(nil, message) when is_binary(message), do: raise(message)
  def expect!(value, _message), do: value

  @doc "В valued Result: значение → `{:ok, value}`, nil → `{:error, :none}`."
  @spec to_result(a | nil) :: {:ok, a} | {:error, :none} when a: var

  def to_result(nil), do: Result.error(:none)
  def to_result(value), do: Result.ok(value)

  @doc "В unit Result: значение → `:ok`, nil → `{:error, :none}` (CQS)."
  @spec to_unit(term() | nil) :: :ok | {:error, :none}

  def to_unit(nil), do: Result.error(:none)
  def to_unit(_value), do: Result.ok()
end
