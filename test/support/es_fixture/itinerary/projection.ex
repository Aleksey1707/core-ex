defmodule Core.EsFixture.Itinerary.Projection do
  @moduledoc """
  Проекция шагов маршрута: строка на шаг, ПДн-места `recipient`/`content` — рядом с открытыми
  полями. Уничтоженное ПДн-значение пишется `NULL`, по событию уничтожения ключа строки субъекта
  удаляются.
  """

  import Ecto.Query, only: [from: 2]

  alias Core.Config
  alias Core.Es.Personal.Destroyed
  alias Core.Es.Personal.Event.KeyDestroyed
  alias Core.EsFixture.Itinerary.Event.Planned
  alias Core.Result

  use Core.Es.Projection,
    name: "itinerary",
    events: [Planned, KeyDestroyed]

  defmodule Step do
    @moduledoc "Строка шага маршрута: открытая часть и два ПДн-места."

    use Ecto.Schema

    @primary_key false

    schema "fixture_itinerary_steps" do
      field :aggregate_id, :binary_id, primary_key: true
      field :step_index, :integer, primary_key: true
      field :channel, :string
      field :recipient, :string
      field :content, :string
    end

    @type t :: %__MODULE__{}
  end

  @doc "Событие маршрута → строки шагов."
  @spec project(Core.Es.Event.t()) :: Result.unit()

  @impl true
  def project(%Planned{payload: %Planned.Payload{steps: steps}} = event) do
    id = Config.codec().dump(event.aggregate_id)
    {_count, nil} = Config.dao().delete_all(from(s in Step, where: s.aggregate_id == ^id))

    rows =
      steps
      |> Enum.with_index()
      |> Enum.map(fn {step, index} ->
        %{
          aggregate_id: id,
          step_index: index,
          channel: step.channel,
          recipient: value(step.recipient),
          content: value(step.content)
        }
      end)

    {_count, nil} = Config.dao().insert_all(Step, rows)
    :ok
  end

  # Субъект ПДн-мест — сам маршрут: строки находятся по идентификатору субъекта.
  def project(%KeyDestroyed{aggregate_id: subject}) do
    id = Config.codec().dump(subject)
    {_count, nil} = Config.dao().delete_all(from(s in Step, where: s.aggregate_id == ^id))
    :ok
  end

  @doc "Очистить read-модель."
  @spec clear() :: :ok

  @impl true
  def clear do
    {_count, nil} = Config.dao().delete_all(Step)
    :ok
  end

  # ---

  # Уничтоженное значение — не ПДн: строка остаётся без значения места.
  defp value(%Destroyed{}), do: nil
  defp value(nil), do: nil
  defp value(prim), do: Config.codec().dump(prim)
end
