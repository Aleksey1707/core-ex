defmodule Core.Codec.Plugin.Opts do
  @moduledoc """
  Валидация опций `use Core.Codec.Plugin` и проверка контракта перед сборкой модуля.

  Проверяет форму `types:` и `union:`, что тип объявлен ровно одной из `types:` / `fields:` /
  `variants:`, и перед сборкой — что каждый ручной тип обслужен `dump/2` (и `load/3` при
  `loadable: true`, вместе с семейством `union:` без `variants:`) ручной клаузой, а ручной вариант —
  колбэками `dump_variant/2` / `load_variant/3`. Ручная клауза на сгенерированный тип или семейство и
  `@spec` у `dump/2` / `load/3` плагина с `fields:` или `variants:` — `CompileError`; цели ручных
  клауз и сами отказы — `Core.Codec.Plugin.Clauses`.
  """

  alias Core.Codec.Plugin.Clauses
  alias Core.Helper

  @label "Codec.Plugin"

  @doc false
  @spec types!(term()) :: [module()]

  def types!(types) do
    if not (is_list(types) and Enum.all?(types, &(is_atom(&1) and not is_nil(&1)))) do
      Helper.Opts.reject!("#{@label}: types", "ожидается список модулей, получено #{inspect(types)}")
    end

    types
  end

  @doc false
  @spec loadable!(keyword()) :: boolean()

  def loadable!(opts) do
    case Keyword.get(opts, :loadable, true) do
      loadable when is_boolean(loadable) -> loadable
      other -> Helper.Opts.reject!("#{@label}: loadable", "ожидается true или false, получено #{inspect(other)}")
    end
  end

  @doc false
  @spec all_types!([[module()]]) :: [module()]

  def all_types!(groups) do
    all = Enum.concat(groups)

    case {all, all -- Enum.uniq(all)} do
      {[], _dupes} ->
        Helper.Opts.reject!(@label, "нет типов — задайте types:, fields: или variants:")

      {all, []} ->
        all

      {_all, dupes} ->
        Helper.Opts.reject!(
          "#{@label}: types",
          "типы объявлены в нескольких опциях: #{inspect(Enum.uniq(dupes))} — types: только для ручных типов"
        )
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
      Clauses.raise_never_match!(env, never_match(env, generated), "тип сгенерирован по fields: или variants:")
      Clauses.raise_specs!(env, funs, "у плагина с fields: или variants: контракт задаёт @callback Core.Codec.Plugin")
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
        {line, type} <- Clauses.manual_targets(env.module, fun, length(types), form(name)),
        type in types,
        do: {fun, line, type}
  end

  defp form(name) when name in ~w(dump dump_variant)a, do: :struct
  defp form(name) when name in ~w(load load_variant)a, do: :module

  # Ручная клауза с первым аргументом не литералом типа может принять любой тип плагина.
  defp check_covered!(env, {name, arity} = fun, required, generated, reason) do
    targets = Enum.map(Clauses.manual_targets(env.module, fun, length(generated), form(name)), &elem(&1, 1))
    uncovered = if :any in targets, do: [], else: (required -- generated) -- targets

    if uncovered != [] do
      raise CompileError,
        description: "#{inspect(env.module)}: плагину требуется #{name}/#{arity} для #{inspect(uncovered)} — #{reason}",
        file: env.file,
        line: env.line
    end
  end

  # Семейство существует ради `load/3`: у dump-only плагина восстанавливать нечем,
  # и клоуза фасада для него была бы обещанием, которого плагин не выполняет.
  defp validate_union!(union, false) when is_atom(union),
    do: Helper.Opts.reject!("#{@label}: union", "требует loadable: true")

  defp validate_union!(union, _loadable?) when is_atom(union) and not is_nil(union), do: union

  defp validate_union!(other, _loadable?),
    do: Helper.Opts.reject!("#{@label}: union", "ожидается модуль, получено #{inspect(other)}")
end
