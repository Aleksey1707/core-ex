defmodule Core.Codec.Plugin.Opts do
  @moduledoc """
  Валидация опций `use Core.Codec.Plugin` и проверка контракта после компиляции.

  Проверяет форму `types:` и `union:` и обязательность `load/3` при `loadable: true`.
  """

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

    if Module.get_attribute(mod, :codec_loadable) and not Module.defines?(mod, {:load, 3}) do
      raise CompileError,
        description: "#{inspect(mod)}: при loadable: true требуется load/3",
        file: env.file,
        line: env.line
    end

    :ok
  end

  # ---

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
end
