defmodule Blind.S.Usecase do
  alias Blind.Account
  alias Core.Context

  require Core.Config

  @repo Core.Config.repo!(Blind.Account.Repo)

  # X9 — usecase с паттерном в голове
  def get_typed(%Account.ID{} = id, %Context{} = context), do: @repo.get(id, :current, context)

  # X9b — usecase без паттерна
  def get_untyped(id, context), do: @repo.get(id, :current, context)

  # X9c — usecase-команда: результат для вызывающего
  def open(%Account{} = state, %Account.Cmd.Open{} = cmd, %Context{} = context) do
    with {:ok, {events, executed}} <- Account.execute(state, cmd),
         :ok <- @repo.append(events, context) do
      {:ok, executed}
    end
  end
end

defmodule Blind.S.Controller do
  alias Blind.Account
  alias Blind.Order
  alias Blind.S.Usecase
  alias Core.Context

  def x9_typed(%Order.ID{} = id, %Context{} = context), do: Usecase.get_typed(id, context)

  def x9b_untyped(%Order.ID{} = id, %Context{} = context), do: Usecase.get_untyped(id, context)

  def x9c_result_typo(%Account{} = state, %Account.Cmd.Open{} = cmd, %Context{} = context) do
    case Usecase.open(state, cmd, context) do
      {:ok, executed} -> executed.nmae
      :ok -> nil
      {:error, _error} -> nil
    end
  end
end
