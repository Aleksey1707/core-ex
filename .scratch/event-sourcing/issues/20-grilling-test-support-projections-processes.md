# Тестовая поддержка проекций и процессов

Type: grilling
Status: resolved
Blocked by: 10, 14, 15, 17, 18
Map: [Event-sourced агрегат в :core](../map.md)

## Question

Что библиотека даёт для тестов поверх `Core.Es.Aggregate.Test`, `Core.Es.EventCompatCase` и `run_once/1` и как
тестирует сама себя:

- полнота клауз `project/1` по `events:` и инвариант «`clear/0` оставляет read-модель пустой» — в
  `Core.Es.EventCompatCase`, отдельный case проекции или норма свода;
- тест потребителя с прогоном проекции (`enabled: false`, `async: false`): хватает ли `run_once/1` или нужен прогон до
  `:idle`; как тест проверяет `await`;
- тест цикла читателя в библиотеке — backoff, `wake`, `:outdated`, `trap_exit` — без `sleep`;
- тест процесса агрегата с sandbox: `start_supervised`, `async: false`, `allow` для процессов под `DynamicSupervisor`;
- синтетический агрегат в `test/support`: какие требования он фиксирует (event-sourced и state-stored, апкаст,
  снапшот) и снапшот в тестах `Repo.Pg`.

## Answer

- **`use Core.Es.ProjectionCase, projection:, fixtures:`** — в `lib/`, ExUnit только внутри `quote`, свой sandbox
  checkout на `Core.Config.dao()`, `async: false`: `TRUNCATE` в `clear/0` держит `ACCESS EXCLUSIVE` до конца sandbox.
  Фикстура модуля — `<тип из кодека события>/<текущий тег>.json` от корня `fixtures:` (по умолчанию
  `test/support/fixtures/events`), нет фикстуры — провал с модулем и путём; источники `upcasts:` не прогоняются. Опция
  в `EventCompatCase` и только норма свода отвергнуты.
  - **Полнота `project/1`** — фикстура каждого модуля `events:` в savepoint с откатом; пропуск клаузы — только
    `FunctionClauseError` самой `P.project/1`.
  - **`clear/0`** — разница `n_tup_ins + n_tup_upd + n_tup_del` в `pg_stat_xact_user_tables` вокруг `project/1` на всех
    фикстурах (savepoint на каждую, ошибка откатывается) → `clear/0` → у каждой найденной таблицы `count(*) = 0`; пустой
    набор — провал. Внутри открытой транзакции статистика не сбрасывается, разница точна. `tables:` у case и в
    `use Core.Es.Projection` отвергнуты.
- **Проверки case-модулей** (`EventCompatCase`, `ProjectionCase`) — функции `@doc false` → `:ok | {:error, detail}`,
  сгенерированный `test` делает `assert :ok = …`; библиотека вызывает их на сломанных модулях `test/support`. Вложенный
  `ExUnit.run` и mix-проект-фикстура отвергнуты.
- **Прогон проекции у потребителя** — `Core.Es.Projection.Test.run_until_idle(projection | [projection], opts \\ [])` →
  `:ok | {:error, :locked | :outdated | Error.t()}`: `run_once` до `:idle` без предела итераций;
  `run_once(projection, opts \\ [])` с `batch_size:` (по умолчанию 100); тест — `async: false`. Логику `project/1`
  SHOULD проверять записью через репозиторий → `run_until_idle` → ReadRepo; прямой `P.project/1` MAY в `async: true` на
  событиях из `Agg.execute/2` или `events` state-stored агрегата; хелпера сборки событий нет.
- **`await` в тесте** — у `Core.Es.Projection.Supervisor` опция `await: :poll | :inline`, по умолчанию `:poll`;
  `:inline` при `enabled: true` — `ArgumentError`. Любой старт супервизора ставит отметку в `:persistent_term` (список
  проекций и опции): `await` без отметки — `raise` «дерево проекций не запущено», проекция не из `projections:` —
  `raise`. При `:inline` `await` прогоняет проекцию до `:idle` в вызывающем процессе с `batch_size` из отметки и сверяет
  чекпоинт; любой другой исход — `raise` с исходом и именем проекции. Подмена `await` через DI и распознавание sandbox
  отвергнуты.
