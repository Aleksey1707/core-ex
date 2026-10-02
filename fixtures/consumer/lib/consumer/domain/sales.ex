defmodule Consumer.Domain.Sales do
  @moduledoc """
  Продажи фикстуры: счета, заказы и выдача ролей; держит храповик вывода типов (ADR-0014).

  - Агрегаты: `Account` (event-sourced, кодек с `upcasts:`, модуль ключа `NameKey`, процесс), `Order`
    (enum `Status` отдельным файлом в guard `is_enum/2` самого агрегата), `Ping` (события без нагрузки),
    `Grants` (два события делят модуль нагрузки), `NeverFails` и `AlwaysFails` (`decide` никогда не
    ошибается / только ошибается); события `Parcel` без агрегата.
  - Акторы: `Client` — usecases в каталоге каждого агрегата и read-модели.
  - Значения без владельца (`Values`): `UserID`, идентификаторы из ключа `DeliveryID` и `InspectionID`.
  - Read-модели: активность `Activity` по назначению — проекция на события `Account` и `Order`.
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
      NeverFails.Client.Usecases,
      Order.Client.Usecases,
      Ping.Client.Usecases,
      Account.ID,
      Grants.ID,
      Order.ID,
      Parcel.ID,
      Ping.ID,
      Values.DeliveryID,
      Values.InspectionID,
      Values.UserID,
      {Account.Event, []},
      {Grants.Event, []},
      {Order.Event, []},
      {Parcel.Event, []},
      {Ping.Event, []},
      Account.Card.Codec
    ]
end
