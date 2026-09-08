defmodule Core.Guard do
  @moduledoc """
  Именованные guard'ы для сужения домена аргументов в function heads.

  Подключать через `import` (не `alias`).

  - `is/2`, `is_opt/2` — `defguard`: `%mod{}` / `nil | %mod{}`
  - `is_prim/1` — структурный признак Prim (struct с полем `value`)
  - `is_plain_map/1`, `is_json/1` — map без struct / поверхностная JSON-совместимость
  - `is_enum/2`, `in_enum/3` — макросы для Core.Enum (раскрываются в `in` на compile-time)
  """

  @doc """
  Похоже ли значение на Prim: struct с полем `value`.

  Guard не может вызывать `Prim.prim?/1` (тот грузит модуль), поэтому проверка
  структурная — для точной вне guard: `Prim.prim?(value.__struct__)`.
  """
  defguard is_prim(value) when is_struct(value) and is_map_key(value, :value)

  @doc "Guard: `%mod{}`."
  defguard is(value, mod) when is_struct(value, mod)

  @doc "Guard: `nil | %mod{}`."
  defguard is_opt(value, mod) when is_nil(value) or is_struct(value, mod)

  @doc "Guard: map без struct."
  defguard is_plain_map(value)
           when is_map(value) and not is_struct(value)

  @doc """
  Guard: JSON-совместимое значение.

  Проверка поверхностная — только верхний уровень: содержимое списка и map
  не обходится, поэтому `[{:a, 1}]` и charlist считаются подходящими.
  """
  defguard is_json(value)
           when is_binary(value) or is_list(value) or is_number(value) or
                  is_boolean(value) or is_nil(value) or is_plain_map(value)

  @doc """
  Guard-макрос: `value` входит в `mod.values()` (`Core.Enum`).

  `mod` — литерал модуля на compile-time.
  """
  defmacro is_enum(value, mod) do
    mod = expand_mod!(mod, __CALLER__)
    values = enum_values!(mod, __CALLER__)
    track_enum_source(mod, __CALLER__)
    quote do: unquote(value) in unquote(values)
  end

  @doc """
  Guard-макрос: `value` входит в `subset`; `subset ⊆ mod.values()`.

  Опечатка или дубль в subset → `CompileError`. `subset` — литерал списка атомов (`~w(...)a`).
  """
  defmacro in_enum(value, mod, subset) do
    mod = expand_mod!(mod, __CALLER__)
    values = enum_values!(mod, __CALLER__)
    subset_list = literal_atom_list!(subset, __CALLER__)
    validate_subset!(subset_list, values, mod, __CALLER__)
    track_enum_source(mod, __CALLER__)
    quote do: unquote(value) in unquote(subset_list)
  end

  # ---

  defp expand_mod!(mod_ast, env) do
    mod = Macro.expand(mod_ast, env)

    if is_atom(mod) and mod != nil do
      mod
    else
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "ожидался алиас модуля или атом, получено: #{Macro.to_string(mod_ast)}"
    end
  end

  defp enum_values!(mod, env) do
    with {:error, reason} <- Code.ensure_compiled(mod) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "не удалось скомпилировать #{inspect(mod)}: #{inspect(reason)}"
    end

    unless function_exported?(mod, :values, 0) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "#{inspect(mod)} не является модулем Core.Enum (нет values/0)"
    end

    values = mod.values()

    unless is_list(values) and values != [] and Enum.all?(values, &is_atom/1) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "#{inspect(mod)}.values/0 должна возвращать непустой список атомов"
    end

    values
  end

  defp literal_atom_list!(ast, env) do
    list = extract_atom_list!(ast, env)

    if list == [] do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "subset enum должен быть непустым списком атомов"
    end

    list
  end

  defp extract_atom_list!(ast, env) when is_list(ast) do
    if atom_list?(ast),
      do: ast,
      else: raise_expected_atom_list!(ast, env)
  end

  defp extract_atom_list!(ast, env) do
    case Macro.expand(ast, env) do
      list when is_list(list) -> extract_atom_list!(list, env)
      other -> raise_expected_atom_list!(other, env)
    end
  end

  defp atom_list?(list), do: Enum.all?(list, &is_atom/1)

  defp raise_expected_atom_list!(got, env) do
    raise CompileError,
      file: env.file,
      line: env.line,
      description: "ожидался непустой список атомов, получено: #{Macro.to_string(got)}"
  end

  defp validate_subset!(subset, values, mod, env) do
    assert_no_duplicates!(subset, env)
    Enum.each(subset, &assert_enum_member!(&1, values, mod, env))
    :ok
  end

  defp assert_no_duplicates!(subset, env) do
    duplicates = subset -- Enum.uniq(subset)

    if duplicates != [] do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "subset enum не должен содержать дублей: #{inspect(Enum.uniq(duplicates))}"
    end

    :ok
  end

  defp assert_enum_member!(value, values, mod, env) do
    if value in values do
      :ok
    else
      name = enum_name(mod)

      raise CompileError,
        file: env.file,
        line: env.line,
        description: "#{name}: #{inspect(value)} не входит в enum #{inspect(values)}"
    end
  end

  defp enum_name(mod) do
    if function_exported?(mod, :name, 0),
      do: mod.name(),
      else: inspect(mod)
  end

  # Значения enum инлайнятся в guard на compile-time, но компилятор этой связи не видит:
  # без `@external_resource` правка enum не пересобирает каллер (см. 11-domain.md).
  defp track_enum_source(mod, env) do
    source = mod.module_info(:compile)[:source]

    if (env.module && is_list(source)) and source != [],
      do: Module.put_attribute(env.module, :external_resource, List.to_string(source))

    :ok
  end
end