- **Процесс агрегата** — тест `async: false`, соединение — shared mode `Core.DataCase`, без `allow` и `$callers`.
  Повтор после конфликта — `Account.RacyRepo{,.Pg}` в `test/support`: перед первыми K `append` дописывает конкурирующее
  событие через `Core.Es.Store.append`; `Account.RacyProcess` с `repo: Account.RacyRepo`. Ключ в `config/test.exs` и хук
  `before_append:` отвергнуты.
- **Цикл читателя** — решение о следующем тике — чистая функция `@doc false`, тест таблицей исходов без процесса.
  Процесс — `start_supervised` с интервалами 60 000 мс, тики `send(pid, :tick)` и `wake` через `Registry.dispatch`,
  факт цикла — telemetry цикла, `refute_receive` — только «`wake` цикл не запустил»; `:outdated` — вставленная строка
  чекпоинта с версией выше; `trap_exit` — блокирующий `project/1`, остановка посреди пачки. Проверка по реальному
  времени и инжекция таймера в `StartOpts` отвергнуты.
- **Гонки `Core.Es.Store` и видимость читателя** (страж `xid`, unique при конкурентной записи, событие более поздней
  транзакции при открытой более старой) — `ExUnit.Case, async: false`, участники в `Sandbox.unboxed_run` с настоящими
  commit, шаги — сообщениями без `sleep`, `TRUNCATE` в `on_exit`; без тега, входит в `make`.
- **Синтетический агрегат** — event-sourced `Core.EsFixture.Account` (ошибки `decide`, `{:ok, []}`, два события на
  команду, событие без нагрузки, апкаст v1 → v2 → v3, удалённый тип) с `Repo.Pg`, `Repo.Pg.Snapshotted`
  (`snapshot: [every: 2]`) и `Process`; state-stored `Entity` / `Child` из `es_test.exs` с кодеком `Core.EventFixture`
  (`type:`), поток не с 1 и с разрывами; `Core.EsFixture.Projection` по обоим типам, объявляет не все теги;
  golden-фикстуры обоих, `EventCompatCase` и `ProjectionCase` на них; миграции — `priv/repo/migrations`.
- **Снапшот в тестах** — контрактный набор behaviour в `test/support` на `Repo.Pg` и `Repo.Pg.Snapshotted`; тесты
  снапшота — на втором: upsert после ≥ N, один upsert у `get_many`, промах маркера прямым `UPDATE`, битый `bytea` или
  лишний ключ struct → `warning` и полная свёртка.
- **Своды** — туман «Своды» карты: `19-testing.md` — case `Core.Es.ProjectionCase`, раздел проекций, shared mode для
  процессов, стартующих внутри вызова, тесты гонок; `17-otp-concurrency.md` — SHOULD: следующий тик нового
  периодического цикла — чистая функция с тестом без процесса.
- Пересмотр [«OTP-дерево асинхронных проекций»](18-grilling-projection-process-tree.md): отметка в `:persistent_term`
  ставится при любом старте супервизора. `CONTEXT.md` не меняется; ADR не заводится — тестовая поддержка откатывается
  дёшево.

## Comments

- 2026-09-13 — из тикета [«OTP-дерево асинхронных проекций»](18-grilling-projection-process-tree.md):
  `Core.Es.Projection.run_once(projection)` → `:processed | :idle | :locked | :outdated | {:error, Error.t()}` — одна
  пачка в вызывающем процессе, внутри `Transact.run` — `raise`; условие читателя открывает события своей транзакции,
  поэтому sandbox-тест их видит; тест с прогоном проекции — `async: false`: advisory lock и строка чекпоинта держатся до
  конца sandbox-транзакции; тесты потребителя — `enabled: false`.
- 2026-09-13 — из тикета [«Пересборка проекций»](17-grilling-projection-rebuild.md): `clear/0` обязателен у каждой
  проекции и вызывается при любом старте с начала.
