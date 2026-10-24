defmodule Core.View.Opts do
  @moduledoc """
  Валидация и нормализация деклараций `use Core.View`.

  Поле объявляется keyword-спекой с ровно одним kind-ключом (`prim:`, `enum:`, `type:`,
  `view:`, `form:`, `list:`, `jsonb:`) и необязательным `optional: true`. Спека — источник
  и структуры, и её типа, и дампа, поэтому всё, что нельзя типизировать точно
  (кастомный kind Prim, неизвестная форма), отвергается на этапе компиляции.
  """

  alias Core.Codec
  alias Core.Helper.FieldCheck
  alias Core.Prim

  @label "View"
  @type_values FieldCheck.type_values()

  @prim_type_asts %{
    uuid: quote(do: String.t()),
    string: quote(do: String.t()),
    datetime: quote(do: DateTime.t()),
    date: quote(do: Date.t()),
    decimal: quote(do: Decimal.t()),
    integer: quote(do: integer())
  }

  @coercible_kinds Codec.coercible_kinds()

  # Kind, приводимый профилем, обязан быть и типизируем: поле объявляется Prim-модулем, а
  # значит новый native kind в `Core.Codec` без typespec оставил бы структуру без типа.
  @untyped_kinds @coercible_kinds -- Map.keys(@prim_type_asts)

  if @untyped_kinds != [] do
    raise CompileError,
      description: "#{@label}: нет typespec для kinds #{inspect(@untyped_kinds)}"
  end

  @typedoc "Нормализованная спека значения поля."
  @type spec ::
          {:prim, module(), atom()}
          | {:enum, module()}
          | {:type, atom()}
          | {:view, module()}
          | {:form, atom()}
          | {:list, spec()}
          | {:jsonb, module() | {module(), atom()}}

  @typedoc "Нормализованное поле: имя, спека значения, признак необязательности."
  @type field :: {atom(), spec(), boolean()}

  @doc "Проверить и нормализовать `forms:` — именованные map-формы вложенных значений."
  @spec forms!(term()) :: [{atom(), [field()]}]

  def forms!(forms) do
    if not Keyword.keyword?(forms) do
      raise CompileError, description: "#{@label}: forms: должен быть keyword-списком"
    end

    names = Keyword.keys(forms)
    check_duplicates!(names, "forms:")

    Enum.map(forms, fn {name, fields} -> {name, fields!(fields, names, "форма #{name}")} end)
  end

  @doc "Проверить и нормализовать `fields:` — поля представления."
  @spec fields!(term(), [atom()], String.t()) :: [field()]

  def fields!(fields, form_names, label \\ "fields:") do
    if not Keyword.keyword?(fields) or fields == [] do
      raise CompileError, description: "#{@label}: #{label} — непустой keyword-список полей"
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

  @doc "Typespec значения поля `prim:` по kind его Prim."
  @spec prim_type_ast(atom()) :: Macro.t()

  def prim_type_ast(kind) when is_atom(kind), do: Map.fetch!(@prim_type_asts, kind)

  @doc "Спека требует `codec` для дампа (иначе значение уходит как есть)."
  @spec needs_codec?(spec()) :: boolean()

  def needs_codec?({:prim, _mod, _kind}), do: true
  def needs_codec?({:list, inner}), do: needs_codec?(inner)
  def needs_codec?({:enum, _mod}), do: false
  def needs_codec?({:type, _type}), do: false
  def needs_codec?({:view, _mod}), do: true
  def needs_codec?({:form, _name}), do: true
  def needs_codec?({:jsonb, _spec_ref}), do: true

  # ---

  defp field!(name, opts, form_names, label) when is_atom(name) do
    if not Keyword.keyword?(opts) do
      raise CompileError, description: "#{where(label, name)} — keyword-спека"
    end

    {kind_key, value} = kind_key!(name, opts, label)
    optional? = Keyword.get(opts, :optional, false)

    if not is_boolean(optional?) do
      raise CompileError, description: "#{where(label, name)}: optional: — boolean"
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
            "#{where(label, name)}: нужен ровно один из " <>
              "prim:/enum:/type:/view:/form:/list:/jsonb:, задано #{inspect(other)}"
    end
  end

  defp spec!(:prim, mod, name, _form_names, label) do
    FieldCheck.prim!(mod, where(label, name))

    if mod.__domain_sensitive__() do
      raise CompileError,
        description:
          "#{where(label, name)}: #{inspect(mod)} объявлен sensitive — " <>
            "чувствительное значение не место в read-модели"
    end

    {:prim, mod, prim_kind!(mod, name, label)}
  end

  defp spec!(:enum, mod, name, _form_names, label) do
    FieldCheck.enum!(mod, where(label, name))

    {:enum, mod}
  end

  defp spec!(:type, type, name, _form_names, label) do
    if type not in @type_values do
      raise CompileError,
        description:
          "#{where(label, name)}: неизвестный type: #{inspect(type)}, " <>
            "ожидается один из #{inspect(@type_values)}"
    end

    {:type, type}
  end

  defp spec!(:view, mod, name, _form_names, label) do
    FieldCheck.module!(mod, where(label, name))

    if not Core.Helper.Module.exports?(mod, :__view__, 0) do
      raise CompileError,
        description: "#{where(label, name)}: #{inspect(mod)} не Core.View"
    end

    {:view, mod}
  end

  defp spec!(:form, form_name, name, form_names, label) do
    if form_name not in form_names do
      raise CompileError,
        description: "#{where(label, name)}: форма #{inspect(form_name)} не объявлена в forms:"
    end

    {:form, form_name}
  end

  defp spec!(:list, inner, name, form_names, label) do
    {^name, spec, optional?} = field!(name, inner, form_names, label)

    if optional? do
      raise CompileError,
        description: "#{where(label, name)}: optional: задаётся у самого поля, не в list:"
    end

    {:list, spec}
  end

  defp spec!(:jsonb, {mod, fun}, name, _form_names, label)
       when is_atom(mod) and is_atom(fun) do
    FieldCheck.module!(mod, where(label, name))

    if not Core.Helper.Module.exports?(mod, fun, 0) do
      raise CompileError,
        description:
          "#{where(label, name)}: #{inspect(mod)}.#{fun}/0 не объявлена " <>
            "(спека redump задаётся кодеком, который пишет эту wire-форму)"
    end

    {:jsonb, {mod, fun}}
  end

  # Есть ли у типа спека, знает только фасад: её выводит или объявляет плагин типа (`{:codec, Type}`).
  defp spec!(:jsonb, type, name, _form_names, label) when is_atom(type) do
    FieldCheck.module!(type, where(label, name))

    cond do
      Prim.prim?(type) ->
        raise CompileError,
          description: "#{where(label, name)}: jsonb: #{inspect(type)} — Prim, а не тип плагина; нужен prim:"

      Core.Enum.enum?(type) ->
        raise CompileError,
          description: "#{where(label, name)}: jsonb: #{inspect(type)} — Core.Enum, а не тип плагина; нужен enum:"

      true ->
        {:jsonb, type}
    end
  end

  defp spec!(:jsonb, other, name, _form_names, label) do
    raise CompileError,
      description:
        "#{where(label, name)}: jsonb: — модуль типа или {Модуль, :функция} спеки redump, " <>
          "задано #{inspect(other)}"
  end

  defp prim_kind!(mod, name, label) do
    leaf = Prim.leaf(mod)
    kind = leaf.__domain_kind__()

    if kind not in @coercible_kinds do
      raise CompileError,
        description:
          "#{where(label, name)}: у #{prim_label(mod, leaf)} kind #{inspect(kind)} — " <>
            "типизировать нечем; объявите поле через type:"
    end

    kind
  end

  defp prim_label(leaf, leaf), do: inspect(leaf)
  defp prim_label(mod, leaf), do: "#{inspect(mod)} (leaf #{inspect(leaf)})"

  defp where(label, name), do: "#{@label}: #{label}, поле #{name}"

  defp collect_forms({:form, name}, acc), do: MapSet.put(acc, name)
  defp collect_forms({:list, inner}, acc), do: collect_forms(inner, acc)
  defp collect_forms(_spec, acc), do: acc

  defp check_duplicates!(names, label) do
    case names -- Enum.uniq(names) do
      [] ->
        :ok

      dupes ->
        raise CompileError, description: "#{@label}: #{label} — дубли ключей #{inspect(dupes)}"
    end
  end
end
