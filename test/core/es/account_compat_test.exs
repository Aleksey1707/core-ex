defmodule Core.Es.AccountCompatTest do
  use Core.Es.EventCompatCase,
    aggregate: Core.EsFixture.Account,
    async: true
end