- 2026-09-13 — факты: `Core.DataCase` — `start_owner!(shared: not async)`; `Sandbox.allow` и `$callers` в библиотеке нет,
  Poller / Cleaner видят соединение shared-режимом при `async: false`; тесты циклов — `start_supervised`, короткие
  интервалы, telemetry цикла → pid теста, `assert_receive` / `refute_receive`, `send(pid, :tick)`, инжекции таймера нет;
  `Core.EventFixture` — не агрегат (два события, кодек без `type:`), golden-фикстур событий нет, миграция одна — outbox;
  ExUnit в `lib/` нет; `DBConnection` ищет владельца по `[self() | $callers]`; `AfterCommit` в sandbox срабатывает после
  внешнего `Transact.run`; `pg_try_advisory_xact_lock` повторно берётся в своей транзакции, другому соединению — `false`,
  в sandbox держится до конца теста; `pg_stat_xact_user_tables` включает откаты и несброшенный хвост прошлых транзакций
  соединения, но внутри открытой транзакции не сбрасывается (проверено на `core_test`) — разница до / после в одной
  транзакции точна.
- 2026-09-13 — раунд 1:
  - полнота `project/1` — `use Core.Es.ProjectionCase, projection:, fixtures:` в `lib/`, ExUnit только внутри `quote`,
    свой sandbox checkout на `Core.Config.dao()`, `async: false` (`TRUNCATE` в `clear/0` держит `ACCESS EXCLUSIVE` до
    конца sandbox); `project/1` на golden-фикстуре каждого модуля `events:` в savepoint с откатом, пропуск клаузы — только
    `FunctionClauseError` самой `P.project/1`; опция в `EventCompatCase` и норма свода отвергнуты;
  - `clear/0` — там же: разница `n_tup_ins + n_tup_upd + n_tup_del` в `pg_stat_xact_user_tables` вокруг `project/1` на
    всех фикстурах (savepoint на каждую, ошибка откатывается) → `clear/0` → у каждой найденной таблицы `count(*) = 0`;
    пустой набор — провал; `tables:` у case и в `use Core.Es.Projection` отвергнуты (последнее пересматривает «Пересборку
    проекций»);
  - прогон в тесте потребителя — `Core.Es.Projection.Test.run_until_idle(projection | [projection])` →
    `:ok | {:error, :locked | :outdated | Error.t()}`: `run_once` до `:idle`, без предела итераций; цикл у потребителя и
    `until:` у `run_once` отвергнуты;
  - `await` в тесте — опция супервизора `await: :poll | :inline`, по умолчанию `:poll`: `:inline` → `:ignore`, `info`,
    отметка в `:persistent_term`, `await` прогоняет проекцию до `:idle` в вызывающем процессе и сверяет чекпоинт; с
    `enabled: true` — `ArgumentError`; подмена через DI и распознавание sandbox в `await` отвергнуты;
  - процесс агрегата в тесте — shared mode через `async: false` (`Core.DataCase`), без `allow` и `$callers`; норма
    `19-testing.md` «`allow` для порождённых процессов» уточняется для процессов, стартующих внутри вызова;
  - цикл читателя — решение о следующем тике чистой функцией `@doc false`, тест таблицей исходов без процесса; процесс —
    `start_supervised` с интервалами 60 000 мс, тики `send(pid, :tick)` и `wake` через `Registry.dispatch`, факт цикла —
    telemetry цикла (имя — «Наблюдаемость»), `refute_receive` — только «`wake` цикл не запустил»; `:outdated` —
    вставленная строка чекпоинта с версией выше; `trap_exit` — блокирующий `project/1`, остановка посреди пачки;
    короткие интервалы с проверкой по времени и инжекция таймера в `StartOpts` отвергнуты;
  - синтетический агрегат: event-sourced `Core.EsFixture.Account` с `Repo.Pg` и `Process` — ошибки `decide`, `{:ok, []}`,
    два события на команду, событие без нагрузки, апкаст v1 → v2 → v3, удалённый тип; state-stored — `Entity` / `Child`
    из `es_test.exs` в `test/support` с таблицами, кодек — `Core.EventFixture` с `type:`, поток не с 1 и с разрывами;
    `Core.EsFixture.Projection` по обоим типам, объявляет не все теги; golden-фикстуры обоих, `EventCompatCase` и
    `ProjectionCase` на них; миграции — `priv/repo/migrations`; минимальный счётчик и модули в тест-файлах отвергнуты;
  - снапшот в тестах — `Account.Repo.Pg` и `Account.Repo.Pg.Snapshotted` (`every: 2`): контрактный набор behaviour на
    обоих, тесты снапшота — на втором (upsert после ≥ N, один upsert у `get_many`, промах маркера прямым `UPDATE`, битый
    `bytea` / лишний ключ struct → `warning` и полная свёртка); один модуль с `every: 1` отвергнут.
