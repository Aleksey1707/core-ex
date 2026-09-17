defmodule Blind.S.EventNew do
  alias Blind.Account
  alias Blind.Order
  alias Blind.UserID
  alias Core.Es
  alias Core.Version

  # D1 — неверная нагрузка (литерал чужой нагрузки)
  def d1_wrong_payload(%Account.Name{} = name, %Account.ID{} = id, %UserID{} = by, %Es.Event.At{} = at),
    do: Account.Event.Opened.new(%Account.Event.Renamed.Payload{name: name}, id, Version.new(), by, at)

  # D1b — неверная нагрузка из конструктора Payload.new/1
  def d1b_wrong_payload_new(%Account.Name{} = name, %Account.ID{} = id, %UserID{} = by, %Es.Event.At{} = at),
    do: Account.Event.Opened.new(Account.Event.Renamed.Payload.new(name), id, Version.new(), by, at)

  # D1c — нагрузка — не struct
  def d1c_payload_map(%Account.ID{} = id, %UserID{} = by, %Es.Event.At{} = at),
    do: Account.Event.Opened.new(%{name: "x"}, id, Version.new(), by, at)

  # D2 — чужой Prim в aggregate_id (из паттерна в голове)
  def d2_foreign_aggregate_id(%Account.Event.Opened.Payload{} = p, %Order.ID{} = id, %UserID{} = by, %Es.Event.At{} = at),
    do: Account.Event.Opened.new(p, id, Version.new(), by, at)

  # D2b — чужой Prim в aggregate_id из Order.ID.new/0
  def d2b_foreign_aggregate_id_new(%Account.Event.Opened.Payload{} = p, %UserID{} = by, %Es.Event.At{} = at),
    do: Account.Event.Opened.new(p, Order.ID.new(), Version.new(), by, at)

  # D2c — чужой Prim в aggregate_id из {:ok, id} = Order.ID.new(raw)
  def d2c_foreign_aggregate_id_parsed(%Account.Event.Opened.Payload{} = p, raw, %UserID{} = by, %Es.Event.At{} = at) do
    {:ok, id} = Order.ID.new(raw)
    Account.Event.Opened.new(p, id, Version.new(), by, at)
  end

  # D3 — чужой Prim в by
  def d3_foreign_by(%Account.Event.Opened.Payload{} = p, %Account.ID{} = id, %Order.ID{} = by, %Es.Event.At{} = at),
    do: Account.Event.Opened.new(p, id, Version.new(), by, at)

  # D3b — чужой Prim в by из Order.ID.new/0
  def d3b_foreign_by_new(%Account.Event.Opened.Payload{} = p, %Account.ID{} = id, %Es.Event.At{} = at),
    do: Account.Event.Opened.new(p, id, Version.new(), Order.ID.new(), at)

  # D4 — DateTime вместо Es.Event.At; целое вместо Version (событие без нагрузки)
  def d4_datetime_at(%Account.ID{} = id, %UserID{} = by),
    do: Account.Event.Closed.new(id, Version.new(), by, DateTime.utc_now())

  def d4b_int_version(%Account.ID{} = id, %UserID{} = by, %Es.Event.At{} = at),
    do: Account.Event.Closed.new(id, 1, by, at)

  # D5 — опечатка в поле события, возвращённого конструктором
  def d5_event_typo(%Account.ID{} = id, %UserID{} = by, %Es.Event.At{} = at) do
    event = Account.Event.Closed.new(id, Version.new(), by, at)
    event.aggregat_id
  end
end
