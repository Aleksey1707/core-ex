defmodule Consumer.Account.Event do
  @moduledoc "События счёта."

  alias Consumer.Account.Event.Closed
  alias Consumer.Account.Event.Frozen
  alias Consumer.Account.Event.Opened
  alias Consumer.Account.Event.Renamed

  @type t :: Opened.t() | Renamed.t() | Frozen.t() | Closed.t()
end
