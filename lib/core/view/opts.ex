defmodule Core.View.Opts do
  @moduledoc """
  Валидация и нормализация деклараций `use Core.View`.

  Поле объявляется keyword-спекой с ровно одним kind-ключом (`prim:`, `enum:`, `type:`,
  `view:`, `form:`, `list:`, `set:`, `map:`, `jsonb:`) и необязательным `optional: true`. Спека — источник
  и структуры, и её типа, и дампа, поэтому всё, что нельзя типизировать точно
  (кастомный kind Prim, неизвестная форма), отвергается на этапе компиляции.
  """

  alias Core.Codec
  alias Core.Codec.Field
  alias Core.Helper
  alias Core.Helper.FieldCheck
  alias Core.Prim

  @label "View"
  @type_values FieldCheck.type_values()
  @kind_keys ~w(prim enum type view form list set map jsonb)a
  @collection_kinds ~w(list set)a

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
          | {:set, spec()}
          | {:map, spec(), spec()}
          | {:jsonb, module() | {module(), atom()}}

  @typedoc "Нормализованное поле: имя, спека значения, признак необязательности."
  @type field :: {atom(), spec(), boolean()}

  @doc "Проверить и нормализовать `forms:` — именованные map-формы вложенных значений."
  @spec forms!(term()) :: [{atom(), [field()]}]

  def forms!(forms) do
    if not Keyword.keyword?(forms) do
      Helper.Opts.reject!("#{@label}: forms", "ожидается keyword-список форм, получено #{inspect(forms)}")
    end

    names = Keyword.keys(forms)
    FieldCheck.unique!(names, "#{@label}: forms")

    Enum.map(forms, fn {name, fields} -> {name, fields!(fields, names, "forms: #{name}")} end)
  end

  @doc "Проверить и нормализовать `fields:` — поля представления."
  @spec fields!(term(), [atom()], String.t()) :: [field()]

  def fields!(fields, form_names, label \\ "fields") do
    if not Keyword.keyword?(fields) or fields == [] do
      Helper.Opts.reject!("#{@label}: #{label}", "ожидается непустой keyword-список полей, получено #{inspect(fields)}")
    end

    FieldCheck.unique!(Keyword.keys(fields), "#{@label}: #{label}")

    Enum.map(fields, fn {name, opts} -> field!(name, opts, form_names, "#{@label}: #{label}: #{name}") end)
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

  @doc false
  @spec shaped?(spec()) :: boolean()

  def shaped?({:set, _inner}), do: true
  def shaped?({:map, _key, _value}), do: true
  def shaped?({:list, inner}), do: shaped?(inner)
  def shaped?(_spec), do: false

  @doc "Спека требует `codec` для дампа (иначе значение уходит как есть)."
  @spec needs_codec?(spec()) :: boolean()

  def needs_codec?({:prim, _mod, _kind}), do: true
  def needs_codec?({:enum, _mod}), do: false
  def needs_codec?({:type, _type}), do: false
  def needs_codec?({:view, _mod}), do: true
  def needs_codec?({:form, _name}), do: true
  def needs_codec?({:jsonb, _spec_ref}), do: true
  def needs_codec?({kind, _inner} = spec) when kind in @collection_kinds, do: nested_codec?(spec)
  def needs_codec?({:map, _key, _value} = spec), do: nested_codec?(spec)

  # ---

  defp nested_codec?(spec), do: Enum.any?(Field.children(spec), &needs_codec?/1)

  defp field!(name, opts, form_names, path) when is_atom(name) do
    if not Keyword.keyword?(opts) do
      Helper.Opts.reject!(path, "ожидается keyword-спека, получено #{inspect(opts)}")
    end

    {kind_key, value} = kind_key!(opts, path)
    optional? = Keyword.get(opts, :optional, false)

    if not is_boolean(optional?) do
      Helper.Opts.reject!("#{path}: optional", "ожидается boolean, получено #{inspect(optional?)}")
    end

    {name, spec!(kind_key, value, name, form_names, path), optional?}
  end

  defp kind_key!(opts, path) do
    case Keyword.drop(opts, ~w(optional)a) do
      [{key, value}] when key in @kind_keys ->
        {key, value}

      other ->
        Helper.Opts.reject!(
          path,
          "ожидается ровно один из #{Enum.map_join(@kind_keys, "/", &"#{&1}:")}, получено #{inspect(other)}"
        )
    end
  end

  defp spec!(:prim, mod, _name, _form_names, path) do
    at = "#{path}: prim"
    FieldCheck.prim!(mod, at)
    leaf = Prim.leaf(mod)

    case Codec.check_readable(mod) do
      :ok ->
        {:prim, mod, leaf.__domain_kind__()}

      {:error, :not_coercible} ->
        Helper.Opts.reject!(
          at,
          "у #{prim_label(mod, leaf)} kind #{inspect(leaf.__domain_kind__())} — типизировать нечем; " <>
            "объявите поле через type:"
        )

      {:error, :sensitive} ->
        Helper.Opts.reject!(
          at,
          "#{inspect(mod)} объявлен sensitive — чувствительное значение не место в read-модели"
        )
    end
  end

  defp spec!(:enum, mod, _name, _form_names, path) do
    FieldCheck.enum!(mod, "#{path}: enum")

    {:enum, mod}
  end

  defp spec!(:type, type, _name, _form_names, path) do
    if type not in @type_values do
      Helper.Opts.reject!(
        "#{path}: type",
        "ожидается один из #{inspect(@type_values)}, получено #{inspect(type)}"
      )
    end

    {:type, type}
  end

  defp spec!(:view, mod, _name, _form_names, path) do
    at = "#{path}: view"
    FieldCheck.module!(mod, at)

    if not Core.Helper.Module.exports?(mod, :__view__, 0) do
      Helper.Opts.reject!(at, "#{inspect(mod)} не Core.View")
    end

    {:view, mod}
  end

  defp spec!(:form, form_name, _name, form_names, path) do
    if form_name not in form_names do
      Helper.Opts.reject!("#{path}: form", "форма #{inspect(form_name)} не объявлена в forms:")
    end

    {:form, form_name}
  end

  defp spec!(kind, inner, name, form_names, path) when kind in @collection_kinds,
    do: {kind, element!("#{kind}", name, inner, form_names, path)}

  # Ключ — по тому же правилу, что в спеке полей: вид с wire-строкой, не ПДн (ADR-0091).
  defp spec!(:map, inner, name, form_names, path) do
    {key_opts, value_opts} = Field.map_opts!(inner, path)
    key = element!("map: key", name, key_opts, form_names, path)
    Field.check_map_key!(field_key(key), key_opts, path)

    {:map, key, element!("map: value", name, value_opts, form_names, path)}
  end

  defp spec!(:jsonb, {mod, fun}, _name, _form_names, path)
       when is_atom(mod) and is_atom(fun) do
    at = "#{path}: jsonb"
    FieldCheck.module!(mod, at)

    if not Core.Helper.Module.exports?(mod, fun, 0) do
      Helper.Opts.reject!(
        at,
        "#{inspect(mod)}.#{fun}/0 не объявлена (спека redump задаётся кодеком, который пишет эту wire-форму)"
      )
    end

    {:jsonb, {mod, fun}}
  end

  # Есть ли у типа спека, знает только фасад: её выводит или объявляет плагин типа (`{:codec, Type}`).
  defp spec!(:jsonb, type, _name, _form_names, path) when is_atom(type) do
    at = "#{path}: jsonb"
    FieldCheck.module!(type, at)

    cond do
      Prim.prim?(type) ->
        Helper.Opts.reject!(at, "#{inspect(type)} — Prim, а не тип плагина; нужен prim:")

      Core.Enum.enum?(type) ->
        Helper.Opts.reject!(at, "#{inspect(type)} — Core.Enum, а не тип плагина; нужен enum:")

      true ->
        {:jsonb, type}
    end
  end

  defp spec!(:jsonb, other, _name, _form_names, path) do
    Helper.Opts.reject!(
      "#{path}: jsonb",
      "ожидается модуль типа или {Модуль, :функция} спеки redump, получено #{inspect(other)}"
    )
  end

  defp element!(label, name, inner, form_names, path) do
    {^name, spec, optional?} = field!(name, inner, form_names, path)

    if optional? do
      Helper.Opts.reject!("#{path}: #{label}", "optional: задаётся у самого поля, не в #{label}:")
    end

    spec
  end

  defp field_key({:prim, mod, _kind}), do: {:prim, mod}
  defp field_key(spec), do: spec

  defp prim_label(leaf, leaf), do: inspect(leaf)
  defp prim_label(mod, leaf), do: "#{inspect(mod)} (leaf #{inspect(leaf)})"

  defp collect_forms({:form, name}, acc), do: MapSet.put(acc, name)
  defp collect_forms(spec, acc), do: Enum.reduce(Field.values(spec), acc, &collect_forms/2)
end
