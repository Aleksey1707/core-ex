defmodule Consumer.Grants do
  @moduledoc "Агрегат, у кодека которого два события делят модуль нагрузки."

  alias Consumer.Grants.Event
  alias Consumer.UserID
  alias Core.Es

  use Core.Es.Aggregate,
    event_codec: Consumer.Grants.Event.Codec

  defmodule ID do
    use Core.Prim.UUID,
      name: "Выдача ролей",
      version: 7
  end

  defmodule RoleID do
    use Core.Prim.UUID,
      name: "Роль",
      version: 7
  end

  defmodule Cmd do
    defmodule Grant do
      use Core.Es.Cmd

      @enforce_keys ~w(role by at)a
      defstruct @enforce_keys

      @type t :: %__MODULE__{role: RoleID.t(), by: UserID.t(), at: Es.Event.At.t()}
    end

    defmodule Revoke do
      use Core.Es.Cmd

      @enforce_keys ~w(role by at)a
      defstruct @enforce_keys
    end
  end

  defstruct id: nil, version: nil, roles: MapSet.new()

  @impl true
  def decide(%Cmd.Grant{role: %RoleID{} = role}, %__MODULE__{} = state) do
    if MapSet.member?(state.roles, role),
      do: {:ok, []},
      else: {:ok, [Event.Granted.draft(role)]}
  end

  def decide(%Cmd.Revoke{role: %RoleID{} = role}, %__MODULE__{} = state) do
    if MapSet.member?(state.roles, role),
      do: {:ok, [Event.Revoked.draft(role)]},
      else: {:ok, []}
  end

  @impl true
  def evolve(%__MODULE__{} = state, %Event.Granted{payload: %RoleID{} = role}),
    do: %{state | roles: MapSet.put(state.roles, role)}

  def evolve(%__MODULE__{} = state, %Event.Revoked{payload: %RoleID{} = role}),
    do: %{state | roles: MapSet.delete(state.roles, role)}
end
