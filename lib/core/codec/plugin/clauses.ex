defmodule Core.Codec.Plugin.Clauses do
  @moduledoc """
  Разбор ручных клауз Codec-плагина по `Module.get_definition/2` и отказы по ним при сборке.

  Цель клаузы — модуль, на который она матчит первым аргументом:

  | Форма первого аргумента | Цель |
  |---|---|
  | `%Mod{}` (форма `:struct`), `Mod` (форма `:module`) | `Mod` |
  | `%var{}` (`:struct`), `var` (`:module`) с guard `var in [A, B]` или `var === A` | `A`, `B` |
  | то же, условия через `and` | пересечение списков; условие не о модуле список не меняет |
  | несколько `when` | объединение, если список задаёт каждый; иначе `:any` |
  | `left = right` | цель `left`; цель `right` — если `left` даёт `:any` |
  | иное, в том числе переменная без такого guard'а | `:any` |

  Недостижимые ручные клаузы и ручной `@spec` функции, чьи клаузы порождает сборка, —
  `CompileError`.
  """

  # ===== цели =====

  # Ручные клаузы функции → {строка, модуль или :any}. Сгенерированные клаузы — первые
  # `generated`, их порождает `use`. `form` — как первый аргумент называет модуль: `:struct` —
  # паттерном `%Mod{}`, `:module` — литералом. Переменная первого аргумента с guard `var in [...]`
  # даёт запись на каждый модуль списка.
  @doc false
  @spec manual_targets(module(), {atom(), arity()}, non_neg_integer(), :struct | :module) ::
          [{non_neg_integer() | nil, module() | :any}]

  def manual_targets(mod, fun, generated, form) do
    case Module.get_definition(mod, fun) do
      nil ->
        []

      {:v1, _kind, _meta, clauses} ->
        clauses
        |> Enum.drop(generated)
        |> Enum.flat_map(fn {meta, [arg | _rest], guards, _body} ->
          Enum.map(targets(arg, guards, form), &{meta[:line], &1})
        end)
    end
  end

  # ---

  defp targets(arg, guards, form) do
    case target(arg, form) do
      {:var, var} -> guard_targets(var, guards)
      type -> [type]
    end
  end

  defp target({:=, _meta, [left, right]}, form) do
    case target(left, form) do
      :any -> target(right, form)
      type -> type
    end
  end

  defp target({:%, _meta, [type, _fields]}, :struct) when is_atom(type), do: type

  defp target({:%, _meta, [{name, _var_meta, ctx}, _fields]}, :struct) when is_atom(name) and is_atom(ctx),
    do: {:var, {name, ctx}}

  defp target(type, :module) when is_atom(type), do: type
  defp target({name, _meta, ctx}, :module) when is_atom(name) and is_atom(ctx), do: {:var, {name, ctx}}
  defp target(_arg, _form), do: :any

  # Несколько `when` — дизъюнкция: набор известен, только если каждый guard его задаёт.
  defp guard_targets(_var, []), do: [:any]

  defp guard_targets(var, guards) do
    found = Enum.map(guards, &in_guard(&1, var))

    if Enum.all?(found, &match?({:ok, _mods}, &1)),
      do: for({:ok, mods} <- found, mod <- mods, do: mod),
      else: [:any]
  end

  # `var in [A, B]` в guard разворачивается в `orelse` из `=:=`; `and` сужает набор до пересечения,
  # условие не о модуле набор не меняет.
  defp in_guard({{:., _, [:erlang, :"=:="]}, _, [left, right]}, var) do
    case {same_var?(left, var), same_var?(right, var)} do
      {true, false} when is_atom(right) -> {:ok, [right]}
      {false, true} when is_atom(left) -> {:ok, [left]}
      _other -> :error
    end
  end

  defp in_guard({{:., _, [:erlang, :orelse]}, _, [left, right]}, var) do
    with {:ok, l} <- in_guard(left, var), {:ok, r} <- in_guard(right, var), do: {:ok, l ++ r}
  end

  defp in_guard({{:., _, [:erlang, :andalso]}, _, [left, right]}, var) do
    case {in_guard(left, var), in_guard(right, var)} do
      {{:ok, l}, {:ok, r}} -> {:ok, Enum.filter(l, &(&1 in r))}
      {{:ok, mods}, :error} -> {:ok, mods}
      {:error, found} -> found
    end
  end

  defp in_guard(_guard, _var), do: :error

  defp same_var?({name, _meta, ctx}, {name, ctx}), do: true
  defp same_var?(_ast, _var), do: false

  # ===== отказы =====

  # Одна ошибка на все недостижимые клаузы: под `--warnings-as-errors` предупреждение тоже валит
  # сборку, но вывод типов успевает добавить к нему ложные предупреждения о теле такой клаузы.
  @doc false
  @spec raise_never_match!(Macro.Env.t(), [{{atom(), arity()}, non_neg_integer() | nil, module()}], String.t()) ::
          :ok

  def raise_never_match!(_env, [], _reason), do: :ok

  def raise_never_match!(env, [{_fun, line, _type} | _rest] = dead, reason) do
    clauses =
      Enum.map_join(dead, ", ", fn {fun, line, type} -> "#{format(fun)} для #{inspect(type)} (строка #{line})" end)

    raise CompileError,
      description: "#{inspect(env.module)}: ручные клаузы never match — #{clauses}: #{reason}; удалите их",
      file: env.file,
      line: line || env.line
  end

  # Ручная спека — контракт всей функции, включая клаузы, которые порождает сборка: сужая его до
  # своих типов, она ломает вызовы сгенерированных, и сборка этого не видит — только Dialyzer.
  @doc false
  @spec raise_specs!(Macro.Env.t(), [{atom(), arity()}], String.t()) :: :ok

  def raise_specs!(env, funs, reason) do
    case manual_specs(env.module, funs) do
      [] ->
        :ok

      [{_fun, line} | _rest] = specs ->
        listed = Enum.map_join(specs, ", ", fn {fun, line} -> "#{format(fun)} (строка #{line})" end)

        raise CompileError,
          description: "#{inspect(env.module)}: @spec #{listed} — #{reason}; удалите спеку",
          file: env.file,
          line: line || env.line
    end
  end

  # ---

  defp manual_specs(mod, funs) do
    specs =
      for {:spec, expr, _pos} <- Enum.reverse(Module.get_attribute(mod, :spec)),
          {fun, line} = spec_fun(expr),
          fun in funs,
          do: {fun, line}

    Enum.sort_by(specs, &elem(&1, 1))
  end

  defp spec_fun({:when, _meta, [spec, _constraints]}), do: spec_fun(spec)
  defp spec_fun({:"::", _meta, [{name, meta, args}, _result]}), do: {{name, length(List.wrap(args))}, meta[:line]}
  defp spec_fun(_malformed), do: {nil, nil}

  defp format({name, arity}), do: "#{name}/#{arity}"
end
