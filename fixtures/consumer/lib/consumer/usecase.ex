defmodule Consumer.Usecase do
  @moduledoc "Типовые вызовы генерируемых функций и функций `Core.Es`: предупреждений быть не должно."

  alias Consumer.Account
  alias Consumer.AlwaysFails
  alias Consumer.Codec.Internal, as: InCodec
  alias Consumer.DAO
  alias Consumer.Grants
  alias Consumer.NeverFails
  alias Consumer.Order
  alias Consumer.Ping
  alias Consumer.Projection
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.Helper.Transact
  alias Core.Pagination
  alias Core.Version

  require Core.Config

  @repo Core.Config.repo!(Consumer.Account.Repo)
  @order_repo Core.Config.repo!(Consumer.Order.Repo)

  def open(%Account.ID{} = id, %Account.Cmd.Open{} = command, %Context{} = context) do
    Transact.run(DAO, fn ->
      with {:ok, account} <- @repo.get(id, :current, context),
           {:ok, {events, _account}} <- Account.execute(account, command) do
        @repo.append(events, context)
      end
    end)
  end

  def rename(%Account{} = state, %Account.Cmd.Rename{} = command) do
    case Account.execute(state, command) do
      {:ok, {[], executed}} -> {:unchanged, executed.name}
      {:ok, {events, executed}} -> {:changed, length(events), executed.name}
      {:error, %Error{code: code}} -> {:error, code}
    end
  end

  def refresh(%Account{} = state, %Context{} = context) do
    case @repo.refresh(state, Version.new(), context) do
      {:ok, refreshed} -> refreshed.status
      {:error, %Error{code: :version_mismatch}} -> nil
    end
  end

  def many(%Account.ID{} = a, %Account.ID{} = b, %Context{} = context),
    do: @repo.get_many([{a, :current}, {b, Version.new()}], context)

  def place(%Order.ID{} = id, %Order.Cmd.Place{} = command, %Context{} = context) do
    Transact.run(DAO, fn ->
      with {:ok, order} <- @order_repo.get(id, :current, context),
           {:ok, {events, _order}} <- Order.execute(order, command) do
        @order_repo.append(events, context)
      end
    end)
  end

  def process(%Account.ID{} = id, %Account.Cmd.Open{} = command, %Context{} = context) do
    case Account.Process.execute(id, :current, command, context, fn _events -> :ok end) do
      :ok -> :ok
      {:error, %Error{}} = error -> error
    end
  end

  def close(%Account{} = state, %Account.Cmd.Close{} = command) do
    with {:ok, {events, closed}} <- Account.execute(state, command) do
      {length(events), closed.status}
    end
  end

  def grant(%Grants{} = state, %Grants.Cmd.Grant{} = command) do
    with {:ok, {events, granted}} <- Grants.execute(state, command) do
      {length(events), MapSet.size(granted.roles)}
    end
  end

  def hit(%Ping{} = state, %Ping.Cmd.Hit{} = command) do
    with {:ok, {_events, hit}} <- Ping.execute(state, command), do: hit.count
  end

  def cancel(%NeverFails{} = state, %Order.Cmd.Cancel{} = command) do
    case NeverFails.execute(state, command) do
      {:ok, {events, cancelled}} -> {length(events), cancelled.cancelled?}
      {:error, %Error{code: code}} -> {:error, code}
    end
  end

  def refuse(%AlwaysFails{} = state, %Order.Cmd.Place{} = command) do
    case AlwaysFails.execute(state, command) do
      {:ok, {events, _placed}} -> length(events)
      {:error, %Error{code: code}} -> {:error, code}
    end
  end

  def history(%Account.ID{} = id, %Pagination.Limit{} = limit, %Pagination.Offset{} = offset, %Context{} = context) do
    case @repo.page_stream(id, limit, offset, context) do
      {:ok, page} -> {page.items, page.count}
      {:error, %Error{code: code}} -> {:error, code}
    end
  end

  def await(%Account.ID{} = account_id, %Order.ID{} = order_id) do
    with :ok <- Projection.await(Account, account_id, 5_000),
         :ok <- Projection.await(Order, order_id, 5_000) do
      :ok
    else
      {:error, %Error{code: :projection_timeout}} -> :timeout
      {:error, %Error{} = error} -> {:error, error.code}
    end
  end

  def load(data) do
    case InCodec.load(Account.Event, data) do
      {:ok, %Account.Event.Opened{} = event} -> {:opened, event.payload.name}
      {:ok, event} -> {:other, event.aggregate_id}
      {:error, %Error{} = error} -> {:error, error.code}
    end
  end

  def load_opened(data) do
    with {:ok, event} <- InCodec.load(Account.Event.Opened, data),
         do: {:ok, {event.aggregate_id, event.payload.name}}
  end

  def load_bang(data) do
    case InCodec.load!(Account.Event, data) do
      %Account.Event.Renamed{} = event -> event.payload.name
      event -> event.aggregate_id
    end
  end

  def load_name(raw) do
    with {:ok, name} <- InCodec.load(Account.Name, raw), do: InCodec.dump(name)
  end

  def dump(%Account.Event.Opened{} = event, %Account.Card{} = card, %Order.Amount{} = amount),
    do: {InCodec.dump(event), InCodec.dump(card), InCodec.dump(amount), InCodec.dump(InCodec.load!(Order.Amount, 1))}

  def fresh, do: {Account.ID.new(), Version.new(), Es.Event.At.now!()}

  def fold_history(%Account{} = state, events) when is_list(events),
    do: Account.fold(state, events).status
end
