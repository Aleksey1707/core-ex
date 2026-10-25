# 10: Перевод OTP на схему — подписчики, проекции, процесс агрегата

**What to build:** подписчики брокера, дерево проекций, процесс агрегата и health-plug проверяют
опции схемой; вызов `Agg.Process.execute` без опций не платит за проверку.

Спека — «Объём перевода», волна 2.

**Blocked by:** 07

**Status:** resolved

- [x] `MqSubscriberReliable`, его `Step` и `Supervisor` (включая `watch_list`, `stream_readers`,
      `kafka_readers`): схема там, где опции разбираются; вызовы `StartOpts` убраны.
- [x] `Es.Projection.Supervisor` (`start_link`, `watch_list`) переведён.
- [x] `Es.Aggregate.Process`: `init` / `watch_list` и `execute` (`timeout:`) — схема; ручные
      `Keyword.validate!` и клауза `raise ArgumentError` на тип убраны.
- [x] `Web.HealthPlug.init` переведён; решение (схема над обратным вызовом `Plug`) записано в
      `## Comments`.
- [x] Опции в `@moduledoc` из схемы у модулей с `@doc false` на месте разбора.
- [x] Тесты старта с неверными опциями и тесты процесса агрегата зелёные (тексты про `:timeout`
      обновлены).
- [x] CHANGELOG: функции, где неизвестный ключ раньше проходил, добавлены в список «Ломающих».
- [x] `make` зелёный.

## Comments

- `MqSubscriberReliable`: схема над `init/1` (`@init_opts_schema` = свои ключи ++
  `Step.schema/0`), описание — в `@moduledoc`, «Опции старта». `child_spec/1` / `start_link/1` без
  схемы: `:id` — `Keyword.get(opts, :name) || __MODULE__`, `:shutdown` — `Keyword.get(opts,
  :shutdown, 30_000)`; неверное имя отклоняет `GenServer.start_link/3`, неверный `shutdown:` —
  проверка спецификации ребёнка супервизором (как у `Outbox.Cleaner`, тикет 07).
- `Step`: ключи шага (`topic`, `filter`, `from_message`, `on_message`, `context_factory`) — схема
  `Step.schema/0` (`@doc false`); `Step.new!/2` сохранил сигнатуру (его зовут `Outbox.Test` и
  `test/core/es/operation_test.exs`) и проверяет только свои ключи через `Core.Options.__validate__!/3`
  с меткой вызывающего. Опции шага — подмножество опций вызывающего, поэтому `@opts_schema` над
  `new!/2` невозможна: неизвестными оказались бы чужие ключи. Из `init/1` подписчика проверка шага
  уже не падает (ключи проверены схемой `init/1`), повтор стоит микросекунды на старте.
  Умолчание `filter:` — внешний захват `&Step.accept_all/1` (публичный `@doc false`).
- Умолчания, зависящие от другой опции (`poll_interval_ms:` от `reader_module:`, `dlq_topic:` от
  `topic:`, `state_max_age:` от ПДн агрегата), в схеме без `default:` и читаются `Keyword.get/2`.
- Межключевые проверки остались в теле `raise ArgumentError`. У функций с одним местом разбора
  префикс — как у схемы (`Core.PubSub.MqSubscriberReliable.init/1:`, `Core.Web.HealthPlug.init/1:`);
  у разбора, общего для двух функций (`Es.Projection.Supervisor` — `await: :inline` и дубль `name:`,
  `Es.Aggregate.Process` — `state_max_age: :infinity` у агрегата с ПДн, повторы в дереве
  подписчиков через `StartOpts.unique!/4` / `process!/3`), — прежняя метка модуля.
- Деревья (`MqSubscriberReliable.Supervisor`, `Es.Projection.Supervisor`): схема у каждой публичной
  функции, которая разбирает опции (`start_link/1`, `watch_list/1`, у подписчиков ещё
  `stream_readers/1`, `kafka_readers/1`) — общий атрибут `@tree_opts_schema`; разбор после схемы —
  приватный `options!/1`. Раздел «Опции» получает `@doc` `start_link/1`, `@moduledoc` ссылается
  на него, а не повторяет. Элемент `topics:` — `{:list, {:keyword_list, …}}`: `reader:` —
  `{:tuple, [:atom, :keyword_list]}` + `StartOpts.process!/3`, `subscriber:` — custom
  `Supervisor.subscriber/1` (keyword, без ключей дерева, `name:` атомом, `topic:` непустой строкой:
  прочие ключи проверяет подписчик). `component:` — custom `Supervisor.component/1`, `projections:` —
  `{:list, {:custom, Projection.Supervisor, :projection, []}}`.
