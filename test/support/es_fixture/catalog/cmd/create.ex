defmodule Core.EsFixture.Catalog.Cmd.Create do
  @moduledoc "Завести каталог по пути: части разделены `/`."

  alias Core.Es
  alias Core.EventFixture.ActorID
  alias Core.EventFixture.Name

  use Core.Es.Cmd

  @enforce_keys ~w(path by at)a
  defstruct @enforce_keys

  @type t :: %__MODULE__{path: Name.t(), by: ActorID.t(), at: Es.Event.At.t()}
end
