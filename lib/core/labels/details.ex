defmodule Core.Labels.Details do
  @moduledoc """
  Название и сведения события: чистая функция «событие → `{название, сведения}`» (ADR-0063).

  Обходит нагрузку по объявлениям — название события и подпись нагрузки-Prim
  (`Core.Labels.Event`), подписи полей нагрузки (`Core.Labels.Fields`), подписи значений Enum
  (`Core.Labels.Values`), вид id (`Core.Labels.ID`), текст Prim (`Core.Labels.Text`) — и отдаёт
  список сведений из Prim-значений. Дампа и имён нет: значения — Prim как есть, в JSON их переводит
  wire, а имя по id ставит словарь ссылок.

  Сведения — проекция описания значения (`Core.Labels.Description`): объявленная видимая форма
  обходится один раз, её узел несёт подпись, вид, значение и ссылки; сведения берут узел без
  ссылок, словарь ссылок (`Core.Labels.Refs`) — ссылки тех же узлов. Вид и правило вида Prim
  считаются один раз на лист.

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
  alias Core.Labels.Description
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

  @doc "Название и сведения события."
  @spec build(Es.Event.t()) :: {String.t(), [t()]}

  def build(%event{payload: payload}) when is_atom(event), do: {event.__label_title__(), details(event, payload)}

  # ---

  defp details(_event, nil), do: []

  defp details(event, payload) do
    case event.__label_payload__() do
      nil -> struct_details(payload)
      label -> [Description.entry(label, {:prim, event.__es_payload__()}, payload) |> Description.detail()]
    end
  end

  defp struct_details(%module{} = struct) do
    module
    |> Walk.values(struct)
    |> Description.describe(:details)
    |> Enum.map(&Description.detail/1)
  end
end
