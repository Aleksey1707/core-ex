defmodule Consumer.Domain.Sales.Account.Profile.Codec do
  alias Consumer.Domain.Sales.Account

  use Core.Codec.Plugin, types: [Account.Profile, Account.Profile.Contact]
end
