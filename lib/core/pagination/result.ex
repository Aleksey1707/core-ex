defmodule Core.Pagination.Result do
  @moduledoc """
  Результат постраничной выборки: элементы и общее количество.
  """

  @enforce_keys ~w(items total)a
  defstruct @enforce_keys

  @type t(item) :: %__MODULE__{items: [item], total: non_neg_integer()}
  @type t :: t(term())

  @doc "Собрать результат страницы."
  @spec new([item], non_neg_integer()) :: t(item) when item: var

  def new(items, total) when is_list(items) and is_integer(total) and total >= 0 do
    %__MODULE__{items: items, total: total}
  end

  @doc "Пустая страница (`total: 0`)."
  @spec empty() :: t(term())

  def empty, do: %__MODULE__{items: [], total: 0}

  @doc """
  Применить функцию к элементам страницы, сохранив `total`.

  `total` — размер всей выборки, а не страницы, поэтому маппинг его не меняет.
  """
  @spec map(t(a), (a -> b)) :: t(b) when a: var, b: var

  def map(%__MODULE__{items: items} = result, fun) when is_function(fun, 1) do
    %{result | items: Enum.map(items, fun)}
  end
end
