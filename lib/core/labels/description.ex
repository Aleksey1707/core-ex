defmodule Core.Labels.Description do
  @moduledoc false

  alias Core.Es.Personal.Destroyed
  alias Core.Field
  alias Core.Helper.FieldCheck
  alias Core.Labels.Fields
  alias Core.Labels.Kind
  alias Core.Labels.Walk

  @typedoc "Вид описанного узла: вид сведения, лист без вида или уничтоженное ПДн-значение."
  @type kind ::
          :text
          | :number
          | :date
          | :datetime
          | :user
          | :ref
          | :group
          | :list
          | :set
          | :map
          | :change
          | :destroyed
          | {:unkinded, module()}
          | {:custom, module()}

  @typedoc "Ссылка описанного узла: резолвер и id-значение."
  @type ref :: {module(), struct()}

  @typedoc "Описанный узел видимой формы: подпись, вид, значение и ссылки поддерева."
  @type described :: %{
          label: Walk.label(),
          kind: kind(),
          entity: module() | nil,
          value: term(),
          refs: [ref()]
        }

  @typedoc "Режим описания: `:details` — с презентационным значением, `:refs` — только вид и ссылки."
  @type mode :: :details | :refs

  # Значения, чей порядок задаёт `compare/2` модуля, а не порядок термов.
  @comparable Kind.scalars()

  # Виды, значение которых раскрывается полями struct'а.
  @group_kinds Field.group_kinds()

  # Виды спеки подписей, которым описание даёт вид клаузами `kind/1`; `:text` — extra подписей.
  @shape_kinds ~w(prim enum entity union list set map type text)a

  # Свободная map'а описывается подписями ключа и значения, а не видом `type:`.
  @type_kinds [
    string: :text,
    boolean: :text,
    integer: :number,
    pos_integer: :number,
    non_neg_integer: :number,
    map: nil
  ]

  # ===== описание =====

  @doc "Описать видимую форму struct'а в режиме: `:refs` не считает презентационное значение листа."
  @spec describe(Walk.values(), mode()) :: [described()]

  def describe({:fields, entries}, mode), do: Enum.map(entries, &node(&1, mode))
  def describe({:change, entry}, mode), do: [node(entry, mode)]

  @doc "Описать значение поля с подписью и спекой."
  @spec entry(Walk.label(), Fields.spec(), term()) :: described()

  def entry(label, spec, value), do: node(Walk.entry(label, spec, value), :details)

  # ---

  defp node(%{data: {:change, old, new}} = entry, mode) do
    old = node(old, mode)
    new = node(new, mode)

    %{
      label: entry.label,
      kind: :change,
      entity: nil,
      value: change_value(mode, old, new),
      refs: old.refs ++ new.refs
    }
  end

  defp node(%{data: :leaf} = entry, mode), do: leaf(entry, mode)
  defp node(%{data: {:group, entries}} = entry, mode), do: container(entry, :group, entries, mode)
  defp node(%{data: {:list, entries}} = entry, mode), do: container(entry, :list, entries, mode)

  defp node(%{data: {:set, entries}} = entry, mode),
    do: container(entry, :set, Enum.sort_by(entries, &order(&1.spec, &1.value), &before?/2), mode)

  defp node(%{data: {:map, pairs}, spec: {:type, :map}} = entry, mode),
    do: grouped(entry, :list, Enum.map(pairs, &free_pair(&1, mode)), mode)

  defp node(%{data: {:map, pairs}} = entry, mode) do
    pairs =
      for %{key: key, value: value} <- Enum.sort_by(pairs, &order(&1.key.spec, &1.key.value), &before?/2),
          do: {node(key, mode), node(value, mode)}

    %{
      label: entry.label,
      kind: :map,
      entity: nil,
      value: map_value(mode, pairs),
      refs: Enum.flat_map(pairs, fn {key, value} -> key.refs ++ value.refs end)
    }
  end

  defp container(entry, kind, entries, mode), do: grouped(entry, kind, Enum.map(entries, &node(&1, mode)), mode)

  defp grouped(entry, kind, nodes, mode) do
    %{
      label: entry.label,
      kind: kind,
      entity: nil,
      value: list_value(mode, nodes),
      refs: Enum.flat_map(nodes, & &1.refs)
    }
  end

  defp free_pair(%{key: key, value: value}, mode) do
    key = node(key, mode)
    value = node(value, mode)

    %{
      label: nil,
      kind: :group,
      entity: nil,
      value: list_value(mode, [key, value]),
      refs: key.refs ++ value.refs
    }
  end

  # ---

  defp change_value(:details, old, new), do: %{old: detail(old), new: detail(new)}
  defp change_value(:refs, _old, _new), do: nil

  defp map_value(:details, pairs), do: Enum.map(pairs, fn {key, value} -> %{key: detail(key), value: detail(value)} end)
  defp map_value(:refs, _pairs), do: nil

  defp list_value(:details, nodes), do: Enum.map(nodes, &detail/1)
  defp list_value(:refs, _nodes), do: nil

  # ---

  # Уничтоженное ПДн-значение значения не имеет: правило вида Prim к нему не применяется.
  defp leaf(%{value: %Destroyed{}} = entry, _mode),
    do: %{label: entry.label, kind: :destroyed, entity: nil, value: nil, refs: []}

  defp leaf(%{spec: nil, value: value} = entry, mode), do: inferred(entry, value, mode)
  defp leaf(%{spec: {:prim, module}, value: value} = entry, mode), do: prim(entry, module, value, mode)
  defp leaf(%{spec: spec, value: value} = entry, mode), do: plain(entry, kind(spec), plain_value(mode, spec, value))

  defp inferred(entry, nil, _mode), do: plain(entry, :text, nil)
  defp inferred(entry, flag, _mode) when is_boolean(flag), do: plain(entry, :text, boolean(flag))
  defp inferred(entry, number, _mode) when is_number(number), do: plain(entry, :number, number)
  defp inferred(entry, text, _mode) when is_binary(text), do: plain(entry, :text, text)
  defp inferred(entry, %module{} = value, :details), do: prim(entry, module, value, :details)

  # Не-Prim struct — не лист для словаря ссылок: значение и правило вида Prim не считаются.
  defp inferred(entry, %module{} = value, :refs) do
    if Core.Prim.prim?(module), do: prim(entry, module, value, :refs), else: plain(entry, :text, nil)
  end

  defp plain(entry, kind, value), do: %{label: entry.label, kind: kind, entity: nil, value: value, refs: []}

  # Правило вида Prim — один вызов `Kind.of/1` на лист: из его ответа выходят вид, значение и ссылка.
  defp prim(entry, module, value, mode) do
    rule = Kind.of(module)

    %{
      label: entry.label,
      kind: prim_kind(rule),
      entity: prim_entity(rule),
      value: prim_value(mode, rule, value),
      refs: prim_refs(rule, value)
    }
  end

  defp kind({:enum, _module}), do: :text
  defp kind({:text, _fun}), do: :text
  defp kind({kind, _module}) when kind in @group_kinds, do: :group
  defp kind({:list, _inner}), do: :list
  defp kind({:set, _inner}), do: :set
  defp kind({:map, _key, _value}), do: :map
  defp kind({:type, :map}), do: :list
  defp kind({:type, type}), do: type_kind(type)

  defp prim_kind({:plain, kind}), do: kind
  defp prim_kind({:declared, _owner, {:text, _fun}}), do: :text
  defp prim_kind({:declared, _owner, %{kind: :id}}), do: :text
  defp prim_kind({:declared, _owner, %{kind: :user}}), do: :user
  defp prim_kind({:declared, _owner, %{kind: :ref}}), do: :ref
  defp prim_kind({:unkinded, leaf}), do: {:unkinded, leaf}
  defp prim_kind({:custom, leaf}), do: {:custom, leaf}

  defp prim_entity({:declared, _owner, %{kind: :ref, entity: entity}}), do: entity
  defp prim_entity(_rule), do: nil

  for type <- FieldCheck.type_values(), kind = Keyword.fetch!(@type_kinds, type), not is_nil(kind) do
    defp type_kind(unquote(type)), do: unquote(kind)
  end

  defp plain_value(:details, spec, value), do: plain_value(spec, value)
  defp plain_value(:refs, _spec, _value), do: nil

  defp plain_value(_spec, nil), do: nil
  defp plain_value({:type, :boolean}, true), do: "Да"
  defp plain_value({:type, :boolean}, false), do: "Нет"
  defp plain_value({:enum, module}, value), do: module.label(value)
  defp plain_value({:text, fun}, value), do: fun.(value)
  defp plain_value(_spec, value), do: value

  defp boolean(true), do: "Да"
  defp boolean(false), do: "Нет"

  defp prim_value(:details, rule, prim), do: prim_value(rule, prim)
  defp prim_value(:refs, _rule, _prim), do: nil

  defp prim_value(_rule, nil), do: nil
  defp prim_value({:plain, _kind}, prim), do: prim
  defp prim_value({:declared, owner, {:text, fun}}, prim), do: fun.(Kind.owned(prim, owner))
  defp prim_value({:declared, owner, _id}, prim), do: Kind.owned(prim, owner)
  defp prim_value(_rule, prim), do: prim

  # Ссылка листа — с того же ответа правила вида: id с резолвером, значение владельца объявления.
  defp prim_refs(_rule, nil), do: []
  defp prim_refs({:declared, _owner, %{resolver: nil}}, _prim), do: []
  defp prim_refs({:declared, owner, %{resolver: resolver}}, prim), do: [{resolver, Kind.owned(prim, owner)}]
  defp prim_refs(_rule, _prim), do: []

  defp order({:prim, _module}, prim), do: Core.Prim.unwrap(prim)
  defp order(_spec, value), do: value

  defp before?(%module{} = left, %module{} = right) when module in @comparable,
    do: module.compare(left, right) != :gt

  defp before?(left, right), do: left <= right

  # ===== проекция =====

  @doc "Сведение сведений события: описанный узел без ссылок."
  @spec detail(described()) :: map()

  def detail(node), do: labelled(base(node), node.label)

  # ---

  defp base(%{kind: :destroyed}), do: %{kind: :destroyed}
  defp base(%{kind: :change, value: %{old: old, new: new}}), do: %{kind: :change, old: old, new: new}

  defp base(%{kind: {:unkinded, leaf}}) do
    raise ArgumentError,
          "#{inspect(leaf)}: id без вида в сведениях — `use Core.Labels.ID` после `use Core.Prim.UUID`"
  end

  defp base(%{kind: {:custom, leaf}}) do
    raise ArgumentError,
          "#{inspect(leaf)}: свой вид Prim в сведениях не выходит — `use Core.Labels.ID` или `Core.Labels.Text`"
  end

  defp base(%{kind: :ref, entity: entity, value: value}), do: %{kind: :ref, entity: entity, value: value}
  defp base(%{kind: kind, value: value}), do: %{kind: kind, value: value}

  defp labelled(detail, nil), do: detail
  defp labelled(detail, label), do: Map.put(detail, :label, label)

  # Ратчет полноты: новый вид подписей без клаузы `kind/1` иначе падал бы `FunctionClauseError`
  # в сведениях события, которое собралось.
  Core.Field.Spec.check_kinds!(:labels, @shape_kinds, [:text], "Core.Labels.Description")
end
