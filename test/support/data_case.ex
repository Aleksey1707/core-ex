defmodule Core.DataCase do
  @moduledoc """
  Setup для тестов, которым нужен Postgres: Ecto Sandbox поверх `Core.TestRepo`.

  `async: true` работает благодаря sandbox-владельцу на процесс теста.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Core.TestRepo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Core.DataCase
    end
  end

  setup tags do
    Core.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc "Поднять sandbox по тегам теста."
  @spec setup_sandbox(map()) :: :ok

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Core.TestRepo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end
end
