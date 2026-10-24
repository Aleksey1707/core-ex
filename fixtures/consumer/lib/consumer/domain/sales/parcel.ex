defmodule Consumer.Domain.Sales.Parcel do
  @moduledoc "Посылка — владелец потока событий без агрегата и репозитория."

  alias Consumer.Domain.Sales.Parcel

  defstruct id: nil

  @type t :: %__MODULE__{id: Parcel.ID.t() | nil}
end
