defmodule Core.Option do
  @moduledoc """
  Опциональное значение: `a | nil`.

  Конверсии в Result:
  - `to_result/1` — когда нужен payload (`{:ok, v}`)
  - `to_unit/1` — когда достаточно факта наличия (CQS, `:ok`)
  """

  alias Core.Result

  @typedoc "Опциональное значение: `a` либо его отсутствие."
  @type t(a) :: a | nil

  @typedoc "Опциональное значение произвольного типа."
  @type t :: t(term())

  @doc "Применить функцию к значению; `nil` → `nil`."
  @spec map(nil, (term() -> term())) :: nil
  @spec map(t(a), (a -> b)) :: t(b) when a: var, b: var

  def map(nil, fun) when is_function(fun, 1), do: nil
  def map(value, fun) when is_function(fun, 1), do: fun.(value)

  @doc "Значение присутствует (`не nil`)?"
  @spec some?(t()) :: boolean()

  def some?(nil), do: false
  def some?(_value), do: true

  @doc "Значение или `other`, если `nil`."
  @spec or_(t(a), t(a)) :: t(a) when a: var

  def or_(nil, other), do: other
  def or_(value, _other), do: value

  @doc "Значение или результат `fun`, если `nil`."
  @spec or_else(t(a), (-> t(a))) :: t(a) when a: var

  def or_else(nil, fun) when is_function(fun, 0), do: fun.()
  def or_else(value, fun) when is_function(fun, 0), do: value

  @doc "Значение или default, если `nil`."
  @spec unwrap_or(t(a), a) :: a when a: var

  def unwrap_or(nil, default), do: default
  def unwrap_or(value, _default), do: value

  @doc "Значение или результат `fun`, если `nil`."
  @spec unwrap_or_else(t(a), (-> a)) :: a when a: var

  def unwrap_or_else(nil, fun) when is_function(fun, 0), do: fun.()
  def unwrap_or_else(value, fun) when is_function(fun, 0), do: value

  @doc "Извлечь значение; на `nil` — `ArgumentError`."
  @spec unwrap!(t(a)) :: a when a: var

  def unwrap!(nil), do: raise(ArgumentError, "Option.unwrap!/1 вызван на nil")
  def unwrap!(value), do: value

  @doc "В valued Result: значение → `{:ok, value}`, nil → `{:error, :none}`."
  @spec to_result(t(a)) :: Result.t(a, :none) when a: var

  def to_result(nil), do: Result.error(:none)
  def to_result(value), do: Result.ok(value)

  @doc "В unit Result: значение → `:ok`, nil → `{:error, :none}` (CQS)."
  @spec to_unit(t()) :: Result.unit(:none)

  def to_unit(nil), do: Result.error(:none)
  def to_unit(_value), do: Result.ok()
end
