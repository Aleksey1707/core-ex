defmodule Consumer.S.EventNew do
  @moduledoc "Конструктор события: нагрузка, Prim агрегата и автора, момент, версия."

  alias Consumer.Account
  alias Consumer.Order
  alias Consumer.UserID
  alias Core.Es
  alias Core.Version

  # D1 — литерал нагрузки другого события
  def d1_foreign_payload(%Account.Name{} = name, %Account.ID{} = id, %UserID{} = by, %Es.Event.At{} = at),
    # expect: incompatible types given to Consumer.Account.Event.Opened.new/5
    do: Account.Event.Opened.new(%Account.Event.Renamed.Payload{name: name}, id, Version.new(), by, at)

  # D1b — нагрузка другого события из `Payload.new/1`
  def d1b_foreign_payload_new(%Account.Name{} = name, %Account.ID{} = id, %UserID{} = by, %Es.Event.At{} = at),
    # expect: incompatible types given to Consumer.Account.Event.Opened.new/5
    do: Account.Event.Opened.new(Account.Event.Renamed.Payload.new(name), id, Version.new(), by, at)

  # D1c — map вместо нагрузки
  def d1c_payload_map(%Account.ID{} = id, %UserID{} = by, %Es.Event.At{} = at),
    # expect: incompatible types given to Consumer.Account.Event.Opened.new/5
    do: Account.Event.Opened.new(%{name: "x"}, id, Version.new(), by, at)

  # D2 — ID другого агрегата из паттерна
  def d2_foreign_aggregate_id(%Account.Event.Opened.Payload{} = payload, %Order.ID{} = id, %UserID{} = by),
    # expect: incompatible types given to Consumer.Account.Event.Opened.new/5
    do: Account.Event.Opened.new(payload, id, Version.new(), by, Es.Event.At.new!(DateTime.utc_now()))

  # D2b — ID другого агрегата из `Order.ID.new()`
  def d2b_foreign_aggregate_id_new(%Account.Event.Opened.Payload{} = payload, %UserID{} = by, %Es.Event.At{} = at),
    # expect: incompatible types given to Consumer.Account.Event.Opened.new/5
    do: Account.Event.Opened.new(payload, Order.ID.new(), Version.new(), by, at)

  # D2c — ID другого агрегата из `{:ok, id} = ID.new(raw)`
  def d2c_foreign_aggregate_id_parsed(%Account.Event.Opened.Payload{} = payload, raw, %UserID{} = by) do
    {:ok, id} = Order.ID.new(raw)
    {:ok, at} = Es.Event.At.now()
    # expect: incompatible types given to Consumer.Account.Event.Opened.new/5
    Account.Event.Opened.new(payload, id, Version.new(), by, at)
  end

  # D3 — Prim другого вида в `by`
  def d3_foreign_by(%Account.Event.Opened.Payload{} = payload, %Account.ID{} = id, %Order.ID{} = by, at),
    # expect: incompatible types given to Consumer.Account.Event.Opened.new/5
    do: Account.Event.Opened.new(payload, id, Version.new(), by, at)

  # D3b — Prim другого вида в `by` из `Order.ID.new()`
  def d3b_foreign_by_new(%Account.Event.Opened.Payload{} = payload, %Account.ID{} = id, %Es.Event.At{} = at),
    # expect: incompatible types given to Consumer.Account.Event.Opened.new/5
    do: Account.Event.Opened.new(payload, id, Version.new(), Order.ID.new(), at)

  # D4 — `DateTime` вместо `Es.Event.At`
  def d4_datetime_at(%Account.ID{} = id, %UserID{} = by),
    # expect: incompatible types given to Consumer.Account.Event.Closed.new/4
    do: Account.Event.Closed.new(id, Version.new(), by, DateTime.utc_now())

  # D4b — целое вместо `Version`
  def d4b_integer_version(%Account.ID{} = id, %UserID{} = by, %Es.Event.At{} = at),
    # expect: incompatible types given to Consumer.Account.Event.Closed.new/4
    do: Account.Event.Closed.new(id, 1, by, at)

  # D5 — опечатка в поле события, собранного конструктором
  def d5_event_typo(%Account.ID{} = id, %UserID{} = by, %Es.Event.At{} = at) do
    event = Account.Event.Closed.new(id, Version.new(), by, at)
    # expect: unknown key .aggregat_id
    event.aggregat_id
  end
end
