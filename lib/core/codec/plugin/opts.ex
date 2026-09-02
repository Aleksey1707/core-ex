defmodule Core.Codec.Plugin.Opts do
  @moduledoc """
  Валидация опций `use Core.Codec.Plugin` и проверка контракта после компиляции.

  Проверяет XOR `types:` / `tags:`, обязательность `load/3` при `loadable: true`
  и `load_tagged/3` при `tagged: true`.
  """

  @doc false
  @spec normalize!(keyword()) :: {[module()], [String.t()], map() | nil, boolean()}

  def normalize!(opts) do
    normalize_types_or_tags!(Keyword.get(opts, :types), Keyword.get(opts, :tags))
  end

  @doc false
  @spec validate_flags!(boolean(), boolean()) :: :ok

  def validate_flags!(true, false) do
    raise CompileError, description: "tagged: true requires tags: %{mod => tag}"
  end

  def validate_flags!(_tagged?, _from_tags_map?), do: :ok

  @doc false
  @spec after_compile!(Macro.Env.t(), binary()) :: :ok

  def after_compile!(env, _bytecode) do
    mod = env.module
    loadable? = Module.get_attribute(mod, :codec_loadable)
    tagged? = Module.get_attribute(mod, :codec_tagged)

    if loadable? and not Module.defines?(mod, {:load, 3}) do
      raise CompileError,
        description: "#{inspect(mod)} with loadable: true must define load/3",
        file: env.file,
        line: env.line
    end

    if tagged? and not Module.defines?(mod, {:load_tagged, 3}) do
      raise CompileError,
        description: "#{inspect(mod)} with tagged: true must define load_tagged/3",
        file: env.file,
        line: env.line
    end

    :ok
  end

  # ---

  defp normalize_types_or_tags!(types, tags) when is_map(tags) and not is_nil(types) do
    raise CompileError, description: "types: and tags: are mutually exclusive"
  end

  defp normalize_types_or_tags!(_types, tags) when is_map(tags), do: normalize_tags_map!(tags)

  defp normalize_types_or_tags!(types, nil) when is_list(types) and types != [] do
    normalize_types_list!(types)
  end

  defp normalize_types_or_tags!(types, tags) when is_list(types) and not is_nil(tags) do
    raise CompileError,
      description: "tags: must be %{mod => tag}; do not pass tags: with types:"
  end

  defp normalize_types_or_tags!(_types, _tags) do
    raise CompileError,
      description: "provide types: (non-empty list) or tags: (%{mod => tag})"
  end

  defp normalize_tags_map!(tags) when map_size(tags) == 0 do
    raise CompileError, description: "tags: must be a non-empty map"
  end

  defp normalize_tags_map!(tags) do
    Enum.each(tags, fn
      {mod, tag} when is_atom(mod) and is_binary(tag) ->
        :ok

      other ->
        raise CompileError,
          description: "tags: entries must be {module, String.t()}, got: #{inspect(other)}"
    end)

    {Map.keys(tags), Map.values(tags), tags, true}
  end

  defp normalize_types_list!(types) do
    if not Enum.all?(types, &is_atom/1) do
      raise CompileError, description: "types: must be a non-empty list of modules"
    end

    {types, [], nil, false}
  end
end
