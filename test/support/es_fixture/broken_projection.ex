defmodule Core.EsFixture.BrokenProjection do
  @moduledoc """
  Сломанная проекция проверок `Core.Es.ProjectionCase`: события счёта `Core.EsFixture.Account`,
  поток — в `fixture_broken_projection_streams`, название — в `fixture_broken_projection_names`.

  - у `project/1` нет клаузы `Closed`;
  - `clear/0` очищает только таблицу потоков.

  `Renamed` пропуском клаузы не считается: падает `FunctionClauseError` приватной функции, а не
  самой `project/1`. Таблицы — миграция
  `priv/repo/migrations/20260914145000_create_broken_projection_fixture.exs`.
  """

  alias Core.Config
  alias Core.EsFixture.Account

  use Core.Es.Projection,
    name: "es_fixture_broken",
    events: [Account.Event.Opened, Account.Event.Renamed, Account.Event.Closed]

  @streams "fixture_broken_projection_streams"
  @names "fixture_broken_projection_names"

  @doc "Открытие счёта → строки потока и названия; у `Closed` клаузы нет."
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
