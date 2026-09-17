defmodule Blind.Account.Event do
  alias Blind.Account
  alias Blind.UserID

  defmodule Opened do
    defmodule Payload do
      @enforce_keys ~w(name)a
      defstruct @enforce_keys

      @type t :: %__MODULE__{name: Account.Name.t()}

      def new(%Account.Name{} = name), do: %__MODULE__{name: name}
    end

    use Core.Es.Event,
      aggregate_id: Account.ID,
      by: UserID,
      payload: Payload
  end

  defmodule Renamed do
    defmodule Payload do
      @enforce_keys ~w(name)a
      defstruct @enforce_keys

      @type t :: %__MODULE__{name: Account.Name.t()}

      def new(%Account.Name{} = name), do: %__MODULE__{name: name}
    end

    use Core.Es.Event,
      aggregate_id: Account.ID,
      by: UserID,
      payload: Payload
  end

  defmodule Closed do
    use Core.Es.Event,
      aggregate_id: Account.ID,
      by: UserID,
      payload: nil
  end

  @type t :: Opened.t() | Renamed.t() | Closed.t()
end
