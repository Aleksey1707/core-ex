defmodule Core.Labels.Walk do
  @moduledoc false

  alias Core.Es.Personal.Destroyed
  alias Core.Field
  alias Core.Helper
  alias Core.Labels.Fields

  @typedoc "Подпись значения: поля, стороны изменения, ключа или значения словаря."
  @type label :: String.t() | nil

  @typedoc "Значение объявленной формы: лист, группа видимых полей, элементы списка или множества, пары словаря."
  @type data ::
          :leaf
          | {:group, [entry()]}
          | {:list, [entry()]}
          | {:set, [entry()]}
          | {:map, [pair()]}
          | {:change, entry(), entry()}

  @typedoc "Видимое значение: подпись, спека и значение, а у контейнера — раскрытые элементы."
  @type entry :: %{label: label(), spec: Fields.spec() | nil, value: term(), data: data()}

  @typedoc "Пара словаря: ключ и значение своих видов."
  @type pair :: %{key: entry(), value: entry()}

  @typedoc "Видимая форма struct'а: поля или изменение «было → стало»."
  @type values :: {:fields, [entry()]} | {:change, entry()}

  @typedoc "Место объявления, достижимое из нагрузки события: вид, владелец, поле и модуль значения."
  @type place :: {:prim | :enum | :struct | :family, module(), atom(), module()}

  @typedoc "События кодеков и места объявлений, достижимые из их нагрузок."
  @type declarations :: %{events: [module()], places: [place()]}

  # Виды значения, которые обход раскрывает полями struct'а.
  @group_kinds Field.group_kinds()

  # Виды с модулем значения, которые обход объявлений не раскрывает: Prim и Enum.
  @leaf_kinds Field.value_module_kinds() -- @group_kinds

  # ===== обход значений =====

  @doc "Видимая форма struct'а: поля в порядке спеки или одна запись изменения."
  @spec values(module(), struct()) :: values()

  def values(module, %_{} = struct) when is_atom(module) do
    case Fields.change(module) do
      nil -> {:fields, fields(module, struct)}
      {label, spec} -> {:change, change(label, spec, struct)}
    end
  end

  @doc "Видимое значение поля с подписью и спекой; контейнер раскрывается по объявлению."
  @spec entry(label(), Fields.spec(), term()) :: entry()

  def entry(label, spec, value), do: node(label, spec, value)

  # ---

  defp fields(module, struct) do
    labels = Fields.labels(module)

    for {name, spec} <- Fields.specs(module), do: node(Keyword.fetch!(labels, name), spec, Map.fetch!(struct, name))
  end

  defp change(label, spec, %{old_value: old, new_value: new}) do
    %{label: label, spec: spec, value: nil, data: {:change, node(nil, spec, old), node(nil, spec, new)}}
  end

  defp node(decision, spec, value) do
    spec = variant_spec(spec, value)
    %{label: label(decision), spec: spec, value: value, data: data(decision, spec, value)}
  end

  # Видимое семейство выводится по значению варианта: Prim — листом своей спеки (его вид и текст
  # действуют на значение), struct с объявлением полей — группой; прочее — ошибка программиста.
  defp variant_spec({:union, _family} = spec, %Destroyed{}), do: spec

  defp variant_spec({:union, _family} = spec, %variant{}) do
    cond do
      Core.Prim.prim?(variant) -> {:prim, variant}
      Fields.labelled?(variant) -> spec
      true -> raise ArgumentError, "#{inspect(variant)}: вариант семейства — не Prim и без `use Core.Labels.Fields`"
    end
  end

  defp variant_spec(spec, _value), do: spec

  defp data(_decision, _spec, %Destroyed{}), do: :leaf
  defp data(_decision, _spec, nil), do: :leaf
  defp data(_decision, nil, _value), do: :leaf
  defp data(_decision, {:text, _fun}, _value), do: :leaf
  defp data(_decision, {:prim, _module}, _value), do: :leaf
  defp data(_decision, {:enum, _module}, _value), do: :leaf
  defp data(decision, {:type, :map}, value) when is_map(value), do: {:map, free_pairs(decision, value)}
  defp data(_decision, {:type, _type}, _value), do: :leaf

  defp data(_decision, {kind, _module}, %variant{} = value) when kind in @group_kinds,
    do: {:group, group(variant, value)}

  defp data(_decision, {:list, inner}, items), do: {:list, Enum.map(items, &node(nil, inner, &1))}
  defp data(_decision, {:set, inner}, set), do: {:set, Enum.map(set, &node(nil, inner, &1))}

  defp data(decision, {:map, key, value}, map) do
    {key_decision, value_decision} = pair_labels(decision)

    {:map,
     Enum.map(map, fn {key_value, value_value} ->
       %{key: node(key_decision, key, key_value), value: node(value_decision, value, value_value)}
     end)}
  end

  defp free_pairs(decision, map) do
    {key_label, value_label} = pair_labels(decision)

    for {key, value} <- map,
        do: %{key: node(key_label, nil, key), value: node(value_label, nil, value)}
  end

  defp group(module, value) do
    case values(module, value) do
      {:fields, nodes} -> nodes
      {:change, node} -> [node]
    end
  end

  defp label(label: label, key: _key, value: _value), do: label
  defp label(label), do: label

  defp pair_labels(label: _label, key: key, value: value), do: {key, value}
  defp pair_labels(_label), do: {nil, nil}

  # ===== обход объявлений =====

  @doc "События кодеков и места объявлений, достижимые из их нагрузок."
  @spec declarations([module()]) :: declarations()

  def declarations(modules) when is_list(modules) do
    families = families(modules)
    events = events(modules)
    {places, _seen} = Enum.reduce(events, {[], MapSet.new()}, &declared_event(&1, &2, families))

    %{events: Enum.sort(events), places: places}
  end

  # ---

  defp families(modules) do
    for plugin <- modules,
        Helper.Module.exports?(plugin, :__codec_union__, 0),
        family = plugin.__codec_union__(),
        reduce: %{} do
      acc -> Map.update(acc, family, [plugin], &[plugin | &1])
    end
  end

  defp events(modules) do
    for codec <- modules,
        Core.Es.Event.Codec.codec?(codec),
        event <- codec.__es_mods__(),
        uniq: true,
        do: event
  end

  defp declared_event(event, acc, families) do
    case event.__es_payload__() do
      nil -> acc
      payload -> visit(event, :payload, payload_spec(payload), acc, families)
    end
  end

  defp payload_spec(payload) do
    if Core.Prim.prim?(payload), do: {:prim, payload}, else: {:entity, payload}
  end

  defp visit(owner, field, {kind, module}, acc, _families) when kind in @leaf_kinds,
    do: place(acc, {kind, owner, field, module})

  defp visit(owner, field, {:entity, module}, acc, families),
    do: descend(place(acc, {:struct, owner, field, module}), module, families)

  defp visit(owner, field, {:union, family}, acc, families) do
    case Map.fetch(families, family) do
      {:ok, plugins} ->
        plugins
        |> Enum.flat_map(& &1.__codec_types__())
        |> Enum.reduce(acc, &variant(owner, field, &1, &2, families))

      :error ->
        place(acc, {:family, owner, field, family})
    end
  end

  defp visit(owner, field, spec, acc, families),
    do: Enum.reduce(Field.children(spec), acc, &visit(owner, field, &1, &2, families))

  # Вариант семейства объявляет себя по-своему: Prim — видом (или текстом) значения на месте
  # `prim:`, struct — решением по полям на месте `struct:`.
  defp variant(owner, field, module, acc, families) when is_atom(module) do
    if Core.Prim.prim?(module),
      do: place(acc, {:prim, owner, field, module}),
      else: visit(owner, field, {:entity, module}, acc, families)
  end

  defp place({places, seen}, place), do: {[place | places], seen}

  defp descend({places, seen} = acc, module, families) do
    if MapSet.member?(seen, module) or not Fields.labelled?(module) do
      acc
    else
      module
      |> Fields.visible()
      |> Enum.reduce({places, MapSet.put(seen, module)}, fn {name, spec}, acc ->
        visit(module, name, spec, acc, families)
      end)
    end
  end
end
