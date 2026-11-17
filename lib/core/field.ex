defmodule Core.Field do
  @moduledoc false

  alias Core.Codec.Field, as: Grammar
  alias Core.Field.Meta
  alias Core.Helper.Opts

  @typedoc false
  @type role :: :struct | :payload | :plugin | :view | :labels | :union

  @typedoc false
  @type subject :: :aggregate_id | {:payload, atom()} | {:local, atom()}

  @typedoc false
  @type spec ::
          {:prim, module()}
          | {:enum, module()}
          | {:entity, module()}
          | {:union, module()}
          | {:list, spec()}
          | {:set, spec()}
          | {:map, spec(), spec()}
          | {:type, atom()}
          | {:view, module()}
          | {:form, atom()}
          | {:jsonb, module() | {module(), atom()}}
          | {:personal, spec()}

  @typedoc "Значение `default:`: нет или значение по умолчанию."
  @type default :: :none | {:default, term()}

  @typedoc "Шаг пути ПДн-места: wire-ключ объявления или `:each` — элемент списка, значения словаря."
  @type step :: atom() | :each

  @typedoc "ПДн-место: путь от корня объявления и субъект."
  @type place_entry :: %{path: [step()], subject: subject() | {:path, [step()]}}

  @enforce_keys ~w(name wire spec optional? default personal subject)a
  defstruct @enforce_keys

  @typedoc """
  Нормализованное поле декларации: имя, wire-ключ, вид, необязательность, `default:`, объявленный
  флаг ПДн-места и объявленный субъект.
  """
  @type t :: %__MODULE__{
          name: atom(),
          wire: String.t(),
          spec: spec(),
          optional?: boolean(),
          default: default(),
          personal: boolean() | nil,
          subject: subject() | nil
        }

  @declarable ~w(struct payload plugin labels view)a
  @nested_kinds ~w(list set)a
  @personalable ~w(struct payload labels)a

  # ===== декларация =====

  @doc false
  @spec declare!(term(), role(), String.t()) :: [t()]

  def declare!(_spec, :union, where) when is_binary(where), do: Opts.reject!(where, "у семейства вариантов полей нет")

  def declare!(spec, role, where) when role in @declarable and is_binary(where) do
    check_keys!(spec, role, where)
    {clean, personal} = split_personal(spec, role, where)

    clean
    |> parse!(role, where)
    |> normalize!(role, where)
    |> wrap_personal!(personal)
  end

  @doc false
  @spec normalize!([Grammar.t()], role(), String.t()) :: [t()]

  def normalize!(fields, role, where) when is_list(fields) and is_binary(where) do
    seed = Enum.map(fields, &ir(&1, role, where, %{}))
    by_name = Map.new(seed, &{&1.name, &1})

    Enum.map(fields, &ir(&1, role, where, by_name))
  end

  # ---

  defp ir(legacy, role, where, fields) do
    ctx = %{role: role, name: legacy.name, where: "#{where}: #{legacy.name}", spec: legacy.spec, fields: fields}

    %__MODULE__{
      name: legacy.name,
      wire: legacy.wire,
      spec: legacy.spec,
      optional?: legacy.optional?,
      default: legacy.default,
      personal: legacy.personal,
      subject: legacy.subject
    }
    |> Meta.normalize!(legacy, ctx)
  end

  defp parse!(spec, :view, _where) do
    spec
    |> Core.View.Opts.fields!([], "fields")
    |> Enum.map(fn %Core.View.Field{name: name, spec: spec, optional?: optional?} ->
      %Grammar{
        name: name,
        spec: view_spec(spec),
        optional?: optional?,
        wire: Atom.to_string(name),
        default: :none,
        subject: nil,
        personal: nil,
        destroyable: []
      }
    end)
  end

  defp parse!(spec, role, where), do: Grammar.normalize!(spec, role, where)

  # Вид View хранит kind Prim ради своего типа и дампа; в IR его нет — вид значения задаёт Prim.
  defp view_spec({:prim, mod, _kind}), do: {:prim, mod}
  defp view_spec({kind, inner}) when kind in @nested_kinds, do: {kind, view_spec(inner)}
  defp view_spec({:map, key, value}), do: {:map, view_spec(key), view_spec(value)}
  defp view_spec(spec), do: spec

  # Ключ, которого роль не допускает, — тот же отказ, что и неизвестный ключ у грамматики: хост его
  # не знает.
  defp check_keys!(spec, role, where) when is_list(spec) do
    if Keyword.keyword?(spec), do: Enum.each(spec, &check_field_keys(&1, role, where))
  end

  defp check_keys!(_spec, _role, _where), do: :ok

  defp check_field_keys({name, opts}, role, where) when is_atom(name) and is_list(opts) do
    case foreign_keys(opts, role) do
      [] -> :ok
      [key | _rest] -> Opts.reject!("#{where}: #{name}", "неизвестные ключи #{inspect([key])}")
    end
  end

  defp check_field_keys(_entry, _role, _where), do: :ok

  defp foreign_keys(opts, role) do
    if Keyword.keyword?(opts),
      do: Enum.filter(Keyword.keys(opts), &(&1 in Meta.keys() and not Meta.allowed?(&1, role))),
      else: []
  end

  # `personal:` вложенного места (`list: [prim: X, personal: true]`, значение и ключ `map:`)
  # снимается до разбора: грамматика описывает вид, а место ПДн — метаданные поля. Ключ пишется в
  # IR обёрткой `{:personal, вид}`.
  defp split_personal(spec, role, where) do
    if Keyword.keyword?(spec) do
      Enum.map_reduce(spec, %{}, fn
        {name, opts}, acc -> split_field(name, opts, role, where, acc)
        entry, acc -> {entry, acc}
      end)
    else
      {spec, %{}}
    end
  end

  # ---

  defp split_field(name, opts, role, where, acc) when is_atom(name) do
    if Keyword.keyword?(opts) do
      {opts, acc} = split_nested(opts, %{role: role, name: name, where: "#{where}: #{name}"}, [], acc)
      {{name, opts}, acc}
    else
      {{name, opts}, acc}
    end
  end

  defp split_field(name, opts, _role, _where, acc), do: {{name, opts}, acc}

  defp split_nested(opts, meta, path, acc) do
    {personal, opts} = pop_personal(opts, meta, path)
    acc = record_personal(acc, meta, path, personal)
    {entries, acc} = Enum.map_reduce(opts, acc, &split_entry(&1, meta, path, &2))

    {entries, acc}
  end

  defp split_entry({kind, inner}, meta, path, acc) when kind in @nested_kinds do
    {inner, acc} = split_spec(inner, meta, path ++ [kind], acc)
    {{kind, inner}, acc}
  end

  defp split_entry({:map, inner}, meta, path, acc) when is_list(inner) do
    if Keyword.keyword?(inner) do
      {entries, acc} =
        Enum.map_reduce(inner, acc, fn
          {side, spec}, acc when side in ~w(key value)a ->
            {spec, acc} = split_spec(spec, meta, path ++ [:map, side], acc)
            {{side, spec}, acc}

          entry, acc ->
            {entry, acc}
        end)

      {{:map, entries}, acc}
    else
      {{:map, inner}, acc}
    end
  end

  defp split_entry(entry, _meta, _path, acc), do: {entry, acc}

  defp split_spec(spec, meta, path, acc) when is_list(spec) do
    if Keyword.keyword?(spec), do: split_nested(spec, meta, path, acc), else: {spec, acc}
  end

  defp split_spec(spec, _meta, _path, acc), do: {spec, acc}

  # Место верхнего уровня остаётся ключу грамматики: она отвергает его в ролях без флага.
  defp pop_personal(opts, _meta, []), do: {nil, opts}

  defp pop_personal(opts, meta, path) do
    case Keyword.fetch(opts, :personal) do
      :error ->
        {nil, opts}

      {:ok, personal?} ->
        check_personal!(personal?, meta, path)
        {personal?, Keyword.delete(opts, :personal)}
    end
  end

  defp check_personal!(_personal?, meta, path) when meta.role not in @personalable,
    do: Opts.reject!("#{meta.where}: #{path_label(path)}", "неизвестные ключи [:personal]")

  defp check_personal!(personal?, _meta, _path) when is_boolean(personal?), do: :ok

  defp check_personal!(personal?, meta, path),
    do:
      Opts.reject!("#{meta.where}: #{path_label(path)}", "personal: ожидается boolean, получено #{inspect(personal?)}")

  defp record_personal(acc, meta, path, personal?) when is_boolean(personal?),
    do: Map.put(acc, {meta.name, path}, personal?)

  defp record_personal(acc, _meta, _path, _personal?), do: acc

  defp path_label(path) do
    case Enum.take(path, -2) do
      [:map, side] when side in ~w(key value)a -> "map: #{side}: "
      _other -> "#{List.last(path)}: "
    end
  end

  defp wrap_personal!(fields, personal) when map_size(personal) == 0, do: fields

  defp wrap_personal!(fields, personal) do
    Enum.map(fields, fn %__MODULE__{name: name, spec: spec} = field ->
      nested =
        personal
        |> Enum.filter(fn {{field_name, path}, value} -> field_name == name and path != [] and value end)
        |> Enum.sort_by(fn {{_field_name, path}, _value} -> -length(path) end)

      %{field | spec: Enum.reduce(nested, spec, fn {{_field_name, path}, _value}, spec -> wrap(spec, path) end)}
    end)
  end

  defp wrap(spec, []), do: {:personal, spec}

  defp wrap({kind, inner}, [kind | rest]) when kind in @nested_kinds, do: {kind, wrap(inner, rest)}

  defp wrap({:map, key, value}, [:map, :key | rest]), do: {:map, wrap(key, rest), value}
  defp wrap({:map, key, value}, [:map, :value | rest]), do: {:map, key, wrap(value, rest)}
  defp wrap(spec, _path), do: spec

  # ===== интроспекция =====

  @doc false
  @spec introspect(module()) :: [t()] | nil

  def introspect(module) when is_atom(module) do
    if Core.Helper.Module.exports?(module, :__core_fields__, 0), do: module.__core_fields__()
  end

  # ===== типы =====

  @doc false
  @spec read_typespec([t()]) :: keyword(Macro.t())

  def read_typespec(fields) when is_list(fields), do: typespec(fields, :read)

  @doc false
  @spec write_typespec([t()]) :: keyword(Macro.t())

  def write_typespec(fields) when is_list(fields), do: typespec(fields, :write)

  # ---

  # Тип строит грамматика по тем же местам, что и старый `destroyable:`: `%Destroyed{}` встаёт на
  # ПДн-место, а порядок `Destroyed | nil` держит `Core.Codec.Field`.
  defp typespec(fields, mode) do
    fields
    |> Enum.map(fn %__MODULE__{} = field ->
      %Grammar{
        name: field.name,
        spec: plain(field.spec),
        optional?: field.optional?,
        wire: field.wire,
        default: field.default,
        subject: nil,
        personal: field.personal,
        destroyable: destroyable(field, mode)
      }
    end)
    |> Grammar.typespec()
  end

  defp plain({:personal, inner}), do: plain(inner)
  defp plain({kind, inner}) when kind in @nested_kinds, do: {kind, plain(inner)}
  defp plain({:map, key, value}), do: {:map, plain(key), plain(value)}
  defp plain(spec), do: spec

  defp destroyable(%__MODULE__{personal: true}, :read), do: [[]]

  defp destroyable(%__MODULE__{spec: spec}, :read) do
    {_plan, places} = walk_places(spec, [], [], {nil, %{}})
    Enum.uniq(places)
  end

  defp destroyable(_field, :write), do: []

  # ===== ПДн-места =====

  @doc false
  @spec personal_places([t()], [step()]) :: [place_entry()]

  def personal_places(fields, prefix \\ []) when is_list(fields) and is_list(prefix) do
    by_name = Map.new(fields, &{&1.name, &1})

    Enum.flat_map(fields, fn %__MODULE__{} = field -> field_places(field, prefix, :aggregate_id, by_name) end)
  end

  @doc false
  @spec inspect_hidden([t()]) :: [atom()]

  def inspect_hidden(fields) when is_list(fields) do
    Meta.inspect_hidden(fields, %{role: nil, name: nil, where: nil, spec: nil, fields: %{}})
  end

  # ===== обход вида =====

  @doc false
  @spec children(spec()) :: [spec()]

  def children({kind, inner}) when kind in @nested_kinds, do: [inner]
  def children({:map, key, value}), do: [key, value]
  def children({:personal, inner}), do: [inner]
  def children(_spec), do: []

  @doc false
  @spec values(spec()) :: [spec()]

  def values({:map, _key, value}), do: [value]
  def values(spec), do: children(spec)

  @doc false
  @spec walk(spec(), acc, (spec(), acc -> acc)) :: acc when acc: term()

  def walk(spec, acc, fun) when is_function(fun, 2) do
    acc = fun.(spec, acc)

    Enum.reduce(values(spec), acc, &walk(&1, &2, fun))
  end

  # ===== общее =====

  # Один обход вида: места плана (путь и субъект) и места типа (путь в грамматике `destroyable:`).
  # Типы не спускаются в `entity:` — у вложенной структуры свой тип и свои места.
  defp field_places(%__MODULE__{} = field, prefix, subject, by_name) do
    path = prefix ++ [step(field.wire)]
    subject = declared_subject(field.subject, prefix, by_name) || subject
    extra = Meta.plan(path, field, %{role: nil, name: field.name, where: nil, spec: field.spec, fields: by_name})

    case field.personal do
      true ->
        [%{path: path, subject: subject} | extra]

      _declared? ->
        {plan, _places} = walk_places(field.spec, path, [], {subject, by_name})
        plan ++ extra
    end
  end

  # `subject:` не создаёт места: ближайший перекрывает внешний, корневой — `:aggregate_id`.
  defp declared_subject(nil, _prefix, _by_name), do: nil
  defp declared_subject(:aggregate_id, _prefix, _by_name), do: :aggregate_id
  defp declared_subject({:payload, name}, _prefix, by_name), do: {:path, [wire_step(name, by_name)]}
  defp declared_subject({:local, name}, prefix, by_name), do: {:path, prefix ++ [wire_step(name, by_name)]}

  defp wire_step(name, by_name) do
    case Map.fetch(by_name, name) do
      {:ok, %__MODULE__{wire: wire}} -> step(wire)
      :error -> name
    end
  end

  # Путь плана — атомы wire-ключей объявления, а не внешние данные: таблицу атомов он не засоряет.
  # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
  defp step(wire) when is_binary(wire), do: String.to_atom(wire)

  defp walk_places({:personal, _inner}, path, place, {subject, _by_name}),
    do: {[%{path: path, subject: subject}], [place]}

  defp walk_places({:prim, mod}, path, place, {subject, _by_name}) do
    if mod.__domain_personal__(),
      do: {[%{path: path, subject: subject}], [place]},
      else: {[], []}
  end

  defp walk_places({:entity, mod}, path, _place, {subject, _by_name}) do
    case introspect(mod) do
      nil -> {[], []}
      fields -> {entity_places(fields, path, subject), []}
    end
  end

  defp walk_places({:list, inner}, path, place, ctx), do: walk_places(inner, path ++ [:each], place ++ [:list], ctx)

  defp walk_places({:set, inner}, path, place, {subject, _by_name} = ctx) do
    case walk_places(inner, path ++ [:each], place ++ [:set], ctx) do
      {[], _places} -> {[], []}
      _personal -> {[%{path: path, subject: subject}], [place]}
    end
  end

  defp walk_places({:map, key, value}, path, place, {subject, _by_name} = ctx) do
    case walk_places(key, path ++ [:each], place ++ [:value], ctx) do
      {[], _places} -> walk_places(value, path ++ [:each], place ++ [:value], ctx)
      _personal -> {[%{path: path, subject: subject}], [place]}
    end
  end

  defp walk_places({kind, _mod}, _path, _place, _ctx) when kind in ~w(enum union view form jsonb)a, do: {[], []}
  defp walk_places({:type, _type}, _path, _place, _ctx), do: {[], []}

  defp entity_places(fields, path, subject) do
    by_name = Map.new(fields, &{&1.name, &1})

    Enum.flat_map(fields, &field_places(&1, path, subject, by_name))
  end
end
