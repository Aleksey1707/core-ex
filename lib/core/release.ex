defmodule Core.Release do
  @moduledoc """
  Миграции на релизе, где Mix нет (`bin/my_app eval`).

  Приложение зовёт задачи из своего модуля релиза:

      defmodule MyAppApp.Release do
        def migrate, do: Core.Release.migrate(:my_app)

        def rollback(version), do: Core.Release.rollback(:my_app, MyApp.Infra.DAO, version)
      end

      bin/my_app eval 'MyAppApp.Release.migrate()'
      bin/my_app eval 'MyAppApp.Release.rollback(20260902110000)'

  Задача сама загружает приложение (`Application.load/1`), чтобы прочитать `:ecto_repos` и
  конфигурацию репозиториев, но его не стартует: на время команды поднимается только репозиторий
  (`Ecto.Migrator.with_repo/2`). Миграции берутся из `priv` репозитория, как у `mix ecto.migrate`.

  Ответ оператору — `IO.puts`: Mix в релизе нет (`20-agreements.md`, «Логирование»).
  """

  @doc """
  Накатить все невыполненные миграции каждого репозитория из `:ecto_repos` приложения и сообщить их
  число по репозиториям.
  """
  @spec migrate(atom()) :: :ok

  def migrate(app) when is_atom(app) do
    load(app)

    for repo <- Application.fetch_env!(app, :ecto_repos) do
      {:ok, versions, _apps} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))

      IO.puts("Применено миграций в #{inspect(repo)}: #{length(versions)}")
    end

    :ok
  end

  @doc """
  Откатить миграции репозитория до `version` включительно и сообщить их число.
  """
  @spec rollback(atom(), Ecto.Repo.t(), pos_integer()) :: :ok

  def rollback(app, repo, version) when is_atom(app) and is_atom(repo) and is_integer(version) and version > 0 do
    load(app)

    {:ok, versions, _apps} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))

    IO.puts("Откачено миграций в #{inspect(repo)}: #{length(versions)}")
  end

  # ---

  defp load(app) do
    case Application.load(app) do
      :ok -> :ok
      {:error, {:already_loaded, ^app}} -> :ok
    end
  end
end
