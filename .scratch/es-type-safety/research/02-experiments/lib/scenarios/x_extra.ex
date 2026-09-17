defmodule Blind.S.Extra do
  alias Blind.Account
  alias Blind.Order
  alias Core.Context

  # X1 — execute через модуль-параметр (как QC.Transact.execute_all/3)
  def execute_all(aggregate, state, commands)
      when is_atom(aggregate) and is_struct(state) and is_list(commands) do
    Enum.reduce_while(commands, {:ok, {[], state}}, fn command, {:ok, {events, acc}} ->
      case aggregate.execute(acc, command) do
        {:ok, {executed, acc}} -> {:cont, {:ok, {events ++ executed, acc}}}
        {:error, %Core.Error{}} = err -> {:halt, err}
      end
    end)
  end

  def x1_execute_all_foreign_state(%Order{} = state, %Account.Cmd.Open{} = cmd),
    do: execute_all(Account, state, [cmd])

  # X2 — Outbox.from_events с не-событием
  def x2_outbox_not_event, do: Account.Outbox.from_events(["bad"])

  # X3 — Store.page_stream кодеком одного агрегата и ID другого
  def x3_page_stream_foreign_id(
        %Order.ID{} = id,
        %Core.Pagination.Limit{} = limit,
        %Core.Pagination.Offset{} = offset,
        %Context{} = context
      ),
      do: Core.Es.Store.page_stream(Account.Event.Codec, id, limit, offset, context)

  # X4 — repo чужого агрегата в usecase: get по ID и execute по состоянию
  require Core.Config

  @order_repo Core.Config.repo!(Blind.Order.Repo)

  def x4_state_from_other_repo(%Order.ID{} = id, %Account.Cmd.Open{} = cmd, %Context{} = context) do
    with {:ok, state} <- @order_repo.get(id, :current, context) do
      Account.execute(state, cmd)
    end
  end

  # X5 — события одного агрегата в append репозитория другого
  def x5_append_foreign_events(%Account{} = state, %Account.Cmd.Open{} = cmd, %Context{} = context) do
    with {:ok, {events, _state}} <- Account.execute(state, cmd) do
      @order_repo.append(events, context)
    end
  end

  @account_repo Core.Config.repo!(Blind.Account.Repo)

  # X6 — чужой ID через defp (как role/3 в usecase qc)
  def x6_foreign_id_via_defp(%Order.ID{} = id, %Context{} = context), do: load(id, context)

  defp load(id, context), do: @account_repo.get(id, :current, context)

  # X7 — чужой ID внутри замыкания Transact.run (как Transact.run(:current, fn -> ... end) в qc)
  def x7_foreign_id_in_closure(%Order.ID{} = id, %Context{} = context) do
    Core.Helper.Transact.run(Blind.DAO, fn -> @account_repo.get(id, :current, context) end)
  end

  # X8 — чужой ID в public-обёртке без паттерна
  def x8_wrapper(id, context), do: @account_repo.get(id, :current, context)

  def x8_foreign_id_via_wrapper(%Order.ID{} = id, %Context{} = context), do: x8_wrapper(id, context)
end
