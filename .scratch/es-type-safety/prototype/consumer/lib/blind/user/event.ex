defmodule Blind.User.Event do
  alias Blind.User

  defmodule Created do
    defmodule Payload do
      @enforce_keys ~w(type status)a
      defstruct @enforce_keys ++ ~w(login)a

      def new(type, login, status) when is_atom(type) and is_atom(status),
        do: %__MODULE__{type: type, login: login, status: status}
    end

    use Core.Es.Event,
      aggregate_id: User.ID,
      by: User.ID,
      payload: Payload
  end

  defmodule LoginChanged do
    defmodule Payload do
      @enforce_keys ~w(old_value new_value)a
      defstruct @enforce_keys

      def new(old_value, new_value), do: %__MODULE__{old_value: old_value, new_value: new_value}
    end

    use Core.Es.Event,
      aggregate_id: User.ID,
      by: User.ID,
      payload: Payload
  end

  defmodule Blocked do
    use Core.Es.Event,
      aggregate_id: User.ID,
      by: User.ID,
      payload: nil
  end

  defmodule Deleted do
    use Core.Es.Event,
      aggregate_id: User.ID,
      by: User.ID,
      payload: nil
  end
end

defmodule Blind.User.Event.Codec do
  alias Blind.User
  alias Blind.User.Event

  @tag_by_mod %{
    Event.Created => "user.created",
    Event.LoginChanged => "user.login_changed",
    Event.Blocked => "user.blocked",
    Event.Deleted => "user.deleted"
  }

  use Core.Es.Event.Codec,
    event: Event,
    type: "user",
    tags: @tag_by_mod

  @impl true
  def dump_payload(%Event.Created{payload: p}, codec),
    do: %{"type" => Atom.to_string(p.type), "login" => p.login && codec.dump(p.login)}

  def dump_payload(%Event.LoginChanged{payload: p}, codec),
    do: %{"old_value" => codec.dump(p.old_value), "new_value" => codec.dump(p.new_value)}

  @impl true
  def load_payload(Event.Created, payload, codec) when is_map(payload) do
    with {:ok, login} <- codec.load(User.Login, field(payload, :login)) do
      {:ok, Event.Created.Payload.new(:admin, login, :active)}
    end
  end

  def load_payload(Event.LoginChanged, payload, codec) when is_map(payload) do
    with {:ok, old_value} <- codec.load(User.Login, field(payload, :old_value)),
         {:ok, new_value} <- codec.load(User.Login, field(payload, :new_value)) do
      {:ok, Event.LoginChanged.Payload.new(old_value, new_value)}
    end
  end
end

defmodule Blind.User.Repo do
  use Core.Es.Aggregate.Repo,
    aggregate: Blind.User,
    id: Blind.User.ID
end
