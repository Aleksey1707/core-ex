defmodule Core.EsFixture.Account do
  @moduledoc """
  Event-sourced агрегат тестов `Core.Es.Aggregate`: счёт «открыт → заморожен → закрыт».

  Случаи контракта:

  - `not_found` / `already_exists` — ошибки `decide` по `version: nil`;
  - переименование в то же имя — `{:ok, []}`;
  - сверка — `{:ok, []}` в любом состоянии, в том числе на пустом потоке;
  - закрытие открытого счёта — два события одной команды через `fold/3`;
  - `Frozen` / `Closed` — события без нагрузки;
  - `Opened` — записанные `account.opened.v1` и `account.opened.v2` грузятся апкастом;
  - `Verified` — удалённый тип: тег остаётся в `tags:`, событие больше не пишется, `evolve`
    возвращает состояние как есть.
  """

  alias Core.Es
  alias Core.EsFixture.Account.Cmd
  alias Core.EsFixture.Account.Errors
  alias Core.EsFixture.Account.Event
  alias Core.Version

  use Core.Es.Aggregate,
    event_codec: Core.EsFixture.Account.Event.Codec

  defmodule ID do
    @moduledoc "Идентификатор счёта."

    use Core.Prim.UUID,
      name: "Идентификатор счёта",
      version: 7
  end

  defmodule Name do
    @moduledoc "Название счёта."

    use Core.Prim.String,
      name: "Название счёта",
      min_len: 1,
      max_len: 50
  end

  defstruct id: nil, version: nil, name: nil, status: nil

  @type t :: %__MODULE__{
          id: ID.t() | nil,
          version: Version.t() | nil,
          name: Name.t() | nil,
          status: :open | :frozen | :closed | nil
        }

  @on_existing [Cmd.Rename, Cmd.Freeze, Cmd.Close]

  # ===== decide =====

  @doc "Решение по команде счёта."
  @spec decide(Cmd.t(), t()) :: {:ok, [Es.Aggregate.result()]} | {:error, Core.Error.t()}

  @impl true
  def decide(%Cmd.Open{name: name}, %__MODULE__{version: nil}),
    do: {:ok, [Event.Opened.draft(Event.Opened.Payload.new(name))]}

  def decide(%Cmd.Open{}, %__MODULE__{} = state) do
    {:error, Errors.domain(__MODULE__, :already_exists, %{version: Version.value(state.version)})}
  end

  def decide(%command{}, %__MODULE__{version: nil}) when command in @on_existing,
    do: {:error, Errors.domain(__MODULE__, :not_found, nil)}

  def decide(%Cmd.Check{}, %__MODULE__{}), do: {:ok, []}

  def decide(%Cmd.Rename{name: name}, %__MODULE__{name: name}), do: {:ok, []}

  def decide(%Cmd.Rename{name: name}, %__MODULE__{status: :open}),
    do: {:ok, [Event.Renamed.draft(Event.Renamed.Payload.new(name))]}

  def decide(%Cmd.Freeze{}, %__MODULE__{status: :open}), do: {:ok, [Event.Frozen.draft()]}

  def decide(%Cmd.Close{}, %__MODULE__{status: :frozen}), do: {:ok, [Event.Closed.draft()]}

  # Closed решается по состоянию после Frozen: промежуточное событие сворачивается в той же команде.
  def decide(%Cmd.Close{} = command, %__MODULE__{status: :open} = state) do
    freeze = %Cmd.Freeze{by: command.by, at: command.at}

    with {:ok, frozen} <- decide(freeze, state),
         {:ok, closed} <- decide(command, fold(state, freeze, frozen)) do
      {:ok, frozen ++ closed}
    end
  end

  def decide(%command{}, %__MODULE__{} = state) when command in @on_existing do
    detail = %{status: state.status, command: command}
    {:error, Errors.domain(__MODULE__, :invalid_status, detail)}
  end

  # ===== evolve =====

  @doc "Применение события счёта."
  @spec evolve(t(), Event.t()) :: t()

  @impl true
  def evolve(state, %Event.Opened{payload: payload}),
    do: %{state | name: payload.name, status: :open}

  def evolve(state, %Event.Renamed{payload: payload}), do: %{state | name: payload.name}

  def evolve(state, %Event.Frozen{}), do: %{state | status: :frozen}

  def evolve(state, %Event.Closed{}), do: %{state | status: :closed}

  # Тип удалён: событие больше не пишется, записанное читается и состояние не меняет.
  def evolve(state, %Event.Verified{}), do: state
end
