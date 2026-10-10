defmodule Core.Codec.Plugin.Opts do
  @moduledoc """
  Валидация опций `use Core.Codec.Plugin` и проверка контракта после компиляции.

  Проверяет форму `types:` и `union:` и после компиляции — что каждый тип плагина
  обслужен `dump/2` (и `load/3` при `loadable: true`, вместе с семейством `union:`):
  клаузой по `fields:` или ручной. Ручная клауза на тип из `fields:` — предупреждение.
  """

  # ===== опции =====

  @doc false
  @spec types!(keyword()) :: [module()]

  def types!(opts) do
    case Keyword.get(opts, :types) do
      types when is_list(types) and types != [] ->
        validate_modules!(types)

      other ->
        raise CompileError,
          description: "types: ожидается непустой список модулей, получено: #{inspect(other)}"
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
  @spec after_compile!(Macro.Env.t(), binary()) :: :ok

  def after_compile!(env, _bytecode) do
    mod = env.module
    generated = Enum.map(Module.get_attribute(mod, :codec_fields), &elem(&1, 0))
    types = Module.get_attribute(mod, :codec_types)

    # `dump/2` обязателен для каждого типа: фасад уже завёл clause на каждый тип плагина,
    # и без клаузы она упала бы `FunctionClauseError` на первом дампе.
    check_clauses!(env, {:dump, 2}, types, generated)

    if Module.get_attribute(mod, :codec_loadable) do
      check_clauses!(env, {:load, 3}, types ++ List.wrap(Module.get_attribute(mod, :codec_union)), generated)
    end

    :ok
  end

  # ---

  defp check_clauses!(env, {name, _arity} = fun, required, generated) do
    manual = manual_targets(env.module, fun, length(generated), if(name == :dump, do: :struct, else: :module))

    warn_never_match(env, fun, manual, generated)
    check_covered!(env, fun, required, generated, Enum.map(manual, &elem(&1, 1)))
  end

  # Клаузы `fields:` встают первыми (их порождает `use`), поэтому ручная клауза на такой тип
  # недостижима для валидного значения и молча ловила бы только невалидное.
  defp warn_never_match(env, {name, arity}, manual, generated) do
    for {line, type} <- manual, type in generated do
      IO.warn(
        "клауза never match: #{name}/#{arity} для #{inspect(type)} сгенерирован по fields: плагина " <>
          inspect(env.module),
        file: env.file,
        line: line
      )
    end
  end

  # Ручная клауза с первым аргументом не литералом типа может принять любой тип плагина.
  defp check_covered!(env, {name, arity}, required, generated, targets) do
    uncovered = if :any in targets, do: [], else: (required -- generated) -- targets

    if uncovered != [] do
      raise CompileError,
        description:
          "#{inspect(env.module)}: плагину требуется #{name}/#{arity} для #{inspect(uncovered)} — " <>
            "их нет ни в fields:, ни в ручных клаузах",
        file: env.file,
        line: env.line
    end
  end

  defp validate_modules!(types) do
    if not Enum.all?(types, &(is_atom(&1) and not is_nil(&1))) do
      raise CompileError, description: "types: ожидается непустой список модулей"
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

  # Ручные клаузы функции → {строка, модуль первого аргумента или :any}. Сгенерированные клаузы —
  # первые `generated`, их порождает `use`. `form` — как первый аргумент называет модуль:
  # `:struct` — паттерном `%Mod{}`, `:module` — литералом.
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
        |> Enum.map(fn {meta, [arg | _rest], _guards, _body} -> {meta[:line], target(arg, form)} end)
    end
  end

  # ---

  defp target({:=, _meta, [left, right]}, form) do
    case target(left, form) do
      :any -> target(right, form)
      type -> type
    end
  end

  defp target({:%, _meta, [type, _fields]}, :struct) when is_atom(type), do: type
  defp target(type, :module) when is_atom(type), do: type
  defp target(_arg, _form), do: :any
end
