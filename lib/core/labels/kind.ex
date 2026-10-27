defmodule Core.Labels.Kind do
  @moduledoc """
  Вид Prim-значения в сведениях (ADR-0063): одно правило для сведений (`Core.Labels.Details`), словаря
  ссылок (`Core.Labels.Refs`) и ратчета полноты (`Core.Labels.CompletenessCase`).

  Объявление вида ищется по цепочке композита (`Core.Prim.chain/1`) от самого Prim к leaf: первое звено
  с `use Core.Labels.Text` или `use Core.Labels.ID` — владелец объявления, оно действует на весь Prim.

  | Исход | Когда |
  |---|---|
  | `{:declared, owner, {:text, fun}}` | у звена `owner` — `Core.Labels.Text` |
  | `{:declared, owner, id}` | у звена `owner` — `Core.Labels.ID`, `id` — его объявление |
  | `{:plain, kind}` | объявления нет: вид leaf-Prim — `:text` / `:number` / `:date` / `:datetime` |
  | `{:unkinded, leaf}` | объявления нет, leaf — `kind: :uuid`: id без вида |
  | `{:custom, leaf}` | объявления нет, у leaf свой kind (не native): вида в сведениях у него нет |
  """

  alias Core.Labels.ID
  alias Core.Labels.Text

  @typedoc "Объявление вида значения: текст функцией (`Core.Labels.Text`) или вид id (`Core.Labels.ID`)."
  @type declaration :: {:text, (struct() -> String.t())} | ID.t()

  @typedoc "Вид значения leaf-Prim без объявления."
  @type plain :: :text | :number | :date | :datetime

  @typedoc "Вид Prim-значения в сведениях."
  @type t ::
          {:declared, module(), declaration()} | {:plain, plain()} | {:unkinded, module()} | {:custom, module()}

  # ===== вид =====

  @doc "Вид Prim-модуля в сведениях."
  @spec of(module()) :: t()

  def of(module) when is_atom(module) do
    [_ | _] = chain = Core.Prim.chain(module)

    Enum.find_value(chain, &declared/1) || plain(List.last(chain))
  end

  # ---

  defp declared(module) do
    case {Text.find(module), ID.find(module)} do
      {nil, nil} -> nil
      {fun, nil} -> {:declared, module, {:text, fun}}
      {nil, id} -> {:declared, module, id}
    end
  end

  defp plain(leaf), do: native(leaf, leaf.__domain_kind__())

  defp native(_leaf, :string), do: {:plain, :text}
  defp native(_leaf, kind) when kind in ~w(integer decimal)a, do: {:plain, :number}
  defp native(_leaf, :date), do: {:plain, :date}
  defp native(_leaf, :datetime), do: {:plain, :datetime}
  defp native(leaf, :uuid), do: {:unkinded, leaf}
  defp native(leaf, _custom), do: {:custom, leaf}

  # ===== значение владельца =====

  @doc "Значение владельца объявления (`of/1`) внутри Prim: сам Prim или база композита на любой глубине."
  @spec owned(struct(), module()) :: struct()

  def owned(%owner{} = prim, owner), do: prim
  def owned(%_composite{value: base}, owner), do: owned(base, owner)

  # ===== скалярные struct'ы =====

  # Struct'ы скалярных значений: id внутри нет (`Core.Labels.Refs` в них не спускается), а порядок
  # задаёт `compare/2` модуля, а не порядок термов (`Core.Labels.Details`).
  @doc false
  @spec scalars() :: [module()]

  def scalars, do: [Date, DateTime, NaiveDateTime, Time, Decimal]
end
