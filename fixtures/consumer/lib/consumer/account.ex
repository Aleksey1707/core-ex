defmodule Consumer.Account do
  @moduledoc """
  Корректный агрегат: команды в стиле `%command{} when command in @on_existing`, два события одной
  командой через `fold/3`, события с нагрузкой и без, `evolve/2` с паттерном `%Payload{}` и без.
  """

  alias Consumer.Account.Errors
  alias Consumer.Account.Event
  alias Consumer.UserID
  alias Core.Es
  alias Core.Version

  use Core.Es.Aggregate,
    event_codec: Consumer.Account.Event.Codec

  defmodule ID do
    use Core.Prim.UUID,
      name: "Счёт",
      version: 7
  end

  defmodule Name do
    use Core.Prim.String,
      name: "Название счёта",
      min_len: 1,
      max_len: 50
  end

  defmodule Cmd do
    defmodule Open do
      use Core.Es.Cmd

      @enforce_keys ~w(name by at)a
      defstruct @enforce_keys

      @type t :: %__MODULE__{name: Name.t(), by: UserID.t(), at: Es.Event.At.t()}
    end

    defmodule Rename do
      use Core.Es.Cmd

      @enforce_keys ~w(name by at)a
      defstruct @enforce_keys
    end

    defmodule Freeze do
      use Core.Es.Cmd

      @enforce_keys ~w(by at)a
      defstruct @enforce_keys
    end

    defmodule Close do
      use Core.Es.Cmd

      @enforce_keys ~w(by at)a
      defstruct @enforce_keys
    end
  end

  defstruct id: nil, version: nil, name: nil, status: nil

  @type t :: %__MODULE__{}

  @on_existing [Cmd.Rename, Cmd.Freeze, Cmd.Close]

  @impl true
  def decide(%Cmd.Open{name: name}, %__MODULE__{version: nil}),
    do: {:ok, [Event.Opened.draft(Event.Opened.Payload.new(name))]}

  def decide(%Cmd.Open{}, %__MODULE__{} = state),
    do: {:error, Errors.domain(__MODULE__, :already_exists, %{version: Version.value(state.version)})}

  def decide(%command{}, %__MODULE__{version: nil}) when command in @on_existing,
    do: {:error, Errors.domain(__MODULE__, :not_found, nil)}

  def decide(%Cmd.Rename{name: name}, %__MODULE__{name: name}), do: {:ok, []}

  def decide(%Cmd.Rename{name: name}, %__MODULE__{status: :open}),
    do: {:ok, [Event.Renamed.draft(Event.Renamed.Payload.new(name))]}

  def decide(%Cmd.Freeze{}, %__MODULE__{status: :open}), do: {:ok, [Event.Frozen.draft()]}

  def decide(%Cmd.Close{}, %__MODULE__{status: :frozen}), do: {:ok, [Event.Closed.draft()]}

  def decide(%Cmd.Close{} = command, %__MODULE__{status: :open} = state) do
    freeze = %Cmd.Freeze{at: command.at, by: command.by}

    with {:ok, frozen} <- decide(freeze, state),
         {:ok, closed} <- decide(command, fold(state, freeze, frozen)) do
      {:ok, frozen ++ closed}
    end
  end

  def decide(%command{}, %__MODULE__{} = state) when command in @on_existing,
    do: {:error, Errors.domain(__MODULE__, :invalid_status, %{status: state.status})}

  @impl true
  def evolve(state, %Event.Opened{payload: %Event.Opened.Payload{} = payload}),
    do: %{state | name: payload.name, status: :open}

  def evolve(state, %Event.Renamed{payload: payload}), do: %{state | name: payload.name}

  def evolve(state, %Event.Frozen{}), do: %{state | status: :frozen}

  def evolve(state, %Event.Closed{}), do: %{state | status: :closed}
end
