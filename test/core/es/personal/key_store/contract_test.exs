defmodule Core.Es.Personal.KeyStore.ContractTest do
  use Core.Es.Personal.KeyStoreCase,
    impl: Core.Es.Personal.KeyStore.Pg,
    async: true
end
