defmodule Core.Es.Personal.Plan do
  @moduledoc false

  # ПДн-план объявления: места (путь и субъект) и защита записи по нему. Обход один —
  # `Core.Field.personal_places/3`: здесь только формы пути (`:wire` для плана события, `:name`
  # для обхода значения), проверки объявления и runtime-отказы записи.

  alias Core.Es.Personal.Destroyed
  alias Core.Field
  alias Core.Helper.Opts

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

  # Временный адаптер `__es_subjects__/0`: только места верхнего уровня, субъект — `:aggregate_id`
  # или имя поля нагрузки. Уходит вместе с переездом потребителей (07/08).
  @doc false
  @spec subjects([Field.t()]) :: [{atom(), atom()}]

  def subjects(fields) when is_list(fields) do
    by_wire = Map.new(fields, &{wire_step(&1.wire), &1.name})

    for %{path: [wire], subject: subject} <- entries(fields),
        do: {Map.fetch!(by_wire, wire), subject_name(subject, by_wire)}
  end

  # ---

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

  defp subject_name(:aggregate_id, _by_wire), do: :aggregate_id
  defp subject_name({:path, [wire | _rest]}, by_wire), do: Map.get(by_wire, wire, wire)

  # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
  defp wire_step(wire) when is_binary(wire), do: String.to_atom(wire)

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

  defp longest_prefix(path, ancestors) do
    size = length(path)

    Enum.find(Enum.map(0..size, &Enum.take(path, size - &1)), &Map.has_key?(ancestors, &1))
  end

  defp fetch(%{} = value, step), do: Map.get(value, step)
  defp fetch(_value, _step), do: nil

  defp label(path), do: Enum.map_join(path, ".", &if(&1 == :each, do: "each", else: Atom.to_string(&1)))
end
