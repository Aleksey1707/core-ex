defmodule Blind.Usecase do
  @moduledoc "Корректные вызовы сгенерированных функций: предупреждений быть не должно."

  alias Blind.Account
  alias Blind.AlwaysFails
  alias Blind.NeverFails
  alias Blind.Order
  alias Core.Context
  alias Core.Es
  alias Core.Version

  require Core.Config

  @repo Core.Config.repo!(Blind.Account.Repo)

  def open(%Account.ID{} = id, %Account.Cmd.Open{} = cmd, %Context{} = context) do
    with {:ok, state} <- @repo.get(id, :current, context),
         {:ok, {events, %Account{status: :open}}} <- Account.execute(state, cmd) do
      @repo.append(events, context)
    end
  end

  def rename(%Account{} = state, %Account.Cmd.Rename{} = cmd) do
    case Account.execute(state, cmd) do
      {:ok, {[], executed}} -> {:unchanged, executed.name}
      {:ok, {events, executed}} -> {:changed, length(events), executed.name}
      {:error, %Core.Error{code: code}} -> {:error, code}
    end
  end

  def refresh(%Account{} = state, %Context{} = context) do
    case @repo.refresh(state, Version.new(), context) do
      {:ok, refreshed} -> refreshed.status
      {:error, %Core.Error{code: :version_mismatch}} -> nil
    end
  end

  def many(%Account.ID{} = a, %Account.ID{} = b, %Context{} = context),
    do: @repo.get_many([{a, :current}, {b, Version.new()}], context)

  def process(%Account.Cmd.Open{} = cmd, %Context{} = context) do
    case Account.Process.execute(Account.ID.new(), :current, cmd, context, fn _events -> :ok end) do
      :ok -> :ok
      {:error, %Core.Error{}} = error -> error
    end
  end

  def never_fails(%NeverFails{} = state, %Order.Cmd.Cancel{} = cmd) do
    {:ok, {events, executed}} = NeverFails.execute(state, cmd)
    {events, executed.cancelled?}
  end

  def always_fails(%AlwaysFails{} = state, %Order.Cmd.Place{} = cmd) do
    {:error, error} = AlwaysFails.execute(state, cmd)
    error.code
  end

  def fresh_ids, do: {Account.ID.new(), Version.new(), Es.Event.At.now!()}

  def fold_history(%Account{} = state, events) when is_list(events),
    do: Account.fold(state, events).status
end
