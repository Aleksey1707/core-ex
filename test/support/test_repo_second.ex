defmodule Core.TestRepoSecond do
  @moduledoc """
  Второй Ecto-репозиторий тестов библиотеки — на ту же базу, что `Core.TestRepo`.

  Нужен там, где проверяется, что `dao` команды задаёт реализация репозитория агрегата
  (`repo:`), а не `Core.Config.dao/0`: два репозитория на одной базе дают два разных соединения.
  """

  use Core.DAO,
    otp_app: :core,
    adapter: Ecto.Adapters.Postgres
end
