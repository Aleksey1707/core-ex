defmodule Consumer.S.Draft do
  @moduledoc "Черновик события `Event.Codec.draft/1,2`: неверная пара событие–нагрузка."

  alias Consumer.Account
  alias Consumer.Grants
  alias Consumer.Order

  # B1 — событие другого кодека
  # expect: incompatible types given to Consumer.Account.Event.Codec.draft/1
  def b1_foreign_event, do: Account.Event.Codec.draft(Order.Event.Cancelled)

  # B1e — событие другого кодека со своей нагрузкой
  def b1e_foreign_event_with_payload(%Order.Amount{} = amount),
    # expect: incompatible types given to Consumer.Account.Event.Codec.draft/2
    do: Account.Event.Codec.draft(Order.Event.Placed, Order.Event.Placed.Payload.new(amount))

  # B1p — нагрузка другого агрегата, литерал
  def b1p_foreign_payload_literal(%Order.Amount{} = amount),
    # expect: incompatible types given to Consumer.Account.Event.Codec.draft/2
    do: Account.Event.Codec.draft(Account.Event.Opened, %Order.Event.Placed.Payload{amount: amount})

  # B1n — нагрузка другого агрегата через `Payload.new`
  def b1n_foreign_payload_new(%Order.Amount{} = amount),
    # expect: incompatible types given to Consumer.Account.Event.Codec.draft/2
    do: Account.Event.Codec.draft(Account.Event.Opened, Order.Event.Placed.Payload.new(amount))

  # B1s — не-struct вместо нагрузки
  # expect: incompatible types given to Consumer.Account.Event.Codec.draft/2
  def b1s_not_struct, do: Account.Event.Codec.draft(Account.Event.Opened, "opened")

  # B1g — нагрузка другого агрегата у кодека, где модуль нагрузки общий у двух событий
  def b1g_shared_payload_foreign(%Account.ID{} = id),
    # expect: incompatible types given to Consumer.Grants.Event.Codec.draft/2
    do: Grants.Event.Codec.draft(Grants.Event.Granted, id)

  # B2 — нагрузка другого события того же кодека, литерал
  def b2_sibling_payload_literal(%Account.Name{} = name),
    # expect: incompatible types given to Consumer.Account.Event.Codec.draft/2
    do: Account.Event.Codec.draft(Account.Event.Opened, %Account.Event.Renamed.Payload{name: name})

  # B2n — нагрузка другого события того же кодека через `Payload.new`
  def b2n_sibling_payload_new(%Account.Name{} = name),
    # expect: incompatible types given to Consumer.Account.Event.Codec.draft/2
    do: Account.Event.Codec.draft(Account.Event.Opened, Account.Event.Renamed.Payload.new(name))

  # B3 — `draft/1` события с нагрузкой
  # expect: incompatible types given to Consumer.Account.Event.Codec.draft/1
  def b3_payload_event_without_payload, do: Account.Event.Codec.draft(Account.Event.Opened)

  # B3b — `draft/2` события без нагрузки
  def b3b_event_without_payload_given_payload(%Account.Name{} = name),
    # expect: incompatible types given to Consumer.Account.Event.Codec.draft/2
    do: Account.Event.Codec.draft(Account.Event.Frozen, Account.Event.Opened.Payload.new(name))
end
