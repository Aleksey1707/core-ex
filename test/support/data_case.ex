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

  @doc """
  Ошибки changeset'а как карта сообщений.

      assert %{login: ["не может быть пустым"]} = errors_on(changeset)
  """
  @spec errors_on(Ecto.Changeset.t()) :: map()

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts
        |> Keyword.get(String.to_existing_atom(key), key)
        |> to_string()
      end)
    end)
  end
end
