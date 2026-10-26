defmodule Consumer.Domain.Sales.Grants do
  @moduledoc """
  Агрегат, у кодека которого два события делят нагрузку-Prim, третье несёт `Es.ValueChanged`,
  четвёртое — нагрузку по полям с вариантами семейств (`union:`), пятое — нагрузку по полям с
  множеством и словарём (`set:`, `map:`): клаузы нагрузки кодек выводит сам. Состояние и команда
  `Cmd.Assign` — структуры по полям с `set:` и `map:`.
  """

  alias Consumer.Domain.Sales.Grants.Cmd
  alias Consumer.Domain.Sales.Grants.Event
  alias Core.Version

  use Core.Es.Aggregate,
    event_codec: Consumer.Domain.Sales.Grants.Event.Codec

  defmodule ID do
    use Core.Prim.UUID,
      name: "Выдача ролей",
      version: 7
  end

  defmodule RoleID do
    use Core.Prim.UUID,
      name: "Роль",
      version: 7

    use Core.Labels.ID, kind: :id
  end

  use Core.Struct,
    fields: [
      id: [prim: ID],
      version: [prim: Version, optional: true],
      roles: [set: [prim: RoleID], default: MapSet.new()],
      quotas: [map: [key: [prim: RoleID], value: [type: :non_neg_integer]], default: %{}]
    ]

  @impl true
  def decide(%Cmd.Assign{roles: roles, quotas: quotas}, %__MODULE__{roles: roles, quotas: quotas}), do: {:ok, []}

  def decide(%Cmd.Assign{roles: %MapSet{} = roles, quotas: quotas}, %__MODULE__{}),
    do: {:ok, [Event.Assigned.draft(Event.Assigned.Payload.new(roles, quotas))]}

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

  def evolve(%__MODULE__{} = state, %Event.Replaced{payload: %Event.Replaced.Payload{} = payload}),
    do: %{state | roles: state.roles |> MapSet.delete(payload.old_value) |> MapSet.put(payload.new_value)}

  def evolve(%__MODULE__{} = state, %Event.Badged{payload: %Event.Badged.Payload{}}), do: state

  def evolve(%__MODULE__{} = state, %Event.Assigned{payload: %Event.Assigned.Payload{} = payload}),
    do: %{state | roles: payload.roles, quotas: payload.quotas}
end
