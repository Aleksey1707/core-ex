defmodule Consumer.Domain.Sales.Itinerary.Projection do
  @moduledoc """
  Read-модель шагов маршрута: открытые поля шага пишутся рядом с ПДн, уничтоженное ПДн-место —
  не ПДн-значение. Строки чистит событие уничтожения ключа.
  """

  alias Consumer.Domain.Sales.Itinerary.Event
  alias Consumer.Domain.Sales.Itinerary.Step
  alias Core.Es.Personal.Destroyed
  alias Core.Es.Personal.Event.KeyDestroyed

  use Core.Es.Projection,
    name: "itinerary_steps",
    events: [Event.Planned, KeyDestroyed]

  @impl true
  def project(%Event.Planned{payload: %Event.Planned.Payload{steps: steps}}), do: steps(steps)

  def project(%KeyDestroyed{}), do: :ok

  @impl true
  def clear, do: :ok

  # ---

  defp steps(steps), do: Enum.each(steps, &step/1)

  defp step(%Step{recipient: %Destroyed{}}), do: :ok
  defp step(%Step{content: %Destroyed{}}), do: :ok
  defp step(%Step{}), do: :ok
end
