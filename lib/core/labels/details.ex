defmodule Core.Labels.Details do
  @moduledoc """
  Название и сведения события: чистая функция «событие → `{название, сведения}`» (ADR-0063).

  Обходит нагрузку по объявлениям — название события и подпись нагрузки-Prim
  (`Core.Labels.Event`), подписи полей нагрузки (`Core.Labels.Fields`), подписи значений Enum
  (`Core.Labels.Values`), вид id (`Core.Labels.ID`), текст Prim (`Core.Labels.Text`) — и отдаёт
  список сведений из Prim-значений. Дампа и имён нет: значения — Prim как есть, в JSON их переводит
  wire, а имя по id ставит словарь ссылок.

  Сведение — `%{label, kind, value}`. Вид — по спеке поля (`Core.Labels.Fields.specs/1`):

  | `kind` | Спека поля → `value` |
  |---|---|
  | `:text` | Prim `:string`, `type: :string` → как есть; `type: :boolean` → «Да» / «Нет»; `enum:` → подпись |
  | `:text` | `text:`, Prim с `Core.Labels.Text` → текст функции; id `kind: :id` → id |
  | `:number` | Prim `kind: :integer`, `kind: :decimal`, `type:` целого → как есть |
  | `:date`, `:datetime` | Prim `kind: :date`, `kind: :datetime` → как есть |
  | `:user` | id `kind: :user` → id |
  | `:ref` | id `kind: :ref` → id; рядом `entity` — вид записи |
  | `:group` | `entity:` → сведения полей struct'а; `union:` → группа варианта-struct по его `Core.Labels.Fields` или лист варианта-Prim по его спеке: спека листа — модуль варианта, а не семейства |
  | `:list` | `list:` → элементы `%{kind, value}` вида спеки элемента, без подписи |
  | `:set` | `set:` → элементы `%{kind, value}` вида спеки элемента, без подписи, в каноническом порядке |
  | `:map` | `map:` → пары `%{key, value}`: ключ и значение — `%{kind, value}` своих видов; с подписями `[label:, key:, value:]` — с подписью стороны |
  | `:list` | `type: :map` с подписями `[label:, key:, value:]` → группы «ключ — значение» |
  | `:destroyed` | поле с `subject:`, на месте значения `%Core.Es.Personal.Destroyed{}` → без `value` |

  Порядок множества в сведениях — для человека, по возрастанию значения элемента: у Prim — базового
  значения (`Core.Prim.unwrap/1`), у даты, дата-времени, времени и `Decimal` — по `compare/2` своего
  модуля, то есть хронологический и числовой. С порядком wire множества (по JSON-кодировке wire
  элемента, ADR-0091) он сознательно не сверяется: у целых и `Decimal` порядок wire строковый
  (`10` раньше `2`). Пары словаря идут по возрастанию значения ключа.

  Prim-композит (`Core.Prim.Compose`) выходит видом своего базового Prim, значение — композит как есть.
  Объявление вида id или текста у базы композита действует и на композит: значение — база с
  объявлением, текст — функция от неё.

  Видимое семейство (`union:`) выводится по значению варианта: вариант-Prim — листом по спеке
  модуля варианта (объявления вида и текста действуют на вариант, включая цепочку композита),
  вариант-struct с `Core.Labels.Fields` — группой его видимых полей. Неподдерживаемый вариант (struct
  без `Core.Labels.Fields`, не Prim) и Prim со своим видом (`kind:` без `Core.Labels.ID` и
  `Core.Labels.Text`) — `ArgumentError` с именем модуля.

  Map'а с id в ключах выходит списком групп, по группе на пару: ключ с подписью `key:`, значение с
  подписью `value:`; вид каждого — по самому значению (Prim, строка, число, `boolean`, `nil`). Ключи
  выходят ссылками, только если нагрузка загружена с Prim в ключах (ручной плагин): `type: :map`
  плагина по полям грузит map'у как есть, и ключи-строки выходят текстом.

  Prim-идентификатор (`Core.Prim.UUID`) без `use Core.Labels.ID` и без `use Core.Labels.Text` —
  `ArgumentError` с именем модуля: ошибка программиста, а не текст в сведениях.

  Struct изменения (`change:`) выходит одним сведением `%{label, kind: :change, old, new}`: подпись —
  `change:`, стороны `old` / `new` — `%{kind, value}` по виду значения изменения, без подписи; сторона
  без значения — `value: nil`.

  Вид `type:` задан на каждое значение списка типов проверки полей
  (`Core.Helper.FieldCheck.type_values/0`): новый тип без вида не собирает библиотеку.

  Сведения идут в порядке спеки полей; поле `:hidden` в них не попадает. Поле без значения —
  сведение с `value: nil` и своим видом; нагрузка `nil` — пустые сведения; нагрузка-Prim — одно
  сведение с подписью `payload:` события.

  Уничтоженное ПДн-значение (`%Core.Es.Personal.Destroyed{}` в поле с `subject:`, ADR-0074) —
  сведение `%{label, kind: :destroyed}` без `value` (и без `entity` у поля-ссылки), сторона
  изменения — `%{kind: :destroyed}`: вид задаёт форму `value`, а значения у поля нет.
  """

  alias Core.Es
  alias Core.Es.Personal.Destroyed
  alias Core.Field
  alias Core.Helper.FieldCheck
  alias Core.Labels.Kind
  alias Core.Labels.Walk

  @typedoc "Вид значения сведения."
  @type kind :: :text | :number | :date | :datetime | :user | :ref | :group | :list | :set | :map | :destroyed

  @typedoc "Значение сведения: Prim, строка, число, сведения группы, элементы списка или множества, пары словаря."
  @type value :: struct() | String.t() | number() | [t()] | [item()] | [pair()] | nil

  @typedoc """
  Сведение: подписанное значение со своим видом, ссылка на запись, изменение «было → стало» или
  уничтоженное ПДн-значение без значения.
  """
  @type t ::
          %{label: String.t(), kind: kind(), value: value()}
          | %{label: String.t(), kind: :ref, entity: atom(), value: struct() | nil}
          | %{label: String.t(), kind: :change, old: item(), new: item()}
          | %{label: String.t(), kind: :destroyed}

  @typedoc "Элемент списка: значение со своим видом, без подписи."
  @type item ::
          %{kind: kind(), value: value()}
          | %{kind: :ref, entity: atom(), value: struct() | nil}
          | %{kind: :destroyed}

  @typedoc "Пара словаря: ключ и значение своих видов; подписаны, если у поля подписи ключа и значения."
  @type pair :: %{key: item() | t(), value: item() | t()}

  # Значения, чей порядок задаёт `compare/2` модуля, а не порядок термов.
  @comparable Kind.scalars()

  # Виды, значение которых раскрывается сведениями полей struct'а.
  @group_kinds Field.group_kinds()

  # Свободная map'а выходит подписями ключа и значения, а не видом `type:`: вида у неё нет, но ответ на неё дан.
  @type_kinds [
    string: :text,
    boolean: :text,
    integer: :number,
    pos_integer: :number,
    non_neg_integer: :number,
    map: nil
  ]

  @doc "Название и сведения события."
  @spec build(Es.Event.t()) :: {String.t(), [t()]}

  def build(%event{payload: payload}) when is_atom(event), do: {event.__label_title__(), details(event, payload)}

  # ---

  defp details(_event, nil), do: []

  defp details(event, payload) do
    case event.__label_payload__() do
      nil -> struct_details(payload)
      label -> [describe(Walk.entry(label, {:prim, event.__es_payload__()}, payload))]
    end
  end

  defp struct_details(%module{} = struct) do
    case Walk.values(module, struct) do
      {:fields, nodes} -> Enum.map(nodes, &describe/1)
      {:change, node} -> [describe(node)]
    end
  end

  defp describe(%{data: {:change, old, new}} = node),
    do: %{label: node.label, kind: :change, old: item(old), new: item(new)}

  defp describe(node), do: item(node)

  defp item(%{data: :leaf} = node), do: labelled(leaf(node), node.label)

  defp item(%{data: {:group, nodes}} = node),
    do: labelled(%{kind: :group, value: Enum.map(nodes, &describe/1)}, node.label)

  defp item(%{data: {:list, nodes}} = node), do: labelled(%{kind: :list, value: Enum.map(nodes, &item/1)}, node.label)

  defp item(%{data: {:set, nodes}} = node),
    do: labelled(%{kind: :set, value: Enum.map(sorted(nodes), &item/1)}, node.label)

  defp item(%{data: {:map, pairs}, spec: {:type, :map}} = node),
    do: labelled(%{kind: :list, value: Enum.map(pairs, &free_pair/1)}, node.label)

  defp item(%{data: {:map, pairs}} = node),
    do: labelled(%{kind: :map, value: Enum.map(sorted_pairs(pairs), &pair/1)}, node.label)

  defp labelled(item, nil), do: item
  defp labelled(item, label), do: Map.put(item, :label, label)

  defp leaf(%{value: %Destroyed{}}), do: %{kind: :destroyed}

  defp leaf(%{spec: spec, value: value}),
    do: Map.put(shape_of(spec, value), :value, leaf_value(spec, value))

  defp pair(%{key: key, value: value}), do: %{key: item(key), value: item(value)}

  defp free_pair(%{key: key, value: value}), do: %{kind: :group, value: [describe(key), describe(value)]}

  defp shape_of({:type, :map}, _value), do: %{kind: :list}
  defp shape_of(nil, value), do: shape(inferred(value))
  defp shape_of(spec, _value), do: shape(spec)

  defp shape({:prim, module}), do: prim_shape(module)
  defp shape({:enum, _module}), do: %{kind: :text}
  defp shape({:text, _fun}), do: %{kind: :text}
  defp shape({kind, _module}) when kind in @group_kinds, do: %{kind: :group}
  defp shape({:list, _inner}), do: %{kind: :list}
  defp shape({:set, _inner}), do: %{kind: :set}
  defp shape({:map, _key, _value}), do: %{kind: :map}
  defp shape({:type, type}), do: %{kind: type_kind(type)}

  defp prim_shape(module) do
    case Kind.of(module) do
      {:plain, kind} ->
        %{kind: kind}

      {:declared, _owner, {:text, _fun}} ->
        %{kind: :text}

      {:declared, _owner, %{kind: :id}} ->
        %{kind: :text}

      {:declared, _owner, %{kind: :user}} ->
        %{kind: :user}

      {:declared, _owner, %{kind: :ref, entity: entity}} ->
        %{kind: :ref, entity: entity}

      {:unkinded, leaf} ->
        raise ArgumentError,
              "#{inspect(leaf)}: id без вида в сведениях — `use Core.Labels.ID` после `use Core.Prim.UUID`"

      {:custom, leaf} ->
        raise ArgumentError,
              "#{inspect(leaf)}: свой вид Prim в сведениях не выходит — `use Core.Labels.ID` или `use Core.Labels.Text`"
    end
  end

  for type <- FieldCheck.type_values(), kind = Keyword.fetch!(@type_kinds, type), not is_nil(kind) do
    defp type_kind(unquote(type)), do: unquote(kind)
  end

  defp leaf_value(_spec, nil), do: nil
  defp leaf_value({:type, :boolean}, true), do: "Да"
  defp leaf_value({:type, :boolean}, false), do: "Нет"
  defp leaf_value({:enum, module}, value), do: module.label(value)
  defp leaf_value({:text, fun}, value), do: fun.(value)
  defp leaf_value({:prim, module}, prim), do: prim_value(module, prim)
  defp leaf_value(nil, value), do: leaf_value(inferred(value), value)
  defp leaf_value(_spec, value), do: value

  defp inferred(%module{}), do: {:prim, module}
  defp inferred(flag) when is_boolean(flag), do: {:type, :boolean}
  defp inferred(number) when is_number(number), do: {:type, :integer}
  defp inferred(text) when is_binary(text) or is_nil(text), do: {:type, :string}

  defp prim_value(module, prim) do
    case Kind.of(module) do
      {:plain, _kind} -> prim
      {:declared, owner, {:text, fun}} -> fun.(Kind.owned(prim, owner))
      {:declared, owner, _id} -> Kind.owned(prim, owner)
    end
  end

  defp sorted(nodes), do: Enum.sort_by(nodes, &order(&1.spec, &1.value), &before?/2)

  defp sorted_pairs(pairs), do: Enum.sort_by(pairs, &order(&1.key.spec, &1.key.value), &before?/2)

  defp order({:prim, _module}, prim), do: Core.Prim.unwrap(prim)
  defp order(_spec, value), do: value

  defp before?(%module{} = left, %module{} = right) when module in @comparable, do: module.compare(left, right) != :gt
  defp before?(left, right), do: left <= right
end
