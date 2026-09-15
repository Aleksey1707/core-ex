defmodule Core.EsFixture.BrokenAccount do
  @moduledoc """
  Сломанный event-sourced агрегат проверки полноты `evolve` (`Core.Es.EventCompatCase`): события
  счёта `Core.EsFixture.Account`, у `evolve/2` нет клаузы `Closed`.

  Прочие исключения пропуском клаузы не считаются: `Renamed` падает в теле на пустом состоянии
  (`KeyError`), `Frozen` — `FunctionClauseError` приватной функции, а не самой `evolve/2`.
  """

  alias Core.EsFixture.Account.Event

  use Core.Es.Aggregate,
    event_codec: Core.EsFixture.Account.Event.Codec

  defstruct id: nil, version: nil, name: nil, status: nil

  @doc "Решение по команде: событий нет."
  @spec decide(struct(), %__MODULE__{}) :: {:ok, []}

  @impl true
  def decide(_command, %__MODULE__{}), do: {:ok, []}

  @doc "Применение события — без клаузы `Closed`."
  @spec evolve(%__MODULE__{}, Event.t()) :: %__MODULE__{}

  @impl true
  def evolve(state, %Event.Opened{payload: payload}),
    do: %{state | name: payload.name, status: :open}

  def evolve(state, %Event.Renamed{payload: payload}),
    do: %{state | name: payload.name, status: Map.fetch!(%{open: :open}, state.status)}

  def evolve(state, %Event.Frozen{}), do: %{state | status: freeze(state.status)}

  def evolve(state, %Event.Verified{}), do: state

  # ---

  defp freeze(:open), do: :frozen
end
