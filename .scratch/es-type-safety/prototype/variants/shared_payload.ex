# Вариант P1: два события одного кодека делят модуль нагрузки (как `UserRoles.Event.RoleGranted` /
# `RoleRevoked` с `payload: Role.ID` в qc). Ожидается CompileError генерации `draft/1`.
defmodule Blind.Roles.ID do
  use Core.Prim.UUID,
    name: "Роли",
    version: 7
end

defmodule Blind.Roles.RoleID do
  use Core.Prim.UUID,
    name: "Роль",
    version: 7
end

defmodule Blind.Roles.Event do
  alias Blind.Roles
  alias Blind.UserID

  defmodule Granted do
    use Core.Es.Event,
      aggregate_id: Roles.ID,
      by: UserID,
      payload: Roles.RoleID
  end

  defmodule Revoked do
    use Core.Es.Event,
      aggregate_id: Roles.ID,
      by: UserID,
      payload: Roles.RoleID
  end
end

defmodule Blind.Roles.Event.Codec do
  alias Blind.Roles.Event

  @tag_by_mod %{Event.Granted => "roles.granted", Event.Revoked => "roles.revoked"}

  use Core.Es.Event.Codec,
    event: Event,
    type: "roles",
    tags: @tag_by_mod

  @impl true
  def dump_payload(%{payload: role_id}, codec), do: codec.dump(role_id)

  @impl true
  def load_payload(_mod, wire, codec), do: codec.load(Blind.Roles.RoleID, wire)
end
