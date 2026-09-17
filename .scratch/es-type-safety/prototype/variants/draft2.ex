# Вариант P1: конструктор арности 2 `draft(Event.Mod, payload)` — то, что сгенерировал бы кодек для
# событий с общим модулем нагрузки. Модуль написан руками в форме сгенерированного.
defmodule Blind.Draft2 do
  alias Blind.Account.Event

  def draft(Event.Opened, %Event.Opened.Payload{} = payload), do: {Event.Opened, payload}
  def draft(Event.Renamed, %Event.Renamed.Payload{} = payload), do: {Event.Renamed, payload}
  def draft(Event.Frozen), do: Event.Frozen
  def draft(Event.Closed), do: Event.Closed
end

defmodule Blind.S.Draft2 do
  alias Blind.Account
  alias Blind.Account.Event

  # B2 — не та нагрузка у своего события, литерал
  def b2_literal, do: Blind.Draft2.draft(Event.Opened, %Event.Renamed.Payload{name: nil})

  # B2n — не та нагрузка у своего события, через Payload.new/1
  def b2_new(%Account.Name{} = name), do: Blind.Draft2.draft(Event.Opened, Event.Renamed.Payload.new(name))

  # B3 — событие без нагрузки с нагрузкой
  def b3_frozen_with_payload(%Account.Name{} = name),
    do: Blind.Draft2.draft(Event.Frozen, Event.Opened.Payload.new(name))

  # корректно
  def ok(%Account.Name{} = name), do: Blind.Draft2.draft(Event.Opened, Event.Opened.Payload.new(name))
end
