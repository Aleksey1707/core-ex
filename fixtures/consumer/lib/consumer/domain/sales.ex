defmodule Consumer.Domain.Sales do
  @moduledoc """
  Продажи фикстуры: счета, заказы и выдача ролей; держит храповик вывода типов (ADR-0014).

  - Агрегаты (`Common`): `Account` (event-sourced, кодек с `upcasts:`, модуль ключа `NameKey`,
    процесс), `Order`, `Ping` (события без нагрузки), `Grants` (два события делят модуль нагрузки),
    `NeverFails` и `AlwaysFails` (`decide` никогда не ошибается / только ошибается); события `Parcel`
    без агрегата.
  - Значения без владельца (`Common`): `UserID`, идентификаторы из ключа `DeliveryID` и
    `InspectionID`.
  - Срезы: `Client` — usecases по агрегатам и ожидание read-модели.
  - Read-модели: активность `Activity` в `Common` — проекция на события `Account` и `Order`.
  - Компоненты: нет.
  - Другие контексты: нет.
  """
end
