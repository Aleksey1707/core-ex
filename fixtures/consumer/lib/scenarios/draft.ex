defmodule Consumer.S.Draft do
  @moduledoc """
  Черновик события `Event.Mod.draft/0,1`: неверная нагрузка или арность.

  B1 и B1e — событие другого агрегата — сборка не ловит: `draft` у чужого события законен, провал —
  `FunctionClauseError` при исполнении команды (ADR-0014, «Результат `decide`»).
  """

  alias Consumer.Account
  alias Consumer.Grants
  alias Consumer.Order

  # B1p — нагрузка другого агрегата, литерал
  def b1p_foreign_payload_literal(%Order.Amount{} = amount),
    # expect: incompatible types given to Consumer.Account.Event.Opened.draft/1
    do: Account.Event.Opened.draft(%Order.Event.Placed.Payload{amount: amount})

  # B1n — нагрузка другого агрегата через `Payload.new`
  def b1n_foreign_payload_new(%Order.Amount{} = amount),
    # expect: incompatible types given to Consumer.Account.Event.Opened.draft/1
    do: Account.Event.Opened.draft(Order.Event.Placed.Payload.new(amount))

  # B1s — не-struct вместо нагрузки
  # expect: incompatible types given to Consumer.Account.Event.Opened.draft/1
  def b1s_not_struct, do: Account.Event.Opened.draft("opened")

  # B1g — нагрузка другого агрегата у события, чей модуль нагрузки общий с соседним событием
  # expect: incompatible types given to Consumer.Grants.Event.Granted.draft/1
  def b1g_shared_payload_foreign(%Account.ID{} = id), do: Grants.Event.Granted.draft(id)

  # B2 — нагрузка другого события того же агрегата, литерал
  def b2_sibling_payload_literal(%Account.Name{} = name),
    # expect: incompatible types given to Consumer.Account.Event.Opened.draft/1
    do: Account.Event.Opened.draft(%Account.Event.Renamed.Payload{name: name})

  # B2n — нагрузка другого события того же агрегата через `Payload.new`
  def b2n_sibling_payload_new(%Account.Name{} = name),
    # expect: incompatible types given to Consumer.Account.Event.Opened.draft/1
    do: Account.Event.Opened.draft(Account.Event.Renamed.Payload.new(name))

  # B3 — `draft/0` события с нагрузкой
  # expect: Consumer.Account.Event.Opened.draft/0 is undefined or private
  def b3_payload_event_without_payload, do: Account.Event.Opened.draft()

  # B3b — `draft/1` события без нагрузки
  def b3b_event_without_payload_given_payload(%Account.Name{} = name),
    # expect: Consumer.Account.Event.Frozen.draft/1 is undefined or private
    do: Account.Event.Frozen.draft(Account.Event.Opened.Payload.new(name))
end
