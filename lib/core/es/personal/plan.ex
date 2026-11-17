defmodule Core.Es.Personal.Plan do
  @moduledoc false

  # ПДн-план объявления: места (путь и субъект) и защита записи по нему. Обход один —
  # `Core.Field.personal_places/3`: здесь только формы пути (`:wire` для плана события, `:name`
  # для обхода значения), проверки объявления и runtime-отказы записи.

  alias Core.Error
  alias Core.Es.Personal.Destroyed
  alias Core.Es.Personal.Marker
  alias Core.Field
  alias Core.Helper.Opts

  require Error

  @type entry :: Field.place_entry()
  @type value_path :: [atom() | :each]

  # ===== план =====

  @doc false
  @spec entries([Field.t()]) :: [entry()]

  def entries(fields) when is_list(fields), do: Field.personal_places(fields)

  @doc false
  @spec runtime_entries([Field.t()]) :: [entry()]

  def runtime_entries(fields) when is_list(fields), do: Field.personal_places(fields, [], key: :name)

  @doc false
  @spec entries!([Field.t()], String.t(), keyword()) :: [entry()]

  # Проверки объявления — до плана: субъект без ПДн-места, переопределение под `personal: true`,
  # непрозрачный тип без `personal:`, субъект не UUID или сам ПДн, обязательное место при
  # необязательном субъекте. `uuid_prim:` — проверка Prim субъекта, её даёт хост (`Es.Event.Payload`).
  def entries!(fields, where, options \\ []) when is_list(fields) and is_binary(where) do
    uuid_prim = Keyword.get(options, :uuid_prim, fn _mod -> false end)
    plan = entries(fields)
    root = by_name(fields)

    validate_fields(fields, root, root, [], plan, uuid_prim, where)

    plan
  end

  @doc false
  @spec place?([entry()], value_path()) :: boolean()

  def place?(entries, path) when is_list(entries) and is_list(path),
    do: Enum.any?(entries, &(&1.path == path))

  @doc false
  @spec places_under?([entry()], value_path()) :: boolean()

  def places_under?(entries, path) when is_list(entries) and is_list(path),
    do: Enum.any?(entries, &List.starts_with?(&1.path, path))

  # Места одного поля: путь от значения поля — без первого шага (wire-ключа объявления).
  @doc false
  @spec under([entry()], atom()) :: [entry()]

  def under(entries, step) when is_list(entries) and is_atom(step) do
    for %{path: [^step | rest]} = entry <- entries, do: %{entry | path: rest}
  end

  # План нагрузки по её модулю: `:places` — пути wire-ключей объявления (план события),
  # `:runtime_places` — имена полей (обход значения). Нагрузка-Prim с `personal: true` — корневое
  # место `path: []`; сущность/плагин с общей декларацией — места её полей; у нагрузки без ПДн —
  # пусто. Один обход декларации `Core.Field.personal_places/3`, не второй.
  @doc false
  @spec places(module()) :: [entry()]

  def places(payload) when is_atom(payload), do: payload_places(payload, :wire)

  @doc false
  @spec runtime_places(module()) :: [entry()]

  def runtime_places(payload) when is_atom(payload), do: payload_places(payload, :name)

  # Маркеры ПДн-значений по плану на dumped wire-карте нагрузки: открытое значение места
  # заменяется `%Core.Es.Personal.Marker{}` с субъектом; `nil` необязательного места остаётся
  # `nil`, готовый маркер (уничтоженное значение верхнеуровневого поля) не перезаписывается.
  @doc false
  @spec mark!(map(), [entry()], String.t() | nil) :: map()

  def mark!(payload, entries, aggregate_id)
      when is_map(payload) and is_list(entries) and (is_binary(aggregate_id) or is_nil(aggregate_id)) do
    Enum.reduce(entries, payload, &mark_entry(&2, &1, payload, aggregate_id))
  end

  # ---

  defp mark_entry(payload, %{path: path, subject: subject}, root, aggregate_id) do
    mark_at(payload, path, [], %{[] => root}, fn value, ancestors ->
      marker(value, subject_value(subject, ancestors, root, aggregate_id))
    end)
  end

  defp mark_at(value, [], _decl, ancestors, fun), do: fun.(value, ancestors)

  defp mark_at(value, [:each | rest], decl, ancestors, fun) when is_list(value) do
    Enum.map(
      value,
      &mark_at(&1, rest, decl ++ [:each], Map.put(ancestors, decl ++ [:each], &1), fun)
    )
  end

  defp mark_at(value, [:each | rest], decl, ancestors, fun) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, inner} ->
      {key, mark_at(inner, rest, decl ++ [:each], Map.put(ancestors, decl ++ [:each], inner), fun)}
    end)
  end

  defp mark_at(value, [step | rest], decl, ancestors, fun)
       when is_atom(step) and is_map(value) and not is_struct(value) do
    key = Atom.to_string(step)

    case Map.fetch(value, key) do
      {:ok, inner} ->
        Map.put(value, key, mark_at(inner, rest, decl ++ [step], Map.put(ancestors, decl ++ [step], inner), fun))

      :error ->
        value
    end
  end

  defp mark_at(value, _path, _decl, _ancestors, _fun), do: value

  defp marker(nil, _subject), do: nil
  defp marker(%Marker{} = marker, _subject), do: marker
  defp marker(value, subject), do: %Marker{subject: subject, value: value}

  defp subject_value(:aggregate_id, _ancestors, _root, aggregate_id), do: aggregate_id

  defp subject_value({:path, path}, ancestors, root, _aggregate_id) do
    prefix = longest_prefix(path, ancestors)

    path
    |> Enum.drop(length(prefix))
    |> Enum.reduce(Map.get(ancestors, prefix, root), fn
      :each, acc -> acc
      step, acc -> wire_fetch(acc, step)
    end)
  end

  # Субъект плана резолвится по dumped wire-карте: её ключи — строки, шаг пути — атом wire-ключа.
  defp wire_fetch(%{} = value, step) when is_atom(step), do: Map.get(value, Atom.to_string(step))
  defp wire_fetch(%{} = value, step), do: Map.get(value, step)
  defp wire_fetch(_value, _step), do: nil

  defp validate_fields(fields, scope, root, prefix, plan, uuid_prim, where) do
    Enum.each(fields, fn %Field{} = field ->
      field_where = "#{where}: #{field.name}"
      path = prefix ++ [wire_step(field.wire)]

      validate_subject!(field, scope, root, path, plan, uuid_prim, field_where)

      if field.personal == true,
        do: reject_sealed!(field.spec, field_where),
        else: walk_spec(field.spec, field.personal, root, path, plan, uuid_prim, field_where)
    end)
  end

  defp validate_subject!(%Field{subject: nil}, _scope, _root, _path, _plan, _uuid_prim, _where), do: :ok

  defp validate_subject!(%Field{} = field, scope, root, path, plan, uuid_prim, where) do
    case field.subject do
      :aggregate_id -> :ok
      {:payload, name} -> validate_target!(field, name, root, uuid_prim, where)
      {:local, name} -> validate_target!(field, name, scope, uuid_prim, where)
    end

    unless places_under?(plan, path) do
      Opts.reject!(
        where,
        "subject: #{inspect(field.subject)} — в поддереве нет ПДн-места, субъект ни к чему не относится"
      )
    end
  end

  defp validate_target!(%Field{name: name}, name, _scope, _uuid_prim, where),
    do: Opts.reject!(where, "subject: #{inspect(name)} — поле не бывает своим субъектом")

  defp validate_target!(%Field{} = field, name, scope, uuid_prim, where) do
    case Map.fetch(scope, name) do
      :error ->
        Opts.reject!(where, "subject: #{inspect(name)} — нет такого поля нагрузки")

      {:ok, %Field{subject: subject}} when subject != nil ->
        Opts.reject!(where, "субъект #{name} сам объявлен с subject:")

      {:ok, %Field{} = target} ->
        cond do
          personal_field?(target) ->
            Opts.reject!(where, "субъект #{name} — ПДн-значение: поле-субъект не бывает персональным")

          not uuid_spec?(target.spec, uuid_prim) ->
            Opts.reject!(where, "субъект #{name} — не Prim.UUID и не Prim.Compose над ним")

          target.optional? and not field.optional? ->
            Opts.reject!(
              where,
              "обязательное при необязательном субъекте #{name} — непустое ПДн-значение осталось бы без субъекта"
            )

          true ->
            :ok
        end
    end
  end

  # `subject:` под `personal: true` недостижим: спуск в место остановлен.
  defp reject_sealed!({:entity, mod}, where) do
    case Field.introspect(mod) do
      nil ->
        :ok

      fields ->
        Enum.each(fields, &reject_sealed_field!(&1, where))
    end
  end

  defp reject_sealed!({kind, inner}, where) when kind in ~w(list set personal personal_false)a,
    do: reject_sealed!(inner, where)

  defp reject_sealed!({:map, key, value}, where) do
    reject_sealed!(key, where)
    reject_sealed!(value, where)
  end

  defp reject_sealed!(_spec, _where), do: :ok

  defp reject_sealed_field!(%Field{} = field, where) do
    if field.subject != nil,
      do: Opts.reject!(where, "subject: под personal: true — переопределение субъекта за ПДн-границей")

    reject_sealed!(field.spec, where)
  end

  defp walk_spec({:personal, inner}, _declared, _root, _path, _plan, _uuid_prim, where) do
    reject_sealed!(inner, where)
    :ok
  end

  defp walk_spec({:personal_false, inner}, _declared, root, path, plan, uuid_prim, where),
    do: walk_spec(inner, false, root, path, plan, uuid_prim, where)

  defp walk_spec({:entity, mod}, declared, root, path, plan, uuid_prim, where) do
    case Field.introspect(mod) do
      nil ->
        if is_nil(declared) do
          Opts.reject!(
            where,
            "сущность #{inspect(mod)} без общей декларации — укажите personal: true или personal: false"
          )
        end

      fields ->
        validate_fields(fields, by_name(fields), root, path, plan, uuid_prim, where)
    end
  end

  defp walk_spec({:union, mod}, declared, _root, _path, _plan, _uuid_prim, where) do
    if is_nil(declared) do
      Opts.reject!(where, "семейство #{inspect(mod)} — укажите personal: true или personal: false")
    end
  end

  defp walk_spec({:type, :map}, declared, _root, _path, _plan, _uuid_prim, where) do
    if is_nil(declared), do: Opts.reject!(where, "вид type: :map — укажите personal: true или personal: false")
  end

  defp walk_spec({kind, inner}, declared, root, path, plan, uuid_prim, where) when kind in ~w(list set)a do
    walk_spec(inner, declared, root, path ++ [:each], plan, uuid_prim, where)
  end

  defp walk_spec({:map, key, value}, declared, root, path, plan, uuid_prim, where) do
    walk_spec(key, declared, root, path ++ [:each], plan, uuid_prim, where)
    walk_spec(value, declared, root, path ++ [:each], plan, uuid_prim, where)
  end

  defp walk_spec(_spec, _declared, _root, _path, _plan, _uuid_prim, _where), do: :ok

  defp by_name(fields), do: Map.new(fields, &{&1.name, &1})

  defp personal_field?(%Field{} = field) do
    field.personal == true or personal_spec?(field.spec)
  end

  defp personal_spec?({:personal, _inner}), do: true
  defp personal_spec?({:personal_false, inner}), do: personal_spec?(inner)
  defp personal_spec?({:prim, mod}), do: mod.__domain_personal__()
  defp personal_spec?(_spec), do: false

  defp uuid_spec?({:prim, mod}, uuid_prim), do: uuid_prim.(mod)
  defp uuid_spec?({:personal, inner}, uuid_prim), do: uuid_spec?(inner, uuid_prim)
  defp uuid_spec?({:personal_false, inner}, uuid_prim), do: uuid_spec?(inner, uuid_prim)
  defp uuid_spec?(_spec, _uuid_prim), do: false

  defp payload_places(payload, key) do
    cond do
      Core.Prim.prim?(payload) ->
        if payload.__domain_personal__(), do: [%{path: [], subject: :aggregate_id}], else: []

      fields = Field.introspect(payload) ->
        Field.personal_places(fields, [], key: key)

      true ->
        []
    end
  end

  # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
  defp wire_step(wire) when is_binary(wire), do: String.to_atom(wire)

  # ===== загрузка ПДн-мест =====

  @doc """
  Wire-значение поля → значение с `%Core.Es.Personal.Destroyed{}` на каждом ПДн-месте.

  `{"$pd": null}` на месте заменяется **до** разбора вида (у `union:` с `personal: true` — до
  выбора варианта, ручной Codec не вызывается); `nil` необязательного места остаётся `nil`.
  Оставшийся маркер — отказ: `{"$pd": "<строка>"}` — `:sealed_personal_value`, иное —
  `:invalid_value` (`ns: :codec`). `entries` — места от значения поля (`under/2`).
  """
  @spec load(term(), [entry()], module(), atom()) :: Core.Result.t()

  def load(value, entries, type, field) when is_list(entries) and is_atom(type) and is_atom(field) do
    loaded = Enum.reduce(entries, value, &destroyed(&2, &1.path))

    case left_marker(loaded) do
      :none -> {:ok, loaded}
      {:marker, sealed} -> {:error, marker_error(type, field, sealed)}
    end
  end

  @doc false
  @spec marker_error(module(), atom(), term()) :: Error.t()

  def marker_error(type, name, sealed) when is_atom(type) and is_atom(name) and is_binary(sealed) do
    Error.domain(type,
      code: :sealed_personal_value,
      ns: :codec,
      message: "#{inspect(type)}: поле #{name} — ПДн-значение не расшифровано",
      detail: %{field: name}
    )
  end

  def marker_error(type, name, _sealed) when is_atom(type) and is_atom(name) do
    Error.domain(type,
      code: :invalid_value,
      ns: :codec,
      message: "#{inspect(type)}: поле #{name} — маркер ПДн-значения не на месте",
      detail: %{field: name}
    )
  end

  # ---

  defp destroyed(%{"$pd" => nil} = marker, []) when map_size(marker) == 1, do: %Destroyed{}
  defp destroyed(value, []), do: value

  defp destroyed(list, [:each | rest]) when is_list(list),
    do: Enum.map(list, &destroyed(&1, rest))

  defp destroyed(map, [:each | rest]) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {key, item} -> {key, destroyed(item, rest)} end)

  defp destroyed(map, [step | rest]) when is_map(map) and not is_struct(map) and is_atom(step) do
    key = Atom.to_string(step)

    case Map.fetch(map, key) do
      {:ok, item} -> Map.put(map, key, destroyed(item, rest))
      :error -> map
    end
  end

  defp destroyed(value, _path), do: value

  # Маркер вне ПДн-места (или неразобранный шифротекст на месте) — отказ загрузки поля.
  defp left_marker(%{"$pd" => sealed} = marker) when map_size(marker) == 1, do: {:marker, sealed}
  defp left_marker(%_{} = _struct), do: :none

  defp left_marker(map) when is_map(map),
    do: Enum.find_value(map, :none, fn {_key, item} -> found(left_marker(item)) end)

  defp left_marker(list) when is_list(list), do: Enum.find_value(list, :none, &found(left_marker(&1)))
  defp left_marker(_value), do: :none

  defp found(:none), do: nil
  defp found(found), do: found

  # ===== защита записи =====

  @doc """
  Отказ записи по плану: `%Destroyed{}` на любом месте и непустое ПДн-значение при `nil` субъекте.

  `values` — значение корня объявления (нагрузка события, `old_value`/`new_value` которого лежат
  по путям плана). `aggregate_id: :unknown` — субъекта ещё нет (`new/N`, `draft/1`); `nil` —
  субъекта нет и непустое ПДн не записывается (`dump`). `allow:` — пути, где уничтоженное значение
  законно (верхнеуровневое поле с `subject:` уходит маркером).
  """
  @spec assert_writable!(term(), [entry()], keyword()) :: :ok

  def assert_writable!(values, entries, options \\ []) when is_list(entries) do
    aggregate_id = Keyword.get(options, :aggregate_id, :unknown)
    allow = Keyword.get(options, :allow, [])

    Enum.each(entries, &check_place(values, &1, aggregate_id, allow))

    :ok
  end

  # ---

  defp check_place(values, %{path: path, subject: subject}, aggregate_id, allow) do
    if Enum.any?(allow, &List.starts_with?(path, &1)) do
      :ok
    else
      each_place(values, path, [], %{[] => values}, subject, aggregate_id)
    end
  end

  defp each_place(value, [], prefix, ancestors, subject, aggregate_id),
    do: check_value(value, prefix, ancestors, subject, aggregate_id)

  defp each_place(value, [:each | rest], prefix, ancestors, subject, aggregate_id) when is_list(value) do
    Enum.each(
      value,
      &each_place(&1, rest, prefix ++ [:each], Map.put(ancestors, prefix ++ [:each], &1), subject, aggregate_id)
    )
  end

  defp each_place(value, [:each | rest], prefix, ancestors, subject, aggregate_id)
       when is_map(value) and not is_struct(value) do
    Enum.each(value, fn {_key, item} ->
      each_place(item, rest, prefix ++ [:each], Map.put(ancestors, prefix ++ [:each], item), subject, aggregate_id)
    end)
  end

  defp each_place(%{} = value, [step | rest], prefix, ancestors, subject, aggregate_id) when is_atom(step) do
    case Map.fetch(value, step) do
      {:ok, inner} ->
        each_place(inner, rest, prefix ++ [step], Map.put(ancestors, prefix ++ [step], inner), subject, aggregate_id)

      :error ->
        :ok
    end
  end

  defp each_place(_value, _path, _prefix, _ancestors, _subject, _aggregate_id), do: :ok

  defp check_value(%Destroyed{}, path, _ancestors, _subject, _aggregate_id) do
    raise ArgumentError,
          "ПДн-место #{label(path)}: уничтоженное значение нельзя записать в новое событие"
  end

  defp check_value(nil, _path, _ancestors, _subject, _aggregate_id), do: :ok

  defp check_value(_value, _path, _ancestors, :aggregate_id, :unknown), do: :ok

  defp check_value(_value, path, ancestors, subject, aggregate_id) do
    if is_nil(subject_value(subject, aggregate_id, ancestors)) do
      raise ArgumentError, "ПДн-место #{label(path)}: непустое ПДн-значение без субъекта"
    end

    :ok
  end

  defp subject_value(:aggregate_id, aggregate_id, _ancestors), do: aggregate_id

  defp subject_value({:path, path}, _aggregate_id, ancestors) do
    prefix = longest_prefix(path, ancestors)

    path
    |> Enum.drop(length(prefix))
    |> Enum.reduce(Map.get(ancestors, prefix), fn
      :each, acc -> acc
      step, acc -> fetch(acc, step)
    end)
  end

  defp fetch(%{} = value, step), do: Map.get(value, step)
  defp fetch(_value, _step), do: nil

  defp label(path), do: Enum.map_join(path, ".", &if(&1 == :each, do: "each", else: Atom.to_string(&1)))

  # ===== общее =====

  # Путь плана и путь значения: префикс, на котором сошлись место и субъект (в том числе общий
  # `:each` элемента списка).
  defp longest_prefix(path, ancestors) do
    size = length(path)

    Enum.find(Enum.map(0..size, &Enum.take(path, size - &1)), &Map.has_key?(ancestors, &1))
  end
end
