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
  | `:group` | `entity:`, `union:` → сведения полей struct'а; у варианта — по его `Core.Labels.Fields` |
  | `:list` | `list:` → элементы `%{kind, value}` вида спеки элемента, без подписи |
  | `:list` | `type: :map` с подписями `[label:, key:, value:]` → группы «ключ — значение» |

  Prim-композит (`Core.Prim.Compose`) выходит видом своего базового Prim, значение — композит как есть.
  Объявление вида id или текста у базы композита действует и на композит: значение — база с
  объявлением, текст — функция от неё.

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
  """

  alias Core.Es
  alias Core.Helper.FieldCheck
  alias Core.Labels.Fields
  alias Core.Labels.ID
  alias Core.Labels.Text

  @typedoc "Вид значения сведения."
  @type kind :: :text | :number | :date | :datetime | :user | :ref | :group | :list

  @typedoc "Значение сведения: Prim, строка, число, сведения группы или элементы списка."
  @type value :: struct() | String.t() | number() | [t()] | [item()] | nil

  @typedoc "Сведение: подписанное значение со своим видом, ссылка на запись или изменение «было → стало»."
  @type t ::
          %{label: String.t(), kind: kind(), value: value()}
          | %{label: String.t(), kind: :ref, entity: atom(), value: struct() | nil}
          | %{label: String.t(), kind: :change, old: item(), new: item()}

  @typedoc "Элемент списка: значение со своим видом, без подписи."
  @type item :: %{kind: kind(), value: value()} | %{kind: :ref, entity: atom(), value: struct() | nil}

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
      label -> [detail(label, {:prim, event.__es_payload__()}, payload)]
    end
  end

  defp struct_details(%module{} = struct) do
    case Fields.change(module) do
      nil -> fields_details(module, struct)
      {label, spec} -> [change_detail(label, spec, struct)]
    end
  end

  defp fields_details(module, struct) do
    labels = module.__label_fields__()

    for {name, spec} <- Fields.specs(module),
        do: field_detail(Keyword.fetch!(labels, name), spec, Map.fetch!(struct, name))
  end

  defp field_detail([label: label, key: key, value: value], {:type, :map}, map),
    do: %{label: label, kind: :list, value: map_items(map, key, value)}

  defp field_detail(label, spec, value), do: detail(label, spec, value)

  defp map_items(nil, _key, _value), do: nil

  defp map_items(map, key_label, value_label) when is_map(map) do
    for {key, value} <- map,
        do: %{kind: :group, value: [inferred(key_label, key), inferred(value_label, value)]}
  end

  # У map'ы спеки ключей и значений нет: вид — по самому значению.
  defp inferred(label, %module{} = prim), do: detail(label, {:prim, module}, prim)
  defp inferred(label, flag) when is_boolean(flag), do: detail(label, {:type, :boolean}, flag)
  defp inferred(label, number) when is_number(number), do: %{label: label, kind: :number, value: number}
  defp inferred(label, text) when is_binary(text) or is_nil(text), do: %{label: label, kind: :text, value: text}

  defp change_detail(label, spec, %{old_value: old, new_value: new}),
    do: %{label: label, kind: :change, old: item(spec, old), new: item(spec, new)}

  defp detail(label, spec, value), do: Map.put(item(spec, value), :label, label)

  defp item(spec, value), do: Map.put(shape(spec), :value, value(spec, value))

  defp shape({:prim, module}), do: prim_shape(module)
  defp shape({:enum, _module}), do: %{kind: :text}
  defp shape({:text, _fun}), do: %{kind: :text}
  defp shape({kind, _module}) when kind in ~w(entity union)a, do: %{kind: :group}
  defp shape({:list, _inner}), do: %{kind: :list}
  defp shape({:type, type}), do: %{kind: type_kind(type)}

  defp prim_shape(module) do
    case declaration(module) do
      nil -> %{kind: plain_kind(module)}
      {_owner, {:text, _fun}} -> %{kind: :text}
      {_owner, %{kind: :id}} -> %{kind: :text}
      {_owner, %{kind: :user}} -> %{kind: :user}
      {_owner, %{kind: :ref, entity: entity}} -> %{kind: :ref, entity: entity}
    end
  end

  defp plain_kind(module) do
    if Core.Prim.composed?(module),
      do: plain_kind(module.__domain_base__()),
      else: native_kind(module, module.__domain_kind__())
  end

  defp native_kind(_module, :string), do: :text
  defp native_kind(_module, kind) when kind in ~w(integer decimal)a, do: :number
  defp native_kind(_module, :date), do: :date
  defp native_kind(_module, :datetime), do: :datetime

  defp native_kind(module, :uuid) do
    raise ArgumentError,
          "#{inspect(module)}: id без вида в сведениях — `use Core.Labels.ID` после `use Core.Prim.UUID`"
  end

  for type <- FieldCheck.type_values(), kind = Keyword.fetch!(@type_kinds, type), not is_nil(kind) do
    defp type_kind(unquote(type)), do: unquote(kind)
  end

  defp value(_spec, nil), do: nil
  defp value({:type, :boolean}, true), do: "Да"
  defp value({:type, :boolean}, false), do: "Нет"
  defp value({:enum, module}, value), do: module.label(value)
  defp value({:text, fun}, value), do: fun.(value)
  defp value({:prim, module}, prim), do: prim_value(module, prim)
  defp value({kind, _module}, struct) when kind in ~w(entity union)a, do: struct_details(struct)
  defp value({:list, inner}, items), do: Enum.map(items, &item(inner, &1))
  defp value(_spec, value), do: value

  defp prim_value(module, prim) do
    case declaration(module) do
      nil -> prim
      {owner, {:text, fun}} -> fun.(declared(prim, owner))
      {owner, _id} -> declared(prim, owner)
    end
  end

  # Объявление Prim в сведениях — своё или базы композита — и Prim, который его несёт.
  defp declaration(module) do
    case {Text.find(module), ID.find(module)} do
      {nil, nil} -> if Core.Prim.composed?(module), do: declaration(module.__domain_base__())
      {fun, nil} -> {module, {:text, fun}}
      {nil, id} -> {module, id}
    end
  end

  defp declared(%owner{} = prim, owner), do: prim
  defp declared(%_composite{value: base}, owner), do: declared(base, owner)
end
