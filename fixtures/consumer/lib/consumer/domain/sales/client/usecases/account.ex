defmodule Consumer.Domain.Sales.Client.Usecases.Account do
  @moduledoc "Типовые вызовы генерируемых функций счёта, его репозитория и фасада Codec: предупреждений быть не должно."

  alias Consumer.Codec.Internal, as: InCodec
  alias Consumer.DAO
  alias Consumer.Domain.Sales.Common.Account
  alias Consumer.Domain.Sales.Common.Order
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.Helper.Transact
  alias Core.Pagination
  alias Core.Version

  require Core.Config

  @repo Core.Config.repo!(Account.Repo)

  def open(%Account.ID{} = id, %Account.Cmd.Open{} = command, %Context{} = context) do
    Transact.run(DAO, fn ->
      with {:ok, account} <- @repo.get(id, :current, context),
           {:ok, {events, _account}} <- Account.execute(account, command) do
        @repo.append(events, context)
      end
    end)
  end

  def freeze(%Account.ID{} = id, %Version{} = version, %Account.Cmd.Freeze{} = command, %Context{} = context) do
    Transact.run(DAO, fn ->
      with {:ok, {events, _account}} <- @repo.get_decision(id, version, context, &Account.execute(&1, command)) do
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

  def owner(%Account.Name{} = name, %Context{} = context) do
    case Account.NameKey.find(name, context) do
      %Account.ID{} = id -> {:taken, id}
      nil -> :free
    end
  end

  def many(%Account.ID{} = a, %Account.ID{} = b, %Context{} = context),
    do: @repo.get_many([{a, :current}, {b, Version.new()}], context)

  def process(%Account.ID{} = id, %Account.Cmd.Open{} = command, %Context{} = context) do
    case Account.Process.execute(id, :current, command, context, fn _events -> :ok end) do
      {:ok, %Version{} = version} -> {:ok, Version.value(version)}
      {:ok, nil} -> {:ok, nil}
      {:error, %Error{}} = error -> error
    end
  end

  def close(%Account{} = state, %Account.Cmd.Close{} = command) do
    with {:ok, {events, closed}} <- Account.execute(state, command) do
      {length(events), closed.status}
    end
  end

  def history(%Account.ID{} = id, %Pagination.Limit{} = limit, %Pagination.Offset{} = offset, %Context{} = context) do
    case @repo.page_stream(id, limit, offset, context) do
      {:ok, page} -> {page.items, page.count}
      {:error, %Error{code: code}} -> {:error, code}
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
