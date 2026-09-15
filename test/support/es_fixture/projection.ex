defmodule Core.EsFixture.Projection do
  @moduledoc """
  Проекция тестов `Core.Es.Projection`: строка на поток счёта (`Core.EsFixture.Account`) и
  state-stored агрегата (`Core.StateStoredFixture`, события `Core.EventFixture`) — название и
  признак закрытия.

  Объявлены не все теги: `Renamed`, `Frozen` и `Verified` счёта пачка пропускает. Таблица —
  миграция `priv/repo/migrations/20260914140000_create_projection_fixture.exs`.

  Закрытие потока без строки read-модели — отказ `project/1`: у счёта — `{:error, _}`, у агрегата
  `Core.EventFixture` — исключение.
  """

  import Ecto.Query, only: [from: 2]

  alias Core.Config
  alias Core.Error
  alias Core.EsFixture.Account
  alias Core.EventFixture

  require Error

  use Core.Es.Projection,
    name: "es_fixture",
    events: [
      Account.Event.Opened,
      Account.Event.Closed,
      EventFixture.Event.Created,
      EventFixture.Event.Closed
    ]

  defmodule Row do
    @moduledoc "Строка read-модели: поток агрегата."

    use Ecto.Schema

    @primary_key false

    schema "fixture_projection_streams" do
      field :aggregate_type, :string, primary_key: true
      field :aggregate_id, :binary_id, primary_key: true
      field :name, :string
      field :closed, :boolean
    end

    @type t :: %__MODULE__{}
  end

  @doc "Событие потока → строка read-модели."
  @spec project(Core.Es.Event.t()) :: :ok | {:error, Error.t()}

  @impl true
  def project(%Account.Event.Opened{payload: payload} = event),
    do: insert(event, "account", payload.name)

  def project(%EventFixture.Event.Created{payload: payload} = event),
    do: insert(event, "fixture", payload.name)

  def project(%Account.Event.Closed{} = event) do
    case close(event, "account") do
      1 -> :ok
      0 -> {:error, not_found(event)}
    end
  end

  def project(%EventFixture.Event.Closed{} = event) do
    1 = close(event, "fixture")
    :ok
  end

  @doc "Очистить read-модель."
  @spec clear() :: :ok

  @impl true
  def clear do
    {_count, nil} = Config.dao().delete_all(Row)
    :ok
  end

  # ---

  defp insert(event, type, name) do
    codec = Config.codec()

    row = %{
      aggregate_type: type,
      aggregate_id: codec.dump(event.aggregate_id),
      name: codec.dump(name),
      closed: false
    }

    {1, nil} = Config.dao().insert_all(Row, [row])
    :ok
  end

  defp close(event, type) do
    id = Config.codec().dump(event.aggregate_id)

    {count, nil} =
      from(r in Row, where: r.aggregate_type == ^type and r.aggregate_id == ^id)
      |> Config.dao().update_all(set: [closed: true])

    count
  end

  defp not_found(event) do
    Error.app(
      code: :stream_not_found,
      ns: :es_fixture,
      detail: %{aggregate_id: Config.codec().dump(event.aggregate_id)}
    )
  end
end
