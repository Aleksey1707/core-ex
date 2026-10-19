defmodule Core.EsFixture.PersonalBrokenProjection do
  @moduledoc """
  Сломанная пара `Core.EsFixture.Projection` для проверок ПДн `Core.Es.ProjectionCase`: владелец
  счёта из `HolderSet` — в `fixture_broken_projection_holders`.

  - `project/1` на уничтоженном значении падает `FunctionClauseError`: значение разбирается
    функцией Prim;
  - событие уничтожения ключа строку владельца оставляет.

  Таблица — миграция `priv/repo/migrations/20261019143200_create_projection_holders_fixture.exs`.
  """

  alias Core.Config
  alias Core.Es.Personal.Event.KeyDestroyed
  alias Core.EsFixture.Account

  use Core.Es.Projection,
    name: "es_fixture_personal_broken",
    events: [Account.Event.HolderSet, KeyDestroyed]

  defmodule Holder do
    @moduledoc "Строка владельца счёта."

    use Ecto.Schema

    @primary_key false

    schema "fixture_broken_projection_holders" do
      field :aggregate_id, :binary_id, primary_key: true
      field :holder, :string
    end

    @type t :: %__MODULE__{}
  end

  @doc "Владелец счёта → строка; событие уничтожения ключа ничего не чистит."
  @spec project(Core.Es.Event.t()) :: :ok

  @impl true
  def project(%Account.Event.HolderSet{payload: %Account.Event.HolderSet.Payload{holder: holder}} = event) do
    row = %{aggregate_id: Config.codec().dump(event.aggregate_id), holder: Account.Holder.value(holder)}
    {1, nil} = Config.dao().insert_all(Holder, [row])
    :ok
  end

  def project(%KeyDestroyed{}), do: :ok

  @doc "Очистить read-модель."
  @spec clear() :: :ok

  @impl true
  def clear do
    {_count, nil} = Config.dao().delete_all(Holder)
    :ok
  end
end
