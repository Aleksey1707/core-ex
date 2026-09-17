defmodule Blind.User do
  @moduledoc "Корректный агрегат по образцу `QC.Domain.Users.Common.User.decide/2` в форме `draft/1`."

  alias Blind.User.Event

  use Core.Es.Aggregate,
    event_codec: Blind.User.Event.Codec

  defmodule ID do
    use Core.Prim.UUID,
      name: "Пользователь",
      version: 7
  end

  defmodule Login do
    use Core.Prim.String,
      name: "Логин",
      min_len: 1,
      max_len: 50
  end

  defmodule Cmd do
    defmodule Create do
      use Core.Es.Cmd

      @enforce_keys ~w(type login by at)a
      defstruct @enforce_keys
    end

    defmodule ChangeLogin do
      use Core.Es.Cmd

      @enforce_keys ~w(login by at)a
      defstruct @enforce_keys
    end

    defmodule Block do
      use Core.Es.Cmd

      @enforce_keys ~w(by at)a
      defstruct @enforce_keys
    end

    defmodule Delete do
      use Core.Es.Cmd

      @enforce_keys ~w(by at)a
      defstruct @enforce_keys
    end
  end

  defstruct [:id, :version, :type, :login, :status, deleted?: false]

  @mutations [Cmd.ChangeLogin, Cmd.Block, Cmd.Delete]
  @internal_types ~w(anonymous system)a

  @impl true
  def decide(%Cmd.Create{} = command, %__MODULE__{version: nil}) do
    with :ok <- ensure_login(command.type, command.login) do
      {:ok, [Event.Codec.draft(Event.Created.Payload.new(command.type, command.login, :active))]}
    end
  end

  def decide(%Cmd.Create{}, %__MODULE__{} = user),
    do: {:error, Blind.Account.Errors.domain(__MODULE__, :already_exists, user.login)}

  def decide(%mod{}, %__MODULE__{version: nil} = user) when mod in @mutations,
    do: {:error, Blind.Account.Errors.domain(__MODULE__, :not_found, user.id)}

  def decide(%Cmd.Delete{}, %__MODULE__{deleted?: true}), do: {:ok, []}

  def decide(%mod{}, %__MODULE__{type: type} = user) when mod in @mutations and type in @internal_types,
    do: {:error, Blind.Account.Errors.domain(__MODULE__, :invalid_status, user.id)}

  def decide(%Cmd.Delete{}, %__MODULE__{}), do: {:ok, [Event.Codec.draft(Event.Deleted)]}

  def decide(%Cmd.Block{}, %__MODULE__{status: :blocked}), do: {:ok, []}

  def decide(%Cmd.Block{}, %__MODULE__{}), do: {:ok, [Event.Codec.draft(Event.Blocked)]}

  def decide(%Cmd.ChangeLogin{login: login}, %__MODULE__{login: login}), do: {:ok, []}

  def decide(%Cmd.ChangeLogin{login: login}, %__MODULE__{} = user),
    do: {:ok, [Event.Codec.draft(Event.LoginChanged.Payload.new(user.login, login))]}

  defp ensure_login(type, %Login{}) when type in ~w(admin employee)a, do: :ok
  defp ensure_login(:anonymous, nil), do: :ok

  defp ensure_login(type, _login),
    do: {:error, Blind.Account.Errors.domain(__MODULE__, :invalid_status, type)}

  @impl true
  def evolve(user, %Event.Created{payload: payload}),
    do: %{user | type: payload.type, login: payload.login, status: payload.status}

  def evolve(user, %Event.LoginChanged{payload: payload}), do: %{user | login: payload.new_value}
  def evolve(user, %Event.Blocked{}), do: %{user | status: :blocked}
  def evolve(user, %Event.Deleted{}), do: %{user | deleted?: true}
end
