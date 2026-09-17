defmodule Blind.Account do
  alias Blind.Account.Errors
  alias Blind.Account.Event
  alias Blind.UserID
  alias Core.Es
  alias Core.Version

  use Core.Es.Aggregate,
    event_codec: Blind.Account.Event.Codec

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

      @type t :: %__MODULE__{name: Name.t(), by: UserID.t(), at: Es.Event.At.t()}
    end

    defmodule Close do
      use Core.Es.Cmd

      @enforce_keys ~w(by at)a
      defstruct @enforce_keys

      @type t :: %__MODULE__{by: UserID.t(), at: Es.Event.At.t()}
    end

    # Команда без clause в decide/2.
    defmodule Orphan do
      use Core.Es.Cmd

      @enforce_keys ~w(by at)a
      defstruct @enforce_keys
    end
  end

  defstruct id: nil, version: nil, name: nil, status: nil

  @type t :: %__MODULE__{}

  @on_existing [Cmd.Rename, Cmd.Close]

  @impl true
  def decide(%Cmd.Open{name: name}, %__MODULE__{version: nil}),
    do: {:ok, [{Event.Opened, Event.Opened.Payload.new(name)}]}

  def decide(%Cmd.Open{}, %__MODULE__{} = state),
    do: {:error, Errors.domain(__MODULE__, :already_exists, %{version: Version.value(state.version)})}

  def decide(%command{}, %__MODULE__{version: nil}) when command in @on_existing,
    do: {:error, Errors.domain(__MODULE__, :not_found, nil)}

  def decide(%Cmd.Rename{name: name}, %__MODULE__{name: name}), do: {:ok, []}

  def decide(%Cmd.Rename{name: name}, %__MODULE__{status: :open}),
    do: {:ok, [{Event.Renamed, Event.Renamed.Payload.new(name)}]}

  def decide(%Cmd.Close{}, %__MODULE__{status: :open}), do: {:ok, [Event.Closed]}

  @impl true
  def evolve(state, %Event.Opened{payload: payload}),
    do: %{state | name: payload.name, status: :open}

  def evolve(state, %Event.Renamed{payload: payload}), do: %{state | name: payload.name}

  def evolve(state, %Event.Closed{}), do: %{state | status: :closed}
end
