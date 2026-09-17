defmodule Consumer.Parcel.Event do
  alias Consumer.Parcel
  alias Consumer.UserID

  defmodule Sent do
    defmodule Payload do
      @enforce_keys ~w(note)a
      defstruct @enforce_keys

      def new(note), do: %__MODULE__{note: note}
    end

    use Core.Es.Event,
      aggregate_id: Parcel.ID,
      by: UserID,
      payload: Payload
  end

  defmodule Lost do
    defmodule Payload do
      @enforce_keys ~w(note)a
      defstruct @enforce_keys
    end

    use Core.Es.Event,
      aggregate_id: Parcel.ID,
      by: UserID,
      payload: Payload
  end

  defmodule Returned do
    use Core.Es.Event,
      aggregate_id: Parcel.ID,
      by: UserID,
      payload: nil
  end

  @type t :: Sent.t() | Lost.t() | Returned.t()
end
