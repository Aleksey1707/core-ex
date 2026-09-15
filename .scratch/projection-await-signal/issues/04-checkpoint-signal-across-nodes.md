# 04: Сигнал чекпоинта между нодами: `NOTIFY` и слушатель

**What to build:** `Core.Es.Projection.await/4` отвечает быстро и тогда, когда пачку прогнала другая нода, без
кластера Erlang. Пачка сообщает о сдвиге чекпоинта через `NOTIFY` в своей транзакции, слушатель каждой ноды переводит
уведомление в сигнал чекпоинта для локальных ожидающих. Приложение на одной ноде или за pgbouncer в transaction mode
отключает `NOTIFY` опцией `notifications: false` и не платит соединением и блокировкой коммита (ADR-0013).

**Blocked by:** [03: Сигнал чекпоинта внутри ноды](03-checkpoint-signal-in-node.md)

**Status:** ready-for-agent

**Spec:** [Сигнал чекпоинта: ожидание проекции без задержки опроса](../spec.md) — «Пачка», «Протокол канала»,
«Слушатель», «Дерево»

- [ ] Опция дерева `notifications:` — `true` (по умолчанию), `false` или keyword опций соединения Postgrex поверх
      `repo.config()`; иное — `ArgumentError` при любом `enabled:`; значение в отметке, в опции читателей не
      передаётся.
- [ ] Пачка в своей транзакции после сдвига чекпоинта или старта с начала шлёт `pg_notify` в канал
      `core_es_checkpoint` с `name:` проекции; не шлёт, только если отметка на ноде есть и в ней
      `notifications: false`. `append` `NOTIFY` не получает.
- [ ] `Core.Es.Projection.Listener` — процесс дерева на каждый различный `repo:` проекций: `Postgrex.Notifications`
      с `sync_connect: false` и `auto_reconnect: true`, подписка на канал после `init/1`, уведомление → сигнал
      чекпоинта через Registry по имени из payload. При `false` слушатели не стартуют.
- [ ] Порядок потомков дерева: Registry → читатели → слушатели.
- [ ] Тесты в модуле с настоящими коммитами: пачку прогоняет `run_once/2` в другом соединении, шаги ожидания 60 000 мс
      → `:ok` через `NOTIFY` и слушателя; `notifications: false` → `:ok` сигналом внутри ноды.
- [ ] Тест канала: тест сам подписывается `Postgrex.Notifications.listen` на `core_es_checkpoint`; после `run_once/2`
      с настоящим коммитом при `notifications: false` уведомления нет, при `true` — уведомление с именем проекции.
- [ ] `Core.Es.Projection.SupervisorTest`: недопустимые `notifications:` — `ArgumentError`; умолчание и значение в
      отметке; при `false` слушателей нет, при `true` — по одному на repo.
- [ ] moduledoc `Core.Es.Projection.Supervisor` (опция, порядок потомков, слушатель), `Core.Es.Projection.Batch`,
      `Core.Es.Projection.Listener`; протокол канала — в moduledoc слушателя: смена — ломающее изменение.
- [ ] `22-projections.md`: `notifications:` у опций дерева; одна нода — `false`; pgbouncer в transaction mode —
      keyword с прямым хостом; соединение на repo на ноду; в «Read-after-write» — симптом сломанного быстрого пути по
      `duration` `[:es, :projection, :await]` и ссылка на ADR-0013. `make rules-check`.
- [ ] README: опция и env `ES_PROJECTIONS_NOTIFICATIONS` в примере `config/runtime.exs`.
- [ ] `CHANGELOG.md`, «Не выпущено» / «Новое»: пункты «Дерево проекций» и «Read-after-write» дополнены — опция,
      сигнал между нодами, соединение на repo, pgbouncer.
- [ ] `make` зелёный.
