defmodule Core.Result do
  @moduledoc """
  Результат операции: успех со значением (`{:ok, v}`), успех без значения (`:ok`)
  или ошибка (`{:error, reason}`).

  - `{:ok, result} | {:error, reason}` — запросы и операции с payload
  - `:ok | {:error, reason}` — команды CQS без возвращаемого значения
  """

  alias Core.Error
  alias Core.Exc

  @doc "Применить функцию к значению успеха."
  @spec map({:ok, a} | {:error, term()}, (a -> b)) :: {:ok, b} | {:error, term()}
        when a: var, b: var

  def map({:ok, value}, fun), do: ok(fun.(value))
  def map({:error, _reason} = err, _fun), do: err

  @doc """
  Применить функцию к причине ошибки (успех проходит как есть).

  Для обогащения ошибки на границе слоя: `Result.map_error(res, &Error.wrap(outer, &1))`.
  """
  @spec map_error({:ok, a} | :ok | {:error, e}, (e -> f)) :: {:ok, a} | :ok | {:error, f}
        when a: var, e: var, f: var

  def map_error({:error, reason}, fun), do: {:error, fun.(reason)}
  def map_error(ok, _fun), do: ok

  @doc """
  Выполнить побочный эффект над значением успеха и вернуть исходный результат.

  Для логирования в конвейере, где значение менять не нужно.
  """
  @spec tap({:ok, a} | :ok | {:error, e}, (a -> any())) :: {:ok, a} | :ok | {:error, e}
        when a: var, e: var

  def tap({:ok, value} = result, fun) do
    _ = fun.(value)
    result
  end

  def tap(other, _fun), do: other

  @doc "Как `map/2`, иначе вернуть default."
  @spec map_or({:ok, a} | {:error, term()}, b, (a -> b)) :: b when a: var, b: var

  def map_or({:ok, value}, _default, fun), do: fun.(value)
  def map_or({:error, _reason}, default, _fun), do: default

  @doc "Как `map/2`, иначе вычислить default из reason."
  @spec map_or_else({:ok, a} | {:error, e}, (e -> b), (a -> b)) :: b when a: var, b: var, e: var

  def map_or_else({:ok, value}, _default_fun, fun), do: fun.(value)
  def map_or_else({:error, reason}, default_fun, _fun), do: default_fun.(reason)

  @doc "Если первый успешен (`:ok` или `{:ok, _}`), вернуть второй; иначе — ошибку."
  @spec and_(:ok | {:ok, term()} | {:error, term()}, result) :: result when result: var

  def and_(:ok, other), do: other
  def and_({:ok, _value}, other), do: other
  def and_({:error, _reason} = err, _other), do: err

  @doc "Если успех со значением — применить fun."
  @spec and_then({:ok, a} | {:error, term()}, (a -> {:ok, b} | {:error, term()})) ::
          {:ok, b} | {:error, term()}
        when a: var, b: var

  def and_then({:ok, value}, fun), do: fun.(value)
  def and_then({:error, _reason} = err, _fun), do: err

  @doc "Применить fun к каждому элементу; на первой ошибке — halt. Порядок сохраняется."
  @spec traverse([a], (a -> {:ok, b} | {:error, e})) :: {:ok, [b]} | {:error, e}
        when a: var, b: var, e: var

  def traverse(list, fun) when is_list(list) and is_function(fun, 1) do
    list
    |> Enum.reduce_while([], fn item, acc ->
      case fun.(item) do
        {:ok, value} -> {:cont, [value | acc]}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:error, _} = err -> err
      acc -> {:ok, Enum.reverse(acc)}
    end
  end

  @doc "Если успех — вернуть его; иначе — other."
  @spec or_(
          :ok | {:ok, a} | {:error, term()},
          :ok | {:ok, a} | {:error, term()}
        ) :: :ok | {:ok, a} | {:error, term()}
        when a: var

  def or_(:ok, _other), do: :ok
  def or_({:ok, _value} = ok, _other), do: ok
  def or_({:error, _reason}, other), do: other

  @doc "Если успех — вернуть его; иначе вызвать fun."
  @spec or_else(
          :ok | {:ok, a} | {:error, term()},
          (-> :ok | {:ok, a} | {:error, term()})
        ) :: :ok | {:ok, a} | {:error, term()}
        when a: var

  def or_else(:ok, _fun), do: :ok
  def or_else({:ok, _value} = ok, _fun), do: ok
  def or_else({:error, _reason}, fun) when is_function(fun, 0), do: fun.()

  @doc """
  Извлечь значение успеха.

  - `{:error, %Error{}}` → `raise Exc, error`
  - иной `{:error, reason}` → `ArgumentError`
  """
  @spec unwrap!({:ok, a} | {:error, term()}) :: a when a: var

  def unwrap!({:ok, value}), do: value
  def unwrap!({:error, %Error{} = error}), do: raise(Exc, error)

  def unwrap!({:error, reason}) do
    raise ArgumentError, "called Result.unwrap!/1 on error: #{inspect(reason)}"
  end

  @doc "Извлечь значение или raise message."
  @spec expect!({:ok, a} | {:error, term()}, String.t()) :: a when a: var

  def expect!({:ok, value}, _message), do: value
  def expect!({:error, _reason}, message) when is_binary(message), do: raise(message)

  @doc "Значение успеха или default."
  @spec unwrap_or({:ok, a} | {:error, term()}, a) :: a when a: var

  def unwrap_or({:ok, value}, _default), do: value
  def unwrap_or({:error, _reason}, default), do: default

  @doc "Значение успеха или результат fun."
  @spec unwrap_or_else({:ok, a} | {:error, term()}, (-> a)) :: a when a: var

  def unwrap_or_else({:ok, value}, _fun), do: value
  def unwrap_or_else({:error, _reason}, fun) when is_function(fun, 0), do: fun.()

  @doc "Unit-успех без значения (CQS-команда)."
  @spec ok() :: :ok

  def ok, do: :ok

  @doc "Успех со значением."
  @spec ok(a) :: {:ok, a} when a: var

  def ok(value), do: {:ok, value}

  @doc "Ошибка."
  @spec error(a) :: {:error, a} when a: var

  def error(reason), do: {:error, reason}

  @doc "Успех (`:ok` или `{:ok, _}`)?"
  @spec ok?(:ok | {:ok, term()} | {:error, term()}) :: boolean()

  def ok?(:ok), do: true
  def ok?({:ok, _value}), do: true
  def ok?({:error, _reason}), do: false

  @doc "Ошибка?"
  @spec error?(:ok | {:ok, term()} | {:error, term()}) :: boolean()

  def error?({:error, _reason}), do: true
  def error?(:ok), do: false
  def error?({:ok, _value}), do: false

  @doc "В Option (`a | nil`)."
  @spec to_option({:ok, a} | {:error, term()}) :: a | nil when a: var

  def to_option({:ok, value}), do: value
  def to_option({:error, _reason}), do: nil
end
