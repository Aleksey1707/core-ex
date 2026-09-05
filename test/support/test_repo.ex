defmodule Core.TestRepo do
  @moduledoc """
  Ecto-репозиторий тестов библиотеки.

  Повторяет то, что в приложении-потребителе делает его `DAO`: единственный
  Postgres-репозиторий, объявленный через `Core.DAO` — чтобы работали хуки `AfterCommit`.
  """

  use Core.DAO,
    otp_app: :core,
    adapter: Ecto.Adapters.Postgres
end
