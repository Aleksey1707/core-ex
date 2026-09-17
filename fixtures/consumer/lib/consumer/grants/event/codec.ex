defmodule Consumer.Grants.Event.Codec do
  alias Consumer.Grants
  alias Consumer.Grants.Event

  @tag_by_mod %{Event.Granted => "grants.granted", Event.Revoked => "grants.revoked"}

  use Core.Es.Event.Codec,
    event: Event,
    type: "grants",
    tags: @tag_by_mod

  @impl true
  def dump_payload(%Event.Granted{payload: %Grants.RoleID{} = role}, codec), do: codec.dump(role)
  def dump_payload(%Event.Revoked{payload: %Grants.RoleID{} = role}, codec), do: codec.dump(role)

  @impl true
  def load_payload(mod, wire, codec) when mod in [Event.Granted, Event.Revoked],
    do: codec.load(Grants.RoleID, wire)
end
