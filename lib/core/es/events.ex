defmodule Core.Es.Events do
  @moduledoc """
  Коллекция uncommitted-событий агрегата (newest-first).
  """

  alias Core.Error
  alias Core.Es
  alias Core.Result
  alias Core.Version

  require Error

  @type t(event) :: [event]
  @type t :: t(Es.Event.t())

  @doc "Создать пустую коллекцию."
  @spec new() :: t()

  def new, do: []

  @doc """
  Создать коллекцию из enumerable.

  Сортирует по `aggregate_version` убыванию (newest-first).
  """
  @spec new(Enumerable.t()) :: t()

  def new(enumerable) do
    enumerable
    |> Enum.sort_by(&Version.value(&1.aggregate_version), :desc)
  end

  @doc "Добавить событие в начало коллекции (newest-first)."
  @spec add(t(e), e) :: t(e) when e: Es.Event.t()

  def add(events, %{id: %Es.Event.ID{}} = event) when is_list(events), do: [event | events]

  @doc "Список в chronological order (oldest-first) — для flush."
  @spec to_list(t(e)) :: [e] when e: Es.Event.t()

  def to_list(events) when is_list(events), do: Enum.reverse(events)

  @doc "Очистить коллекцию."
  @spec clear(t()) :: t()

  def clear(events) when is_list(events), do: new()

  @doc "Пустая ли коллекция."
  @spec empty?(t()) :: boolean()

  def empty?(events) when is_list(events), do: events == []

  @doc "Число событий."
  @spec count(t()) :: non_neg_integer()

  def count(events) when is_list(events), do: length(events)

  @doc "Есть ли событие с данным id."
  @spec member?(t(), Es.Event.ID.t()) :: boolean()

  def member?(events, %Es.Event.ID{} = id) when is_list(events) do
    Enum.any?(events, &(&1.id == id))
  end

  @doc "Есть ли событие, удовлетворяющее предикату."
  @spec any?(t(e), (e -> as_boolean(term()))) :: boolean() when e: Es.Event.t()

  def any?(events, fun) when is_list(events) and is_function(fun, 1) do
    Enum.any?(events, fun)
  end

  @doc "Отфильтровать события предикатом (порядок хранения)."
  @spec filter(t(e), (e -> as_boolean(term()))) :: t(e) when e: Es.Event.t()

  def filter(events, fun) when is_list(events) and is_function(fun, 1) do
    Enum.filter(events, fun)
  end

  @doc "Все события указанного модуля (порядок хранения)."
  @spec filter_by_type(t(e), module()) :: t(e) when e: Es.Event.t()

  def filter_by_type(events, type) when is_list(events) and is_atom(type) do
    Enum.filter(events, &(&1.__struct__ == type))
  end

  @doc "Найти событие по id."
  @spec find(t(e), Es.Event.ID.t()) :: e | nil when e: Es.Event.t()

  def find(events, %Es.Event.ID{} = id) when is_list(events) do
    Enum.find(events, &(&1.id == id))
  end

  @doc "Получить событие по id."
  @spec get(t(e), Es.Event.ID.t()) :: {:ok, e} | {:error, Error.t()} when e: Es.Event.t()

  def get(events, %Es.Event.ID{} = id) when is_list(events) do
    case find(events, id) do
      nil -> {:error, not_found(id)}
      event -> {:ok, event}
    end
  end

  @doc "Получить событие по id (bang)."
  @spec get!(t(e), Es.Event.ID.t()) :: e when e: Es.Event.t()

  def get!(events, %Es.Event.ID{} = id) when is_list(events) do
    Result.unwrap!(get(events, id))
  end

  @doc "Найти первое (newest) событие указанного модуля."
  @spec find_by_type(t(e), module()) :: e | nil when e: Es.Event.t()

  def find_by_type(events, type) when is_list(events) and is_atom(type) do
    Enum.find(events, &(&1.__struct__ == type))
  end

  @doc "Получить первое (newest) событие указанного модуля."
  @spec get_by_type(t(e), module()) :: {:ok, e} | {:error, Error.t()} when e: Es.Event.t()

  def get_by_type(events, type) when is_list(events) and is_atom(type) do
    case find_by_type(events, type) do
      nil -> {:error, not_found(type)}
      event -> {:ok, event}
    end
  end

  @doc "Получить первое (newest) событие указанного модуля (bang)."
  @spec get_by_type!(t(e), module()) :: e when e: Es.Event.t()

  def get_by_type!(events, type) when is_list(events) and is_atom(type) do
    Result.unwrap!(get_by_type(events, type))
  end

  @doc "Самое новое событие (head)."
  @spec last(t(e)) :: e | nil when e: Es.Event.t()

  def last([]), do: nil
  def last([event | _]) when is_map(event), do: event

  @doc "Самое новое событие."
  @spec get_last(t(e)) :: {:ok, e} | {:error, Error.t()} when e: Es.Event.t()

  def get_last(events) when is_list(events) do
    case last(events) do
      nil -> {:error, not_found(:last)}
      event -> {:ok, event}
    end
  end

  @doc "Самое новое событие (bang)."
  @spec get_last!(t(e)) :: e when e: Es.Event.t()

  def get_last!(events) when is_list(events) do
    Result.unwrap!(get_last(events))
  end

  @doc "Самое старое событие."
  @spec first(t(e)) :: e | nil when e: Es.Event.t()

  def first([]), do: nil
  def first(events) when is_list(events), do: List.last(events)

  @doc "Самое старое событие."
  @spec get_first(t(e)) :: {:ok, e} | {:error, Error.t()} when e: Es.Event.t()

  def get_first(events) when is_list(events) do
    case first(events) do
      nil -> {:error, not_found(:first)}
      event -> {:ok, event}
    end
  end

  @doc "Самое старое событие (bang)."
  @spec get_first!(t(e)) :: e when e: Es.Event.t()

  def get_first!(events) when is_list(events) do
    Result.unwrap!(get_first(events))
  end

  @doc """
  Срез в chronological индексации (0 = oldest).

  Возвращает коллекцию в порядке хранения (newest-first).
  """
  @spec slice(t(e), non_neg_integer(), non_neg_integer()) :: t(e) when e: Es.Event.t()

  def slice(events, offset, limit)
      when is_list(events) and is_integer(offset) and offset >= 0 and is_integer(limit) and
             limit >= 0 do
    events
    |> to_list()
    |> Enum.slice(offset, limit)
    |> Enum.reverse()
  end

  # ---

  defp not_found(detail) do
    Error.domain(__MODULE__,
      code: :not_found,
      ns: :events,
      message: "Событие не найдено",
      detail: detail
    )
  end
end
