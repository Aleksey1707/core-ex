defmodule Consumer.Domain.Sales.Itinerary.Client.Usecases do
  @moduledoc """
  Типовые вызовы агрегата маршрута: шаг на записи — `Step.write_t()`, прочитанный шаг несёт
  уничтоженные ПДн-места наравне с открытой частью.
  """

  alias Consumer.Domain.Sales.Itinerary
  alias Consumer.Domain.Sales.Itinerary.Step
  alias Consumer.Domain.Sales.Values.UserID
  alias Consumer.Infra.DAO
  alias Core.Context
  alias Core.Es
  alias Core.Es.Personal.Destroyed
  alias Core.Helper.Transact
  alias Core.Result

  require Core.Config

  @repo Core.Config.repo!(Itinerary.Repo)

  @spec plan(Itinerary.ID.t(), [Step.write_t()], UserID.t(), Context.t()) :: Result.t(non_neg_integer())

  def plan(%Itinerary.ID{} = id, steps, %UserID{} = by, %Context{} = context) when is_list(steps) do
    command = %Itinerary.Cmd.Plan{steps: steps, by: by, at: Es.Event.At.now!()}

    Transact.run(DAO, fn ->
      with {:ok, itinerary} <- @repo.get(id, :current, context),
           {:ok, {events, planned}} <- Itinerary.execute(itinerary, command),
           :ok <- @repo.append(events, context),
           do: {:ok, attempts(planned.steps)}
    end)
  end

  @spec attempts([Step.t()]) :: non_neg_integer()

  def attempts(steps) when is_list(steps), do: Enum.reduce(steps, 0, &step_attempts/2)

  @spec channels([Step.t()]) :: [Itinerary.Channel.t()]

  def channels(steps) when is_list(steps), do: Enum.map(steps, & &1.channel)

  # ---

  defp step_attempts(%Step{recipient: %Destroyed{}}, total), do: total
  defp step_attempts(%Step{content: %Destroyed{}}, total), do: total
  defp step_attempts(%Step{attempts: attempts}, total), do: total + attempts
end
