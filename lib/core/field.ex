defmodule Core.Field do
  @moduledoc false

  alias Core.Field.Meta
  alias Core.Field.Spec
  alias Core.Helper
  alias Core.Helper.Opts
  alias Core.Prim

  @typedoc false
  @type role :: :struct | :payload | :view | :labels | :union

  @typedoc false
  @type subject :: :aggregate_id | {:payload, atom()} | {:local, atom()}

  @typedoc "Спека значения поля: вид и вложенные спеки; `personal:` метаданных — обёртка места."
  @type spec ::
          Spec.spec()
          | {:personal, spec()}
          | {:personal_false, spec()}

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

  @declarable ~w(struct payload labels)a
  @nested_kinds ~w(list set)a
  @personalable ~w(struct payload labels)a

  # ===== декларация =====

  @doc false
  @spec declare!(term(), role(), String.t(), keyword()) :: [t()]

  def declare!(spec, role, where, context \\ [])

  def declare!(_spec, :union, where, _context) when is_binary(where),
    do: Opts.reject!(where, "у семейства вариантов полей нет")

  # View разбирает спека своего хоста: он знает виды `view:` / `form:` / `jsonb:` и сам отвергает
  # `personal:` / `subject:` текстами роли, поэтому общий `check_keys!` и снятие мест ПДн ему не
  # нужны.
  def declare!(spec, :view, where, context) when is_binary(where) and is_list(context) do
    forms = Keyword.get(context, :forms, [])
    normalize!(parse_view!(spec, where, forms), :view, where)
  end

  def declare!(spec, role, where, _context) when role in @declarable and is_binary(where) do
    {fields, personal} = split!(spec, role, where)
    apply_personal!(normalize!(fields, role, where), personal)
  end

  @doc false
  @spec split!(term(), role(), String.t()) :: {[t()], %{{atom(), [atom()]} => boolean()}}

  # Разбор без реестра метаданных: хосту, который ставит значения между разбором и нормализацией
  # (`Core.Struct`: `default:` вычисляется в теле модуля), нужны обе половины одного прохода.
  def split!(spec, role, where) when role in @declarable and is_binary(where) do
    {clean, personal} = split_personal(spec, role, where)
    declarations = Spec.parse!(clean, role, where)
    fields = Enum.map(declarations, &field!/1)
    check_keys!(clean, role, where)

    {fields, personal}
  end

  @doc false
  @spec normalize!([t()], role(), String.t()) :: [t()]

  def normalize!(fields, role, where) when is_list(fields) and is_binary(where) do
    by_name = Map.new(fields, &{&1.name, &1})

    Enum.map(fields, fn %__MODULE__{} = field ->
      ctx = %{role: role, name: field.name, where: "#{where}: #{field.name}", spec: field.spec, fields: by_name}

      Meta.normalize!(field, ctx)
    end)
  end

  @doc false
  @spec apply_personal!([t()], %{{atom(), [atom()]} => boolean()}) :: [t()]

  def apply_personal!(fields, personal) when is_list(fields) and is_map(personal),
    do: wrap_personal!(fields, personal)

  # ---

  defp field!(declaration) when is_map(declaration) do
    %__MODULE__{
      name: declaration.name,
      wire: declaration.wire,
      spec: declaration.spec,
      optional?: declaration.optional?,
      default: declaration.default,
      personal: declaration.personal,
      subject: declaration.subject
    }
  end

  defp parse_view!(spec, _where, forms) do
    spec
    |> Core.View.Opts.fields!(forms, "fields")
    |> Enum.map(fn %Core.View.Field{name: name, spec: spec, optional?: optional?} ->
      %__MODULE__{
        name: name,
        spec: view_spec(spec),
        optional?: optional?,
        wire: Atom.to_string(name),
        default: :none,
        subject: nil,
        personal: nil
      }
    end)
  end

  # Вид View хранит kind Prim ради своего типа и дампа; в IR его нет — вид значения задаёт Prim.
  defp view_spec({:prim, mod, _kind}), do: {:prim, mod}
  defp view_spec({kind, inner}) when kind in @nested_kinds, do: {kind, view_spec(inner)}
  defp view_spec({:map, key, value}), do: {:map, view_spec(key), view_spec(value)}
  defp view_spec(spec), do: spec

  # Ключ, которого роль не допускает, — тот же отказ, что и неизвестный ключ у грамматики: хост его
  # не знает.
  defp check_keys!(spec, role, where) when is_list(spec),
    do: Enum.each(spec, &check_field_keys(&1, role, where))

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
        |> Enum.filter(fn {{field_name, path}, _value} -> field_name == name and path != [] end)
        |> Enum.sort_by(fn {{_field_name, path}, _value} -> -length(path) end)

      %{field | spec: Enum.reduce(nested, spec, fn {{_field_name, path}, value}, spec -> wrap(spec, path, value) end)}
    end)
  end

  defp wrap(spec, [], true), do: {:personal, spec}
  defp wrap(spec, [], false), do: {:personal_false, spec}

  defp wrap({kind, inner}, [kind | rest], value) when kind in @nested_kinds, do: {kind, wrap(inner, rest, value)}

  defp wrap({:map, key, value}, [:map, :key | rest], nested), do: {:map, wrap(key, rest, nested), value}
  defp wrap({:map, key, value}, [:map, :value | rest], nested), do: {:map, key, wrap(value, rest, nested)}
  defp wrap(spec, _path, _value), do: spec

  # ===== грамматика =====

  @doc false
  @spec kinds() :: [atom()]

  def kinds, do: Spec.kinds()

  @doc false
  @spec kinds(atom()) :: [atom()]

  def kinds(host) when is_atom(host), do: Spec.kinds(host)

  @doc false
  @spec value_module_kinds() :: [atom()]

  def value_module_kinds, do: Spec.value_module_kinds()

  @doc false
  @spec group_kinds() :: [atom()]

  def group_kinds, do: Spec.group_kinds()

  @doc false
  @spec kind_key!(keyword(), atom(), String.t()) :: {atom(), term()}

  def kind_key!(opts, host, where) when is_list(opts) and is_atom(host) and is_binary(where),
    do: Spec.kind_key!(opts, host, where)

  @doc false
  @spec struct_module!(module(), String.t()) :: :ok

  def struct_module!(mod, where) when is_atom(mod) and is_binary(where), do: Spec.struct_module!(mod, where)

  @doc false
  @spec value_spec(module(), String.t()) :: spec()

  def value_spec(mod, where) when is_atom(mod) and is_binary(where), do: Spec.value_spec(mod, where)

  @doc false
  @spec map_opts!(term(), String.t()) :: {keyword(), keyword()}

  def map_opts!(inner, where) when is_binary(where), do: Spec.map_opts!(inner, where)

  @doc false
  @spec check_map_key!(term(), keyword(), String.t()) :: :ok

  def check_map_key!(spec, key_opts, where) when is_binary(where), do: Spec.check_map_key!(spec, key_opts, where)

  @doc false
  @spec union_type([Macro.t()]) :: Macro.t()

  def union_type(types) when is_list(types), do: Spec.union_type(types)

  @doc false
  @spec wire_spec(spec()) :: Spec.spec()

  # Проекция IR на wire-вид: место ПДн (`personal:`) wire-форму не меняет — значение шифруется
  # целиком, а вид остаётся видом вложенного значения.
  def wire_spec({:personal, inner}), do: wire_spec(inner)
  def wire_spec({:personal_false, inner}), do: wire_spec(inner)
  def wire_spec({kind, inner}) when kind in @nested_kinds, do: {kind, wire_spec(inner)}
  def wire_spec({:map, key, value}), do: {:map, wire_spec(key), wire_spec(value)}
  def wire_spec(spec), do: spec

  # ===== интроспекция =====

  @doc false
  @spec introspect(module()) :: [t()] | nil

  def introspect(module) when is_atom(module) do
    if Helper.Module.exports?(module, :__core_fields__, 0),
      do: module.__core_fields__(),
      else: under_compilation(module)
  end

  @doc false
  @spec union_variants(module()) :: [Core.Union.Variant.t()]

  # Реестр вариантов читается протоколом, а не модулем `Core.Union`: обратная ссылка замкнула бы
  # граф сборки (`make xref`).
  def union_variants(family) when is_atom(family) do
    if Helper.Module.exports?(family, :__core_variants__, 0), do: family.__core_variants__(), else: []
  end

  # ---

  # Модуль, который ещё собирается, держит декларацию в атрибуте `@core_fields`: функцию
  # `__core_fields__/0` в его же теле вызвать нельзя. Параллельная сборка может закрыть модуль между
  # проверкой и чтением атрибута — тогда декларации ещё нет.
  defp under_compilation(module) do
    if Module.open?(module), do: Module.get_attribute(module, :core_fields)
  rescue
    ArgumentError -> nil
  end

  # ===== типы =====

  @doc false
  @spec read_typespec([t()]) :: keyword(Macro.t())

  def read_typespec(fields) when is_list(fields), do: typespec(fields, :read)

  @doc false
  @spec write_typespec([t()]) :: keyword(Macro.t())

  def write_typespec(fields) when is_list(fields), do: typespec(fields, :write)

  @doc false
  @spec personal_places?([t()]) :: boolean()

  def personal_places?(fields) when is_list(fields), do: personal_places(fields) != []

  # ---

  # Тип чтения — тот же вид, а на каждом ПДн-месте ещё `Destroyed.t()`; тип записи — проекция вида:
  # `entity:` ссылается на `write_t()` сущности, `union:` — на типы записи вариантов.
  defp typespec(fields, mode) do
    Enum.map(fields, fn %__MODULE__{name: name, spec: spec, optional?: optional?} = field ->
      type = place_type(spec, type_places(field), [], mode)
      {name, Spec.union_type([type | if(optional?, do: [nil], else: [])])}
    end)
  end

  # Места типа — пути `personal_places/2` от самого поля: спуск в `entity:` тип не повторяет, у
  # сущности свой `t()` и свои места.
  defp type_places(%__MODULE__{} = field) do
    for %{path: [_wire | rest]} <- personal_places([field]), do: rest
  end

  defp place_type(spec, places, path, :read) do
    type = spec_type(spec, places, path, :read)

    if path in places, do: Spec.union_type([type, quote(do: Core.Es.Personal.Destroyed.t())]), else: type
  end

  defp place_type(spec, places, path, :write), do: spec_type(spec, places, path, :write)

  # Место целиком (`personal: true` у поля, элемента списка или значения словаря): его вид
  # проецируется без вложенных мест — значение шифруется одним куском.
  defp spec_type({:personal, inner}, _places, _path, mode), do: spec_type(inner, [], [], mode)

  defp spec_type({:personal_false, inner}, places, path, mode), do: spec_type(inner, places, path, mode)

  defp spec_type({:prim, mod}, _places, _path, _mode), do: quote(do: unquote(mod).t())
  defp spec_type({:enum, mod}, _places, _path, _mode), do: quote(do: unquote(mod).t())
  defp spec_type({:entity, mod}, _places, _path, :read), do: quote(do: unquote(mod).t())
  defp spec_type({:entity, mod}, _places, _path, :write), do: entity_write_type(mod)
  defp spec_type({:union, _family}, _places, _path, :read), do: quote(do: struct())
  defp spec_type({:union, family}, _places, _path, :write), do: union_write_type(family)

  defp spec_type({:list, inner}, places, path, mode),
    do: quote(do: [unquote(place_type(inner, places, path ++ [:each], mode))])

  # У элемента `set:` и ключа `map:` своего места нет: ПДн-лист там поднимает границу до контейнера.
  defp spec_type({:set, inner}, _places, _path, mode),
    do: quote(do: MapSet.t(unquote(spec_type(inner, [], [], mode))))

  defp spec_type({:map, key, value}, places, path, mode) do
    key = spec_type(key, [], [], mode)
    value = place_type(value, places, path ++ [:each], mode)

    quote(do: %{optional(unquote(key)) => unquote(value)})
  end

  defp spec_type({:type, :string}, _places, _path, _mode), do: quote(do: String.t())
  defp spec_type({:type, scalar}, _places, _path, _mode), do: quote(do: unquote(scalar)())

  defp entity_write_type(mod) do
    if write_type?(mod),
      do: quote(do: unquote(mod).write_t()),
      else: quote(do: unquote(mod).t())
  end

  # Декларативная структура порождает `write_t()` вместе с `__core_fields__/0`; у собранного
  # вручную модуля тип ищем в байткоде (в сборке того же файла его ещё нет).
  defp write_type?(mod) do
    Helper.Module.exports?(mod, :__core_fields__, 0) or type?(mod, :write_t)
  end

  # Тип записи — тип, а не функция: `function_exported?` его не видит, а байткод модуля видит.
  defp type?(mod, name) do
    case Code.Typespec.fetch_types(mod) do
      {:ok, types} -> Enum.any?(types, &match?({:type, {^name, _, []}}, &1))
      :error -> false
    end
  end

  # Семейство без реестра вариантов (`Core.Union`) типа записи не даёт: остаётся `struct()`.
  # Варианты — из `__core_variants__/0`, у плагина-семейства без реестра — из `types/0`.
  defp union_write_type(family) do
    case union_write_variants(family) do
      [] -> quote(do: struct())
      variants -> Spec.union_type(Enum.map(variants, &variant_write_type/1))
    end
  end

  defp union_write_variants(family) do
    case union_variants(family) do
      [] -> plugin_write_variants(family)
      variants -> Enum.map(variants, &{&1.module, &1.kind})
    end
  end

  defp plugin_write_variants(family) do
    if Helper.Module.exports?(family, :types, 0),
      do: for(mod <- List.wrap(family.types()), is_atom(mod), do: {mod, variant_kind(mod)}),
      else: []
  end

  defp variant_kind(mod) do
    cond do
      Prim.prim?(mod) -> :prim
      Helper.Module.exports?(mod, :__core_fields__, 0) -> :domain
      true -> :manual
    end
  end

  # Тип читается из байткода: у модуля, собранного в том же файле, его может ещё не быть — тогда
  # остаётся структурный тип `%Мод{}`, а не несуществующая ссылка.
  defp variant_write_type({mod, :prim}), do: quote(do: unquote(mod).t())

  defp variant_write_type({mod, _kind}) do
    cond do
      write_type?(mod) -> quote(do: unquote(mod).write_t())
      type?(mod, :t) -> quote(do: unquote(mod).t())
      true -> quote(do: %unquote(mod){})
    end
  end

  # ===== ПДн-места =====

  @doc false
  @spec personal_places([t()], [step()], keyword()) :: [place_entry()]

  # Шаг пути — `:wire` (внешний ключ, форма плана события) или `:name` (имя поля, обход значения
  # на записи). Один обход на обе формы: второй резолв места разошёлся бы с первым.
  def personal_places(fields, prefix \\ [], options \\ []) when is_list(fields) and is_list(prefix) do
    scope = new_scope(fields, options)
    Enum.flat_map(fields, fn %__MODULE__{} = field -> field_places(field, prefix, :aggregate_id, scope) end)
  end

  @doc false
  @spec inspect_hidden([t()]) :: [atom()]

  def inspect_hidden(fields) when is_list(fields) do
    Meta.inspect_hidden(fields, %{role: nil, name: nil, where: nil, spec: nil, fields: %{}})
  end

  @doc false
  @spec inspect_places([t()]) :: %{atom() => [[step()]]}

  # Места `Inspect` — пути, которые читает вывод структуры: спуск в `entity:` не повторяется, у
  # вложенной структуры свой `Inspect`.
  def inspect_places(fields) when is_list(fields) do
    fields
    |> Enum.flat_map(fn %__MODULE__{} = field ->
      paths =
        for %{path: [_wire | rest]} <- personal_places([field]), runtime_path?(field.spec, rest), uniq: true, do: rest

      if paths == [], do: [], else: [{field.name, paths}]
    end)
    |> Map.new()
  end

  @doc false
  @spec hide_personal(term(), [[step()]]) :: term()

  def hide_personal(value, paths) when is_list(paths), do: Enum.reduce(paths, value, &hide_place(&2, &1))

  # ---

  defp new_scope(fields, options) do
    by_name = Map.new(fields, &{&1.name, &1})

    %{by_name: by_name, root: by_name, key: Keyword.get(options, :key, :wire)}
  end

  defp runtime_path?(_spec, []), do: true
  defp runtime_path?({:list, inner}, [:each | rest]), do: runtime_path?(inner, rest)
  defp runtime_path?({:map, _key, value}, [:each | rest]), do: runtime_path?(value, rest)
  defp runtime_path?(_spec, _path), do: false

  defp hide_place(nil, _path), do: nil
  defp hide_place(%Core.Es.Personal.Destroyed{} = value, _path), do: value
  defp hide_place(_value, []), do: %Core.Es.Personal.Hidden{}
  defp hide_place(list, [:each | rest]) when is_list(list), do: Enum.map(list, &hide_place(&1, rest))

  defp hide_place(map, [:each | rest]) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {key, value} -> {key, hide_place(value, rest)} end)

  defp hide_place(value, _path), do: value

  # ===== обход вида =====

  @doc false
  @spec children(spec()) :: [spec()]

  def children({kind, inner}) when kind in @nested_kinds, do: [inner]
  def children({:map, key, value}), do: [key, value]
  def children({:personal, inner}), do: [inner]
  def children({:personal_false, inner}), do: [inner]
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

  defp field_places(%__MODULE__{} = field, prefix, subject, scope) do
    path = prefix ++ [step(field, scope)]
    subject = declared_subject(field.subject, prefix, scope) || subject
    extra = Meta.plan(path, field, %{role: nil, name: field.name, where: nil, spec: field.spec, fields: scope.by_name})

    case field.personal do
      true ->
        [%{path: path, subject: subject} | extra]

      _declared? ->
        {plan, _places} = walk_places(field.spec, path, [], {subject, scope})
        plan ++ extra
    end
  end

  # `subject:` не создаёт места: ближайший перекрывает внешний, корневой — `:aggregate_id`.
  # `{:payload, имя}` — всегда поле корня нагрузки, `{:local, имя}` — соседнее поле той же структуры.
  defp declared_subject(nil, _prefix, _scope), do: nil
  defp declared_subject(:aggregate_id, _prefix, _scope), do: :aggregate_id
  defp declared_subject({:payload, name}, _prefix, scope), do: {:path, [field_step(name, scope.root, scope)]}
  defp declared_subject({:local, name}, prefix, scope), do: {:path, prefix ++ [field_step(name, scope.by_name, scope)]}

  defp field_step(name, by_name, scope) do
    case Map.fetch(by_name, name) do
      {:ok, %__MODULE__{} = field} -> step(field, scope)
      :error -> name
    end
  end

  defp step(%__MODULE__{name: name}, %{key: :name}), do: name
  defp step(%__MODULE__{wire: wire}, _scope), do: step(wire)

  # Путь плана — атомы wire-ключей объявления, а не внешние данные: таблицу атомов он не засоряет.
  # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
  defp step(wire) when is_binary(wire), do: String.to_atom(wire)

  defp walk_places({:personal, _inner}, path, place, {subject, _scope}),
    do: {[%{path: path, subject: subject}], [place]}

  defp walk_places({:personal_false, inner}, path, place, ctx), do: walk_places(inner, path, place, ctx)

  defp walk_places({:prim, mod}, path, place, {subject, _scope}) do
    if mod.__domain_personal__(),
      do: {[%{path: path, subject: subject}], [place]},
      else: {[], []}
  end

  defp walk_places({:entity, mod}, path, _place, {subject, scope}) do
    case introspect(mod) do
      nil -> {[], []}
      fields -> {entity_places(fields, path, subject, scope), []}
    end
  end

  defp walk_places({:list, inner}, path, place, ctx), do: walk_places(inner, path ++ [:each], place ++ [:list], ctx)

  defp walk_places({:set, inner}, path, place, {subject, _scope} = ctx) do
    case walk_places(inner, path ++ [:each], place ++ [:set], ctx) do
      {[], _places} -> {[], []}
      _personal -> {[%{path: path, subject: subject}], [place]}
    end
  end

  defp walk_places({:map, key, value}, path, place, {subject, _scope} = ctx) do
    case walk_places(key, path ++ [:each], place ++ [:value], ctx) do
      {[], _places} -> walk_places(value, path ++ [:each], place ++ [:value], ctx)
      _personal -> {[%{path: path, subject: subject}], [place]}
    end
  end

  defp walk_places({kind, _mod}, _path, _place, _ctx) when kind in ~w(enum union view form jsonb)a, do: {[], []}
  defp walk_places({:type, _type}, _path, _place, _ctx), do: {[], []}

  defp entity_places(fields, path, subject, scope) do
    scope = %{scope | by_name: Map.new(fields, &{&1.name, &1})}

    Enum.flat_map(fields, &field_places(&1, path, subject, scope))
  end
end
