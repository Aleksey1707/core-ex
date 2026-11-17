defmodule Consumer.Domain.Sales do
  @moduledoc """
  Продажи фикстуры: счета, заказы и выдача ролей; держит храповик вывода типов (ADR-0014).

  - Агрегаты: `Account` (event-sourced, состояние и команда `Cmd.Rename` — структуры по полям, кодек с
    `upcasts:`, модули ключа `NameKey` и из ПДн `HolderKey`, процесс), `Order` (enum `Status` отдельным
    файлом в guard `is_enum/2` самого агрегата), `Ping` (события без нагрузки),
    `Grants` (два события делят модуль нагрузки, нагрузки по полям с `union:` и с `set:` / `map:`,
    состояние и команда `Cmd.Assign` — структуры по полям с `set:` / `map:`), `Itinerary`
    (синтетические шаги маршрута: открытые `channel` / `status` / `attempts` рядом с вложенными
    ПДн-местами `recipient` / `content`; типы чтения и записи шага), `NeverFails` и
    `AlwaysFails` (`decide` никогда не ошибается / только ошибается); события `Parcel` без агрегата
    (владелец потока — struct `Parcel`).
  - Акторы: `Client` — usecases в каталоге каждого агрегата и read-модели.
  - Значения без владельца (`Values`): `UserID`, идентификаторы из ключа `DeliveryID` и `InspectionID`.
  - Read-модели: активность `Activity` по назначению — проекция на события `Account` и `Order`;
    представление `Account.View` с `jsonb:` по типу плагина по полям и по семейству.
  - Кодеки: dump-only плагин `Account.Card.Codec`, плагин по полям `Account.Profile.Codec` (поля `union:`, `set:`, `map:`), семейства
    вариантов `Account.Profile.Channel.Codec` (тегированная форма с дискриминатором) и
    `Account.Profile.Badge.Codec` (без обёртки, `variants:` выражением из реестра).
  - Компоненты: нет.
  - Другие контексты: нет.
  """

  use Boundary,
    deps: [Consumer.Codec, Consumer.Infra],
    exports: [
      Account.Client.Usecases,
      Activity.Client.Usecases,
      AlwaysFails.Client.Usecases,
      Grants.Client.Usecases,
      Itinerary.Client.Usecases,
      NeverFails.Client.Usecases,
      Order.Client.Usecases,
      Ping.Client.Usecases,
      Account.ID,
      Grants.ID,
      Itinerary.ID,
      Order.ID,
      Parcel.ID,
      Ping.ID,
      Values.DeliveryID,
      Values.InspectionID,
      Values.UserID,
      {Account.Event, []},
      {Grants.Event, []},
      {Itinerary.Event, []},
      {Order.Event, []},
      {Parcel.Event, []},
      {Ping.Event, []},
      Account.Outbox,
      Itinerary.Outbox,
      Order.Outbox,
      Itinerary.Step.Codec,
      Account.Card.Codec,
      Account.Profile.Codec,
      Account.Profile.Channel.Codec,
      Account.Profile.Badge.Codec,
      Account.View.Codec
    ]
end
