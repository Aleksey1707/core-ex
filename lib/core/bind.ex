defmodule Core.Bind do
  @moduledoc """
  `bind/1` — аналог `use` из Gleam: последовательность строк вместо лестницы колбэков.

  Снимает вложенность у bracket-функций (`File.open/3`, `Core.Helper.Transact.run/3`,
  `Agent.get_and_update/3`, `:timer.tc/1`), где колбэк — последний аргумент, а тело
  следующего шага живёт внутри него.

      import Core.Bind

      bind do
        io <- File.open(path, [:read])
        [] <- :timer.tc()
        IO.read(io, :line)
      end

  Раскрывается в `File.open(path, [:read], fn io -> :timer.tc(fn -> IO.read(io, :line) end) end)`.

  Форма слева от `<-` задаёт параметры колбэка:

  | Слева | Колбэк |
  |---|---|
  | `x`, `{:ok, x}` | `fn x ->` — паттерн как есть |
  | `[]` | `fn ->` — нуль-арный (`Transact.run`, `:timer.tc`) |
  | `[a, b]` | `fn a, b ->` |

  Одноэлементный список равен голому паттерну: `[io] <-` и `io <-` дают одну и ту же `fn io ->`.
  Список-паттерн слева поэтому оборачивается в список параметров: `[[a, b]] <-` — это
  `fn [a, b] ->`, а `[a, b] <-` — `fn a, b ->`.

  Колбэк дописывается последним аргументом; если среди аргументов вызова есть `_`, он встаёт
  на его место — так проходят функции с хвостом после колбэка (`Transact.run(DAO, _, opts)`).
  Маркер читается только на верхнем уровне аргументов: `f(%{a: _})` — не позиция колбэка,
  а `invalid use of _` от компилятора.
  Pipe справа разворачивается в обычный вызов, колбэк получает последнее звено цепочки.

  Строка без `<-` остаётся выражением на своём месте; там же допустим вложенный `bind`.
  Справа от `<-` `bind` стоять не может: там ожидается вызов, принимающий колбэк
  последним аргументом.

  Промах паттерна слева — `FunctionClauseError` из сгенерированной `fn`: `else` у `bind` нет
  и не будет, ветвление по ошибке — дело `with`.

  Когда `bind` не нужен: цепочка `{:ok, _} | {:error, _}` — это `with` (у него есть `else`),
  а шаг, которому подходит имя, — приватная функция: имя объясняет шаг, `bind` — нет.
  Плата за макрос — стектрейсы указывают внутрь сгенерированных `fn`, а вызов, который колбэка
  не принимает, макрос пропускает: арность разойдётся сообщением компилятора или
  `UndefinedFunctionError` в рантайме.
  """

  @non_call ~w(__aliases__ __block__ {} %{} % <<>> fn & :: -> when)a

  @doc """
  Развернуть блок в цепочку колбэков.

  `CompileError`: блок с `else` / `rescue` / `after`, `<-` последним выражением блока,
  справа от `<-` не вызов функции (литерал, алиас, оператор, форма с `do`-блоком),
  больше одного маркера `_` среди аргументов вызова.
  """
  defmacro bind(do: block) do
    block
    |> exprs()
    |> build(__CALLER__)
  end

  defmacro bind(opts) when is_list(opts) do
    abort(
      [],
      __CALLER__,
      "принимается только `do`-блок, получено: #{inspect(Keyword.keys(opts))} — " <>
        "ветвление по ошибке даёт `with` с `else`, не `bind`"
    )
  end

  # ---

  defp exprs({:__block__, _meta, list}), do: list
  defp exprs(expr), do: [expr]

  defp build([], _caller), do: {:__block__, [], []}

  defp build([{:<-, meta, [_lhs, _rhs]}], caller) do
    abort(meta, caller, "`<-` не может быть последним выражением блока — связывать нечего")
  end

  defp build([{:<-, meta, [lhs, rhs]} | rest], caller) do
    callback = {:fn, meta, [{:->, meta, [params(lhs), build(rest, caller)]}]}

    rhs
    |> unpipe()
    |> insert(callback, meta, caller)
  end

  defp build([expr], _caller), do: expr
  defp build([expr | rest], caller), do: {:__block__, [], [expr, build(rest, caller)]}

  defp params({:when, meta, [patterns, guard]}) when is_list(patterns) do
    [{:when, meta, patterns ++ [guard]}]
  end

  defp params(patterns) when is_list(patterns), do: patterns
  defp params(pattern), do: [pattern]

  defp unpipe({:|>, _meta, _args} = pipe) do
    [{first, _pos} | rest] = Macro.unpipe(pipe)

    Enum.reduce(rest, first, fn {ast, pos}, acc -> Macro.pipe(acc, ast, pos) end)
  end

  defp unpipe(ast), do: ast

  defp insert({{:., _dot_meta, _target} = fun, call_meta, args}, callback, meta, caller)
       when is_list(args) do
    {fun, call_meta, callback_args(args, callback, meta, caller)}
  end

  defp insert({fun, call_meta, args}, callback, meta, caller)
       when is_atom(fun) and is_list(args) and fun not in @non_call do
    case form_kind(fun, length(args)) do
      nil -> {fun, call_meta, callback_args(args, callback, meta, caller)}
      kind -> abort(meta, caller, "справа от `<-` ожидается вызов функции, а не #{kind}")
    end
  end

  defp insert(other, _callback, meta, caller) do
    abort(
      meta,
      caller,
      "справа от `<-` ожидается вызов функции, получено: #{Macro.to_string(other)}"
    )
  end

  defp form_kind(fun, arity) do
    cond do
      Macro.operator?(fun, arity) -> "оператор `#{fun}`"
      sigil?(fun) -> "сигил"
      true -> nil
    end
  end

  defp sigil?(fun), do: String.starts_with?(Atom.to_string(fun), "sigil_")

  defp callback_args(args, callback, meta, caller) do
    if block_form?(args),
      do: abort(meta, caller, "справа от `<-` ожидается вызов функции, а не форма с `do`-блоком")

    put_callback(args, callback, meta, caller)
  end

  defp block_form?([]), do: false

  defp block_form?(args) do
    case List.last(args) do
      [{key, _value} | _rest] = last when is_atom(key) -> Keyword.has_key?(last, :do)
      _other -> false
    end
  end

  defp put_callback(args, callback, meta, caller) do
    case Enum.count(args, &placeholder?/1) do
      0 -> args ++ [callback]
      1 -> Enum.map(args, &replace_placeholder(&1, callback))
      _more -> abort(meta, caller, "маркер `_` среди аргументов вызова допустим только один")
    end
  end

  defp replace_placeholder(arg, callback), do: if(placeholder?(arg), do: callback, else: arg)

  defp placeholder?({:_, _meta, context}) when is_atom(context), do: true
  defp placeholder?(_arg), do: false

  defp abort(meta, caller, description) do
    raise CompileError,
      file: caller.file,
      line: Keyword.get(meta, :line, caller.line),
      description: "Core.Bind: " <> description
  end
end
