defmodule Core.Codec.Plugin.Opts do
  @moduledoc """
  Валидация опций `use Core.Codec.Plugin` и проверка контракта перед сборкой модуля.

  Проверяет форму `types:` и `union:`, что тип объявлен ровно одной из `types:` / `fields:` /
  `variants:`, и перед сборкой — что каждый ручной тип обслужен `dump/2` (и `load/3` при
  `loadable: true`, вместе с семейством `union:` без `variants:`) ручной клаузой, а ручной вариант —
  колбэками `dump_variant/2` / `load_variant/3`. Ручная клауза на сгенерированный тип или семейство и
  `@spec` у `dump/2` / `load/3` плагина с `fields:` или `variants:` — `CompileError`.
  """

  # ===== опции =====

  @doc false
  @spec types!(keyword()) :: [module()]

  def types!(opts) do
    case Keyword.get(opts, :types, []) do
      types when is_list(types) ->
        validate_modules!(types)

      other ->
        raise CompileError, description: "types: ожидается список модулей, получено: #{inspect(other)}"
    end
  end

  @doc false
  @spec all_types!(module(), [[module()]]) :: [module()]

  def all_types!(plugin, groups) do
    all = Enum.concat(groups)

    case {all, all -- Enum.uniq(all)} do
      {[], _dupes} ->
        raise CompileError,
          description: "Codec.Plugin #{inspect(plugin)}: нет типов — задайте types:, fields: или variants:"

      {all, []} ->
        all

      {_all, dupes} ->
        raise CompileError,
          description:
            "Codec.Plugin #{inspect(plugin)}: типы объявлены в нескольких опциях: #{inspect(Enum.uniq(dupes))} — " <>
              "types: только для ручных типов"
    end
  end

  @doc false
  @spec union!(keyword(), boolean()) :: module() | nil

  def union!(opts, loadable?) do
    case Keyword.get(opts, :union) do
      nil -> nil
      union -> validate_union!(union, loadable?)
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    mod = env.module
    variants = Module.get_attribute(mod, :codec_variants)
    union = Module.get_attribute(mod, :codec_union)
    dumped = Enum.map(Module.get_attribute(mod, :codec_fields), &elem(&1, 0)) ++ Enum.map(variants, &elem(&1, 0))
    loaded = if variants == [], do: dumped, else: dumped ++ [union]
    generated = if Module.get_attribute(mod, :codec_loadable), do: [dump: dumped, load: loaded], else: [dump: dumped]
    funs = Enum.map(generated, fn {name, _types} -> {name, arity(name)} end)

    if dumped != [] do
      raise_never_match!(env, never_match(env, generated), "тип сгенерирован по fields: или variants:")
      raise_specs!(env, funs, "у плагина с fields: или variants: контракт задаёт @callback Core.Codec.Plugin")
    end

    # `dump/2` обязателен для каждого типа: фасад уже завёл clause на каждый тип плагина,
    # и без клаузы она упала бы `FunctionClauseError` на первом дампе.
    types = Module.get_attribute(mod, :codec_types)
    reason = "их нет ни в fields:, ни в variants:, ни в ручных клаузах"
    check_covered!(env, {:dump, 2}, types, dumped, reason)

    if Module.get_attribute(mod, :codec_loadable) do
      check_covered!(env, {:load, 3}, types ++ List.wrap(union), loaded, reason)
    end

    manual = for {variant, _address, _place, :manual} <- variants, do: variant
    check_covered!(env, {:dump_variant, 2}, manual, [], "ручной вариант без колбэка")
    check_covered!(env, {:load_variant, 3}, manual, [], "ручной вариант без колбэка")

    nil
  end

  # ---

  defp arity(:dump), do: 2
  defp arity(:load), do: 3

  # Клаузы `fields:` и `variants:` встают первыми (их порождает `use`), поэтому ручная клауза на
  # такой тип недостижима для валидного значения и молча ловила бы только невалидное.
  defp never_match(env, generated) do
    for {name, types} <- generated,
        fun = {name, arity(name)},
        {line, type} <- manual_targets(env.module, fun, length(types), form(name)),
        type in types,
        do: {fun, line, type}
  end

  defp form(name) when name in ~w(dump dump_variant)a, do: :struct
  defp form(name) when name in ~w(load load_variant)a, do: :module

  # Ручная клауза с первым аргументом не литералом типа может принять любой тип плагина.
  defp check_covered!(env, {name, arity} = fun, required, generated, reason) do
    targets = Enum.map(manual_targets(env.module, fun, length(generated), form(name)), &elem(&1, 1))
    uncovered = if :any in targets, do: [], else: (required -- generated) -- targets

    if uncovered != [] do
      raise CompileError,
        description: "#{inspect(env.module)}: плагину требуется #{name}/#{arity} для #{inspect(uncovered)} — #{reason}",
        file: env.file,
        line: env.line
    end
  end

  defp validate_modules!(types) do
    if not Enum.all?(types, &(is_atom(&1) and not is_nil(&1))) do
      raise CompileError, description: "types: ожидается список модулей"
    end

    types
  end

  # Семейство существует ради `load/3`: у dump-only плагина восстанавливать нечем,
  # и клоуза фасада для него была бы обещанием, которого плагин не выполняет.
  defp validate_union!(union, false) when is_atom(union) do
    raise CompileError, description: "union: требует loadable: true"
  end

  defp validate_union!(union, _loadable?) when is_atom(union) and not is_nil(union), do: union

  defp validate_union!(other, _loadable?) do
    raise CompileError, description: "union: ожидается модуль, получено: #{inspect(other)}"
  end

  # ===== ручные клаузы =====

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
end
