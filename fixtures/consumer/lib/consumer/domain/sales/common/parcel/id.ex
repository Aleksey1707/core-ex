defmodule Consumer.Domain.Sales.Common.Parcel.ID do
  use Core.Prim.UUID,
    name: "Посылка",
    version: 7
end
