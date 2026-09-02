defmodule Core.Guard do
  @moduledoc """
  Именованные guard'ы для сужения домена аргументов в function heads.

  Подключать через `import` (не `alias`).

  - `is/2`, `is_opt/2` — `defguard` для struct / Prim
  - `is_enum/2`, `in_enum/3` — макросы для Core.Enum (раскрываются в `in` на compile-time)
  """

  @doc """
  Похоже ли значение на Prim: struct с полем `value`.

  Guard не может вызывать `Prim.prim?/1` (тот грузит модуль), поэтому проверка
  структурная — для точной используйте `Prim.prim?/1` вне guard.
  """
  defguard is_prim(value) when is_struct(value) and is_map_key(value, :value)

  @doc "Является ли значение `%Error{}`."
  defguard is_error(value) when is_struct(value, Core.Error)

  @doc "Guard: `%mod{}`."
  defguard is(value, mod) when is_struct(value, mod)

  @doc "Guard: `nil | %mod{}`."
  defguard is_opt(value, mod) when is_nil(value) or is_struct(value, mod)

  @doc "Guard: map без struct."
  defguard is_plain_map(value)
           when is_map(value) and not is_struct(value)

  @doc "Guard: JSON-совместимое значение."
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
    quote do: unquote(value) in unquote(values)
  end

  @doc """
  Guard-макрос: `value` входит в `subset`; `subset ⊆ mod.values()`.

  Опечатка в subset → `CompileError`. `subset` — литерал списка атомов (`~w(...)a`).
  """
  defmacro in_enum(value, mod, subset) do
    mod = expand_mod!(mod, __CALLER__)
    values = enum_values!(mod, __CALLER__)
    subset_list = literal_atom_list!(subset, __CALLER__)
    validate_subset!(subset_list, values, mod, __CALLER__)
    quote do: unquote(value) in unquote(subset_list)
  end

  @doc false
  @spec expand_mod!(Macro.t(), Macro.Env.t()) :: module()

  def expand_mod!(mod_ast, env) do
    mod = Macro.expand(mod_ast, env)

    if is_atom(mod) and mod != nil do
      mod
    else
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "expected a module alias/atom, got: #{Macro.to_string(mod_ast)}"
    end
  end

  @doc false
  @spec enum_values!(module(), Macro.Env.t()) :: [atom()]

  def enum_values!(mod, env) do
    case Code.ensure_compiled(mod) do
      {:module, ^mod} ->
        :ok

      {:error, reason} ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "failed to compile #{inspect(mod)}: #{inspect(reason)}"
    end

    unless function_exported?(mod, :values, 0) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "#{inspect(mod)} is not a Core.Enum module (missing values/0)"
    end

    values = mod.values()

    unless is_list(values) and values != [] and Enum.all?(values, &is_atom/1) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "#{inspect(mod)}.values/0 must return a non-empty list of atoms"
    end

    values
  end

  @doc false
  @spec literal_atom_list!(Macro.t(), Macro.Env.t()) :: [atom()]

  def literal_atom_list!(ast, env) do
    list = extract_atom_list!(ast, env)

    if list == [] do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "enum subset must be a non-empty list of atoms"
    end

    list
  end

  # ---

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
      description: "expected a non-empty list of atoms, got: #{Macro.to_string(got)}"
  end

  @doc false
  @spec validate_subset!([atom()], [atom()], module(), Macro.Env.t()) :: :ok

  def validate_subset!(subset, values, mod, env) do
    Enum.each(subset, &assert_enum_member!(&1, values, mod, env))
    :ok
  end

  # ---

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
end