- Доменные custom-валидаторы одного модуля (`component/1`, `subscriber/1`, `projection/1`,
  `HealthPlug.repos/1` / `path/1`) — публичные `@doc false` в самом модуле, блок «проверка опций»:
  в `StartOpts` им не место, они знают про чужой модуль.
- `StartOpts`: добавлен `term/1` (любое значение, кроме `nil`) — handle `reader:` подписчика; без
  него `:any` пропускал бы `nil`, который прежний `term!/3` отклонял. `binary/1` — общий с тикетом 09.
- `Es.Aggregate.Process`: схема над `execute/4` (`timeout:`), `start_link/3` и `watch_list/3`
  (`@start_opts_schema`); `child_spec/3` — насквозь. Горячий путь: у схемы `execute/4` нет
  обязательных ключей, вызов с `[]` NimbleOptions не проходит. Префикс отказа называет
  `Core.Es.Aggregate.Process.execute/4`, а не сгенерированный `Agg.Process.execute/6`: схема внутри
  `quote` — MUST NOT. Опции команды и старта — в `@moduledoc` из схем. `retries:` в
  `Es.Transact.run` не тронут.
- `Web.HealthPlug.init/1` — схема над обратным вызовом `Plug`. Спека относит `Plug.init/call` к «вне
  объёма по природе», но имеет в виду обратный вызов, который опции не разбирает: `HealthPlug.init/1`
  разбирает свои ключи сам и раньше проверял их `StartOpts`, вызывается один раз — при сборке
  эндпоинта Phoenix или старте роутера, и проверка не стоит ничего на запрос. Схема — единственное
  место разбора, `call/2` получает готовую map. `health_path:` / `ready_path:` сравниваются после
  разбиения на сегменты, как и раньше.
- NimbleOptions отклоняет повтор ключа (`unknown options [:k]`): тестовый хелпер
  `signal_test.exs` собирал опции `++` — переведён на `Keyword.merge/2`; в CHANGELOG — отдельной
  строкой.
- После слияния тикета 09: разбор подписчика `Outbox.Test.parse_subscriber!/1` переведён так же —
  схема NimbleOptions из `Step.schema/0` (`topic:` обязателен) + `name:` (`StartOpts.atom/1`),
  `max_attempts:`, `subscribe_data:` и сетевые ключи подписчика (`:any`, игнорируются); проверка —
  `Core.Options.__validate__!/3` с меткой `"Outbox.Test: подписчик"`, затем `Step.new!/2`. Из
  `StartOpts` там остался только `unique!/4`.
- Исправления по ревью ветки:
  - `Es.Projection.Reader` и `Es.Projection.Listener` получили схему над `init/1` по шаблону
    `Outbox.Cleaner`: их `init/1` читает свои ключи, как у `Outbox.Poller` / `Cleaner`, детей своего
    дерева. Умолчаний у схем нет (`required: true`): значения собирает
    `Es.Projection.Supervisor`, второго источника умолчаний не появилось. Повторная проверка уже
    проверенных деревом опций стоит микросекунды на старт читателя.
  - Межключевые отказы деревьев (`Outbox.Supervisor`, `Es.Projection.Supervisor`,
    `MqSubscriberReliable.Supervisor`, `Es.Aggregate.Process`, `Outbox.Poller`, `Outbox.Test`) — с
    префиксом функции, как у схемы: разбор, общий для нескольких функций, получает метку
    вызывающего аргументом. Метка builder'а `Es.Aggregate.Process` осталась у опций `use` и у отказов
    `execute` вне опций (вызов внутри транзакции, процесс без отметки старта).
  - `Step.new!/1` без своей схемы: принимает проверенные опции вызывающего целиком и берёт из них
    свои ключи. Подписчики `Outbox.Test` проверяет публичная `Core.Options.validate!/3` по схеме
    `subscribers: {:list, {:keyword_list, …}}`; `__validate__!/3` переименована в неё.
