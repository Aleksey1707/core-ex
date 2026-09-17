defmodule Core.EsFixture.BrokenProjection do
  @moduledoc """
  Сломанная проекция проверок `Core.Es.ProjectionCase`: события счёта `Core.EsFixture.Account`,
  поток — в `fixture_broken_projection_streams`, название — в `fixture_broken_projection_names`.

  - `clear/0` очищает только таблицу потоков;
  - `project/1` на `Renamed` падает `FunctionClauseError` приватной функции: отказ на фикстуре
    проверка откатывает и идёт дальше.

  Таблицы — миграция `priv/repo/migrations/20260914145000_create_broken_projection_fixture.exs`.
  """

  alias Core.Config
  alias Core.EsFixture.Account

  use Core.Es.Projection,
    name: "es_fixture_broken",
    events: [Account.Event.Opened, Account.Event.Renamed, Account.Event.Closed]

  @streams "fixture_broken_projection_streams"
  @names "fixture_broken_projection_names"

  @doc "Событие счёта → строки потока и названия при открытии."
  @spec project(Core.Es.Event.t()) :: :ok

  @impl true
  def project(%Account.Event.Opened{payload: payload} = event) do
    codec = Config.codec()

    {1, nil} =
      Config.dao().insert_all(@streams, [%{aggregate_id: codec.dump(event.aggregate_id)}])

    {1, nil} = Config.dao().insert_all(@names, [%{name: codec.dump(payload.name)}])
    :ok
  end

  def project(%Account.Event.Renamed{payload: payload}), do: rename(payload.name)

  def project(%Account.Event.Closed{}), do: :ok

  @doc "Очистить read-модель — таблица названий забыта."
  @spec clear() :: :ok

  @impl true
  def clear do
    {_count, nil} = Config.dao().delete_all(@streams)
    :ok
  end

  # ---

  defp rename(nil), do: :ok
end
