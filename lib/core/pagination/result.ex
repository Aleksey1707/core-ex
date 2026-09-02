defmodule Core.Pagination.Result do
  @moduledoc """
  Результат постраничной выборки: элементы и общее количество.
  """

  @enforce_keys ~w(items count)a
  defstruct @enforce_keys

  @type t(item) :: %__MODULE__{items: [item], count: non_neg_integer()}
  @type t :: t(term())

  @doc "Собрать результат страницы."
  @spec new([item], non_neg_integer()) :: t(item) when item: var

  def new(items, count) when is_list(items) and is_integer(count) and count >= 0 do
    %__MODULE__{items: items, count: count}
  end

  @doc "Пустая страница (`count: 0`)."
  @spec empty() :: t(term())

  def empty, do: %__MODULE__{items: [], count: 0}

  @doc """
  Применить функцию к элементам страницы, сохранив `count`.

  `count` — размер всей выборки, а не страницы, поэтому маппинг его не меняет.
  """
  @spec map(t(a), (a -> b)) :: t(b) when a: var, b: var

  def map(%__MODULE__{items: items} = result, fun) when is_function(fun, 1) do
    %{result | items: Enum.map(items, fun)}
  end
end