- 2026-09-13 — раунд 2:
  - негативные проверки собственных case — логика каждой проверки в функции `@doc false` модуля case →
    `:ok | {:error, detail}`, сгенерированный `test` делает `assert :ok = …`; библиотека вызывает их на сломанных модулях
    `test/support` (проекция без клаузы, `clear/0` с забытой таблицей, `evolve` без клаузы, тег без фикстуры); у
    потребителя — только `use`; вложенный `ExUnit.run`, mix-проект-фикстура и только позитивные тесты отвергнуты;
  - гонки `Core.Es.Store` и видимость читателя (страж `xid`, unique при конкурентной записи, событие более поздней
    транзакции при открытой более старой) — `ExUnit.Case, async: false`, участники в `Sandbox.unboxed_run` с настоящими
    commit, шаги — сообщениями без `sleep`, очистка `TRUNCATE` в `on_exit`, без тега, в `make`; тег, исключённый по
    умолчанию, и отказ от тестов отвергнуты;
  - повтор процесса после конфликта — `Account.RacyRepo` / `Account.RacyRepo.Pg` в `test/support`: делегирует в
    `Account.Repo.Pg` и перед первыми K `append` дописывает конкурирующее событие через `Core.Es.Store.append`;
    `Account.RacyProcess` с `repo: Account.RacyRepo`; ключ в `config/test.exs` и опция-хук `before_append:` отвергнуты;
  - логика `project/1` у потребителя — SHOULD: запись через репозиторий → `run_until_idle` → ReadRepo, `async: false`;
    MAY: прямой `P.project/1` в `async: true` на событиях из `Agg.execute/2` или `events` state-stored агрегата; хелпера
    сборки событий нет;
  - `run_once(projection, opts \\ [])` и `run_until_idle(projections, opts \\ [])` с `batch_size:` (по умолчанию 100);
    `await: :inline` берёт `batch_size` супервизора из отметки;
  - отметку в `:persistent_term` ставит любой старт `Core.Es.Projection.Supervisor` (список проекций и опции); `await` без
    отметки — `raise` «дерево проекций не запущено», проекция не из `projections:` — `raise`; пересматривает «отметки
    нет» из «OTP-дерево асинхронных проекций»; опрос до `:projection_timeout` без отметки отвергнут;
  - `ProjectionCase`: `fixtures:` — корень, по умолчанию `test/support/fixtures/events`, файл —
    `<тип из кодека события>/<текущий тег>.json`, нет фикстуры — провал с модулем и путём; фикстуры источников `upcasts:`
    не прогоняются;
  - SHOULD в `17-otp-concurrency.md`: решение о следующем тике нового периодического цикла — чистая функция с тестом без
    процесса; Poller / Cleaner / подписчик не переделываются, в `DEBT.md` не попадают.
- 2026-09-13 — из тикета [«Наблюдаемость event-sourced агрегата и проекций»](19-grilling-observability.md): цикл
  читателя шлёт `[:es, :projection, :cycle]` с `result`, `events`, `attempt` на каждый исход, включая `:idle` /
  `:locked`, — опора теста цикла без `sleep`; процесс агрегата — `[:es, :aggregate, :process, :execute | :start |
  :stop]`; span'ы `Core.Otel.Es` (`execute`, `project`, `await`) проверяются через `Core.OtelFixture.attach/0` с
  `async: false`; хелперы `watch_list` при `enabled: false` элемент не включают.
- 2026-09-13 — раунд 3:
  - `await: :inline` — любой исход прогона, кроме `:idle` (`:locked`, `:outdated`, `{:error, Error.t()}`), — `raise` с
    исходом и именем проекции; `{:error, _}` как есть и отображение на `:projection_timeout` отвергнуты;
  - ответ подтверждён пользователем.
