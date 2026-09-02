defmodule Core.View.Opts do
  @moduledoc """
  Валидация и нормализация деклараций `use Core.View`.

  Поле объявляется keyword-спекой с ровно одним kind-ключом (`prim:`, `enum:`, `type:`,
  `view:`, `form:`, `list:`, `jsonb:`) и необязательным `optional: true`. Спека — источник
  и структуры, и её типа, и дампа, поэтому всё, что нельзя типизировать точно
  (кастомный kind Prim, неизвестная форма), отвергается на этапе компиляции.
  """

  alias Core.Prim

  @scalar_types ~w(string boolean integer pos_integer non_neg_integer)a
  @formattable_kinds ~w(uuid datetime date decimal)a
  @plain_kinds ~w(string integer)a

  @typedoc "Нормализованная спека значения поля."
  @type spec ::
          {:prim, module(), atom()}
          | {:enum, module()}
          | {:type, atom()}
          | {:view, module()}
          | {:form, atom()}
          | {:list, spec()}
          | {:jsonb, {module(), atom()}}

  @typedoc "Нормализованное поле: имя, спека значения, признак необязательности."
  @type field :: {atom(), spec(), boolean()}

  @doc "Проверить и нормализовать `forms:` — именованные map-формы вложенных значений."
  @spec forms!(term()) :: [{atom(), [field()]}]

  def forms!(forms) do
    if not Keyword.keyword?(forms) do
      raise CompileError, description: "View: forms: должен быть keyword-списком"
    end

    names = Keyword.keys(forms)
    check_duplicates!(names, "forms:")

    Enum.map(forms, fn {name, fields} -> {name, fields!(fields, names, "форма #{name}")} end)
  end

  @doc "Проверить и нормализовать `fields:` — поля представления."
  @spec fields!(term(), [atom()], String.t()) :: [field()]

  def fields!(fields, form_names, label \\ "fields:") do
    if not Keyword.keyword?(fields) or fields == [] do
      raise CompileError, description: "View: #{label} — непустой keyword-список полей"
    end

    check_duplicates!(Keyword.keys(fields), label)

    Enum.map(fields, fn {name, opts} -> field!(name, opts, form_names, label) end)
  end

  @doc "Формы, на которые ссылается хотя бы одна спека."
  @spec used_forms([field()]) :: MapSet.t(atom())

  def used_forms(fields) do
    Enum.reduce(fields, MapSet.new(), fn {_name, spec, _optional?}, acc ->
      collect_forms(spec, acc)
    end)
  end

  @doc "Спека требует `codec` для дампа (иначе значение уходит как есть)."
  @spec needs_codec?(spec()) :: boolean()

  def needs_codec?({:prim, _mod, kind}), do: kind in @formattable_kinds
  def needs_codec?({:list, inner}), do: needs_codec?(inner)
  def needs_codec?({:enum, _mod}), do: false
  def needs_codec?({:type, _type}), do: false
  def needs_codec?({:view, _mod}), do: true
  def needs_codec?({:form, _name}), do: true
  def needs_codec?({:jsonb, _spec_ref}), do: true

  # ---

  defp field!(name, opts, form_names, label) when is_atom(name) do
    if not Keyword.keyword?(opts) do
      raise CompileError, description: "View: #{label}, поле #{name} — keyword-спека"
    end

    {kind_key, value} = kind_key!(name, opts, label)
    optional? = Keyword.get(opts, :optional, false)

    if not is_boolean(optional?) do
      raise CompileError, description: "View: #{label}, поле #{name}: optional: — boolean"
    end

    {name, spec!(kind_key, value, name, form_names, label), optional?}
  end

  defp kind_key!(name, opts, label) do
    case Keyword.drop(opts, ~w(optional)a) do
      [{key, value}] when key in ~w(prim enum type view form list jsonb)a ->
        {key, value}

      other ->
        raise CompileError,
          description:
            "View: #{label}, поле #{name}: нужен ровно один из " <>
              "prim:/enum:/type:/view:/form:/list:/jsonb:, задано #{inspect(other)}"
    end
  end

  defp spec!(:prim, mod, name, _form_names, label) do
    ensure_compiled!(mod, name, label)

    if not Prim.prim?(mod) do
      raise CompileError,
        description: "View: #{label}, поле #{name}: #{inspect(mod)} не Prim"
    end

    if mod.__domain_sensitive__() do
      raise CompileError,
        description:
          "View: #{label}, поле #{name}: #{inspect(mod)} объявлен sensitive — " <>
            "чувствительное значение не место в read-модели"
    end

    {:prim, mod, prim_kind!(mod, name, label)}
  end

  defp spec!(:enum, mod, name, _form_names, label) do
    ensure_compiled!(mod, name, label)

    if not function_exported?(mod, :values, 0) do
      raise CompileError,
        description: "View: #{label}, поле #{name}: #{inspect(mod)} не Core.Enum"
    end

    {:enum, mod}
  end

  defp spec!(:type, type, name, _form_names, label) do
    if type not in @scalar_types do
      raise CompileError,
        description:
          "View: #{label}, поле #{name}: неизвестный type: #{inspect(type)}, " <>
            "ожидается один из #{inspect(@scalar_types)}"
    end

    {:type, type}
  end

  defp spec!(:view, mod, name, _form_names, label) do
    ensure_compiled!(mod, name, label)

    if not function_exported?(mod, :__struct__, 0) do
      raise CompileError,
        description: "View: #{label}, поле #{name}: #{inspect(mod)} не struct"
    end

    {:view, mod}
  end

  defp spec!(:form, form_name, name, form_names, label) do
    if form_name not in form_names do
      raise CompileError,
        description:
          "View: #{label}, поле #{name}: форма #{inspect(form_name)} не объявлена в forms:"
    end

    {:form, form_name}
  end

  defp spec!(:list, inner, name, form_names, label) do
    {^name, spec, optional?} = field!(name, inner, form_names, label)

    if optional? do
      raise CompileError,
        description: "View: #{label}, поле #{name}: optional: задаётся у самого поля, не в list:"
    end

    {:list, spec}
  end

  defp spec!(:jsonb, {mod, fun}, name, _form_names, label)
       when is_atom(mod) and is_atom(fun) do
    ensure_compiled!(mod, name, label)

    if not function_exported?(mod, fun, 0) do
      raise CompileError,
        description:
          "View: #{label}, поле #{name}: #{inspect(mod)}.#{fun}/0 не объявлена " <>
            "(спека redump задаётся кодеком, который пишет эту wire-форму)"
    end

    {:jsonb, {mod, fun}}
  end

  defp spec!(:jsonb, other, name, _form_names, label) do
    raise CompileError,
      description:
        "View: #{label}, поле #{name}: jsonb: — {Модуль, :функция} спеки redump, " <>
          "задано #{inspect(other)}"
  end

  defp prim_kind!(mod, name, label) do
    kind = mod.__domain_kind__()

    if kind not in (@formattable_kinds ++ @plain_kinds) do
      raise CompileError,
        description:
          "View: #{label}, поле #{name}: у #{inspect(mod)} kind #{inspect(kind)} — " <>
            "типизировать нечем; объявите поле через type:"
    end

    kind
  end

  defp ensure_compiled!(mod, name, label) when is_atom(mod) do
    case Code.ensure_compiled(mod) do
      {:module, _} ->
        :ok

      {:error, reason} ->
        raise CompileError,
          description: "View: #{label}, поле #{name}: #{inspect(mod)} недоступен (#{reason})"
    end
  end

  defp ensure_compiled!(other, name, label) do
    raise CompileError,
      description:
        "View: #{label}, поле #{name}: ожидался модуль, " <>
          "задано #{inspect(other)}"
  end

  defp collect_forms({:form, name}, acc), do: MapSet.put(acc, name)
  defp collect_forms({:list, inner}, acc), do: collect_forms(inner, acc)
  defp collect_forms(_spec, acc), do: acc

  defp check_duplicates!(names, label) do
    case names -- Enum.uniq(names) do
      [] -> :ok
      dupes -> raise CompileError, description: "View: #{label} — дубли ключей #{inspect(dupes)}"
    end
  end
end
