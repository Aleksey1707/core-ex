defmodule Core.Labels.Details do
  @moduledoc """
  Название и сведения события: чистая функция «событие → `{название, сведения}`» (ADR-0063).

  Обходит нагрузку по объявлениям — название события и подпись нагрузки-Prim
  (`Core.Labels.Event`), подписи полей нагрузки (`Core.Labels.Fields`) — и отдаёт список
  сведений из Prim-значений. Дампа нет: значения — Prim как есть, в JSON их переводит wire.

  Сведение — `%{label, kind, value}`. Вид — по спеке поля нагрузки:

  | `kind` | Спека поля | `value` |
  |---|---|---|
  | `:text` | Prim `kind: :string`; `type: :string`, `type: :boolean` | Prim; строка; «Да» / «Нет» |
  | `:number` | Prim `kind: :integer`, `kind: :decimal`; `type:` целого | Prim; целое |
  | `:date` | Prim `kind: :date` | Prim |
  | `:datetime` | Prim `kind: :datetime` | Prim |

  Вид `type:` задан на каждое значение списка типов проверки полей
  (`Core.Helper.FieldCheck.type_values/0`): новый тип без вида не собирает библиотеку.

  Сведения идут в порядке спеки нагрузки; поле `:hidden` в них не попадает. Поле без значения —
  сведение с `value: nil` и своим видом; нагрузка `nil` — пустые сведения; нагрузка-Prim — одно
  сведение с подписью `payload:` события.
  """

  alias Core.Es
  alias Core.Helper.FieldCheck
  alias Core.Labels.Fields

  @typedoc "Вид значения сведения."
  @type kind :: :text | :number | :date | :datetime

  @typedoc "Сведение: подписанное значение со своим видом."
  @type t :: %{label: String.t(), kind: kind(), value: struct() | String.t() | integer() | nil}

  # Свободная map подписью не выходит (`Core.Labels.Fields`): вида у неё нет, но ответ на неё дан.
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
    labels = module.__label_fields__()

    for {name, spec} <- Fields.specs(module),
        do: detail(Keyword.fetch!(labels, name), spec, Map.fetch!(struct, name))
  end

  defp detail(label, spec, value), do: %{label: label, kind: kind(spec), value: value(spec, value)}

  defp kind({:prim, module}), do: prim_kind(module.__domain_kind__())
  defp kind({:type, type}), do: type_kind(type)

  defp prim_kind(:string), do: :text
  defp prim_kind(kind) when kind in ~w(integer decimal)a, do: :number
  defp prim_kind(:date), do: :date
  defp prim_kind(:datetime), do: :datetime

  for type <- FieldCheck.type_values(), kind = Keyword.fetch!(@type_kinds, type), not is_nil(kind) do
    defp type_kind(unquote(type)), do: unquote(kind)
  end

  defp value(_spec, nil), do: nil
  defp value({:type, :boolean}, true), do: "Да"
  defp value({:type, :boolean}, false), do: "Нет"
  defp value(_spec, value), do: value
end
