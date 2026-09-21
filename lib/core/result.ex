defmodule Core.Result do
  @moduledoc """
  Результат операции: успех со значением (`{:ok, v}`), успех без значения (`:ok`)
  или ошибка (`{:error, reason}`).

  - `t:t/0`, `t:t/1`, `t:t/2` — `{:ok, result} | {:error, reason}`: запросы и операции с payload
  - `t:unit/0`, `t:unit/1` — `:ok | {:error, reason}`: команды CQS без возвращаемого значения

  Valued-результат (`t:t/2`) несёт значение, unit-результат (`t:unit/1`) — только факт, и
  функция, которой значение нужно, на `:ok` даёт `FunctionClauseError`: применять нечего.

  | Вход | Функции |
  |---|---|
  | `t:t/2` и `t:unit/1` | `map_error/2`, `tap/2`, `and_/2`, `or_/2`, `or_else/2`, `ok?/1`, `error?/1` |
  | только `t:t/2` — колбэк к значению | `map/2`, `map_or/3`, `map_or_else/3`, `and_then/2` |
  | только `t:t/2` — значение наружу | `unwrap!/1`, `unwrap_or/2`, `unwrap_or_else/2`, `to_option/1` |
  | результата на входе нет | `ok/0`, `ok/1`, `error/1`, `traverse/2`, `traverse_all/2` |
  """

  alias Core.Error
  alias Core.Exc
  alias Core.Option

  @typedoc """
  Результат со значением: успех несёт `a`, ошибка — причину `e`.

  Двухпараметрическая форма берётся там, где причина не `%Error{}`: комбинаторы этого модуля
  пропускают reason любой формы, `Core.Option.to_result/1` отдаёт `:none`, `Core.Validator` —
  `{code, detail}`.
  """
  @type t(a, e) :: {:ok, a} | {:error, e}

  @typedoc "Результат со значением `a` и ошибкой библиотеки — частый случай на границах домена."
  @type t(a) :: t(a, Error.t())

  @typedoc "Результат с произвольным значением и ошибкой библиотеки."
  @type t :: t(term(), Error.t())

  @typedoc """
  Unit-результат CQS-команды: успех без значения или ошибка причины `e`.

  Параметризованная форма — по тому же поводу, что у `t/2`: причина не `%Error{}`.
  """
  @type unit(e) :: :ok | {:error, e}

  @typedoc "Unit-результат с ошибкой библиотеки."
  @type unit :: unit(Error.t())

  @doc """
  Применить функцию к значению успеха.

  Результат, который вернул колбэк, вкладывается как значение (`{:ok, {:ok, v}}`) — для
  связывания результатов нужен `and_then/2`.
  """
  @spec map(t(a, e), (a -> b)) :: t(b, e) when a: var, b: var, e: var

  def map({:ok, value}, fun) when is_function(fun, 1), do: ok(fun.(value))
  def map({:error, _reason} = err, fun) when is_function(fun, 1), do: err

  @doc """
  Применить функцию к причине ошибки (успех проходит как есть).

  Для обогащения ошибки на границе слоя: `Result.map_error(res, &Error.wrap(outer, &1))`.
  """
  @spec map_error(t(a, e) | unit(e), (e -> f)) :: t(a, f) | unit(f) when a: var, e: var, f: var

  def map_error({:error, reason}, fun) when is_function(fun, 1), do: {:error, fun.(reason)}
  def map_error({:ok, _value} = ok, fun) when is_function(fun, 1), do: ok
  def map_error(:ok, fun) when is_function(fun, 1), do: :ok

  @doc """
  Выполнить побочный эффект над значением успеха и вернуть исходный результат.

  Для логирования в конвейере, где значение менять не нужно.
  """
  @spec tap(t(a, e) | unit(e), (a -> any())) :: t(a, e) | unit(e) when a: var, e: var

  def tap({:ok, value} = result, fun) when is_function(fun, 1) do
    _ = fun.(value)
    result
  end

  def tap({:error, _reason} = err, fun) when is_function(fun, 1), do: err
  def tap(:ok, fun) when is_function(fun, 1), do: :ok

  @doc "Как `map/2`, иначе вернуть default."
  @spec map_or(t(a, term()), b, (a -> b)) :: b when a: var, b: var

  def map_or({:ok, value}, _default, fun) when is_function(fun, 1), do: fun.(value)
  def map_or({:error, _reason}, default, fun) when is_function(fun, 1), do: default

  @doc "Как `map/2`, иначе вычислить default из reason."
  @spec map_or_else(t(a, e), (e -> b), (a -> b)) :: b when a: var, b: var, e: var

  def map_or_else({:ok, value}, default_fun, fun)
      when is_function(default_fun, 1) and is_function(fun, 1),
      do: fun.(value)

  def map_or_else({:error, reason}, default_fun, fun)
      when is_function(default_fun, 1) and is_function(fun, 1),
      do: default_fun.(reason)

  @doc "Если первый успешен (`:ok` или `{:ok, _}`), вернуть второй; иначе — ошибку."
  @spec and_(t(term(), term()) | unit(term()), result) :: result when result: var

  def and_(:ok, other), do: other
  def and_({:ok, _value}, other), do: other
  def and_({:error, _reason} = err, _other), do: err

  @doc "Если успех со значением — применить fun."
  @spec and_then(t(a, e), (a -> t(b, f))) :: t(b, e | f) when a: var, b: var, e: var, f: var

  def and_then({:ok, value}, fun) when is_function(fun, 1), do: fun.(value)
  def and_then({:error, _reason} = err, fun) when is_function(fun, 1), do: err

  @doc "Применить fun к каждому элементу; на первой ошибке — halt. Порядок сохраняется."
  @spec traverse([a], (a -> t(b, e))) :: t([b], e) when a: var, b: var, e: var

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

  @doc """
  Применить fun к каждому элементу; пройти список целиком и собрать все провалы.

  Порядок значений и порядок провалов — порядок входа.

  Голый список наружу не отдаётся: он заворачивается в `Error.many/1,2` в теле той же
  функции — `ns`, `code` и общий `message` знает только call site.

      def validate_rows(rows) do
        rows
        |> Result.traverse_all(&validate/1)
        |> Result.map_error(
          &Error.many(code: :invalid, ns: :form, message: "Форма невалидна", errors: &1)
        )
      end
  """
  @spec traverse_all([a], (a -> t(b))) :: t([b], [Error.t()]) when a: var, b: var

  def traverse_all(list, fun) when is_list(list) and is_function(fun, 1) do
    {values, errors} =
      Enum.reduce(list, {[], []}, fn item, {values, errors} ->
        case fun.(item) do
          {:ok, value} -> {[value | values], errors}
          {:error, reason} -> {values, [reason | errors]}
        end
      end)

    if errors == [],
      do: {:ok, Enum.reverse(values)},
      else: {:error, Enum.reverse(errors)}
  end

  @doc "Если успех — вернуть его; иначе — other."
  @spec or_(t(a, e) | unit(e), t(a, e) | unit(e)) :: t(a, e) | unit(e) when a: var, e: var

  def or_(:ok, _other), do: :ok
  def or_({:ok, _value} = ok, _other), do: ok
  def or_({:error, _reason}, other), do: other

  @doc "Если успех — вернуть его; иначе вызвать fun."
  @spec or_else(t(a, e) | unit(e), (-> t(a, e) | unit(e))) :: t(a, e) | unit(e) when a: var, e: var

  def or_else(:ok, fun) when is_function(fun, 0), do: :ok
  def or_else({:ok, _value} = ok, fun) when is_function(fun, 0), do: ok
  def or_else({:error, _reason}, fun) when is_function(fun, 0), do: fun.()

  @doc """
  Извлечь значение успеха.

  - `{:error, %Error{}}` → `raise Exc, error`
  - иной `{:error, reason}` → `ArgumentError`
  """
  @spec unwrap!(t(a, term())) :: a when a: var

  def unwrap!({:ok, value}), do: value
  def unwrap!({:error, %Error{} = error}), do: raise(Exc, error)

  def unwrap!({:error, reason}) do
    raise ArgumentError, "Result.unwrap!/1 вызван на ошибке: #{inspect(reason)}"
  end

  @doc "Значение успеха или default."
  @spec unwrap_or(t(a, term()), a) :: a when a: var

  def unwrap_or({:ok, value}, _default), do: value
  def unwrap_or({:error, _reason}, default), do: default

  @doc "Значение успеха или результат fun."
  @spec unwrap_or_else(t(a, term()), (-> a)) :: a when a: var

  def unwrap_or_else({:ok, value}, fun) when is_function(fun, 0), do: value
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
  @spec ok?(t(term(), term()) | unit(term())) :: boolean()

  def ok?(:ok), do: true
  def ok?({:ok, _value}), do: true
  def ok?({:error, _reason}), do: false

  @doc "Ошибка?"
  @spec error?(t(term(), term()) | unit(term())) :: boolean()

  def error?({:error, _reason}), do: true
  def error?(:ok), do: false
  def error?({:ok, _value}), do: false

  @doc "В Option (`a | nil`)."
  @spec to_option(t(a, term())) :: Option.t(a) when a: var

  def to_option({:ok, value}), do: value
  def to_option({:error, _reason}), do: nil
end
