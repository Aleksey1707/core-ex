# 04: Сигнал чекпоинта между нодами: `NOTIFY` и слушатель

**What to build:** `Core.Es.Projection.await/4` отвечает быстро и тогда, когда пачку прогнала другая нода, без
кластера Erlang. Пачка сообщает о сдвиге чекпоинта через `NOTIFY` в своей транзакции, слушатель каждой ноды переводит
уведомление в сигнал чекпоинта для локальных ожидающих. Приложение на одной ноде или за pgbouncer в transaction mode
отключает `NOTIFY` опцией `notifications: false` и не платит соединением и блокировкой коммита (ADR-0013).

**Blocked by:** [03: Сигнал чекпоинта внутри ноды](03-checkpoint-signal-in-node.md)

**Status:** resolved

**Spec:** [Сигнал чекпоинта: ожидание проекции без задержки опроса](../spec.md) — «Пачка», «Протокол канала»,
«Слушатель», «Дерево»

- [x] Опция дерева `notifications:` — `true` (по умолчанию), `false` или keyword опций соединения Postgrex поверх
      `repo.config()`; иное — `ArgumentError` при любом `enabled:`; значение в отметке, в опции читателей не
      передаётся.
- [x] Пачка в своей транзакции после сдвига чекпоинта или старта с начала шлёт `pg_notify` в канал
      `core_es_checkpoint` с `name:` проекции; не шлёт, только если отметка на ноде есть и в ней
      `notifications: false`. `append` `NOTIFY` не получает.
- [x] `Core.Es.Projection.Listener` — процесс дерева на каждый различный `repo:` проекций: `Postgrex.Notifications`
      с `sync_connect: false` и `auto_reconnect: true`, подписка на канал после `init/1`, уведомление → сигнал
      чекпоинта через Registry по имени из payload. При `false` слушатели не стартуют.
- [x] Порядок потомков дерева: Registry → читатели → слушатели.
- [x] Тесты в модуле с настоящими коммитами: пачку прогоняет `run_once/2` в другом соединении, шаги ожидания 60 000 мс
      → `:ok` через `NOTIFY` и слушателя; `notifications: false` → `:ok` сигналом внутри ноды.
- [x] Тест канала: тест сам подписывается `Postgrex.Notifications.listen` на `core_es_checkpoint`; после `run_once/2`
      с настоящим коммитом при `notifications: false` уведомления нет, при `true` — уведомление с именем проекции.
- [x] `Core.Es.Projection.SupervisorTest`: недопустимые `notifications:` — `ArgumentError`; умолчание и значение в
      отметке; при `false` слушателей нет, при `true` — по одному на repo.
- [x] moduledoc `Core.Es.Projection.Supervisor` (опция, порядок потомков, слушатель), `Core.Es.Projection.Batch`,
      `Core.Es.Projection.Listener`; протокол канала — в moduledoc слушателя: смена — ломающее изменение.
- [x] `22-projections.md`: `notifications:` у опций дерева; одна нода — `false`; pgbouncer в transaction mode —
      keyword с прямым хостом; соединение на repo на ноду; в «Read-after-write» — симптом сломанного быстрого пути по
      `duration` `[:es, :projection, :await]` и ссылка на ADR-0013. `make rules-check`.
- [x] README: опция и env `ES_PROJECTIONS_NOTIFICATIONS` в примере `config/runtime.exs`.
- [x] `CHANGELOG.md`, «Не выпущено» / «Новое»: пункты «Дерево проекций» и «Read-after-write» дополнены — опция,
      сигнал между нодами, соединение на repo, pgbouncer.
- [x] `make` зелёный.

## Comments

- 2026-09-15 — реализация:
  - протокол канала и отправка — в `Core.Es.Projection.Listener`: `notify/1` (`@doc false`) зовёт пачка
    после `Checkpoint.start/3` и `Checkpoint.move/3`, условие по отметке — там же;
  - слушатели — звено `:listeners` (`one_for_one`, id `{Listener, repo}`) последним в `rest_for_one`:
    падение слушателя одного repo не рвёт подписку слушателей других; при `false` звена нет;
  - `repo.config()` зовётся в `handle_continue/2` слушателя, а не в `init/1` дерева; `sync_connect: false`
    и `auto_reconnect: true` ложатся поверх keyword из `notifications:` и не переопределяются;
  - тесты: готовность слушателя дерева — опрос `pg_stat_activity` (соединение открыто после старта дерева
    и выполнило `LISTEN`), как `poll_lock_wait` в `StoreRaceTest`: уведомление до `LISTEN` теряется.
    Отсутствие уведомления в канале доказано без таймаута — метка `pg_notify` после пачек приходит
    первой (порядок коммитов). Мутации «слушатель не рассылает сигнал» и «отправка игнорирует отметку»
    роняют свои тесты; 16 прогонов модуля подряд зелёные;
  - отметка дерева вынесена из `Supervisor.mark/0` в `Core.Es.Projection.Supervisor.Mark` (`put/1`, `find/0`):
    чтение отметки пачкой через супервизор давало цикл `Batch → Listener → Supervisor → Reader → Batch`,
    и `make xref` падал;
  - `DownRepo` в `SupervisorTest` без `config/0`: тест исключений читателя стартует дерево с
    `notifications: false`;
  - правлены также moduledoc `Core.Es.Projection` («Пачка», «Ожидание»: «пачку другой ноды ожидающий
    находит шагом» стало неверным) и `Core.Es.Projection.Registry`; «Область» `17-otp-concurrency.md` —
    `listener.ex`;
- 2026-09-15 — по ревью:
  - подписка слушателя — `timeout: :infinity`: при `sync_connect: false` вызов ждёт первую попытку
    подключения, её ограничивает `connect_timeout` Postgrex, и таймаут 5 000 мс ронял бы слушателя на
    недоступном хосте каждые 5 с; имя pid в `handle_continue/2` — `server`;
  - тест `notifications: false` с настоящими коммитами проверяет, что звена слушателей нет;
  - `22-projections.md`: у нормы о соединениях слушателей — пример лимита соединений; абзац о сломанном
    быстром пути в «Read-after-write» — норма разбора по `duration` с примером на метрике
    `Core.Es.PromEx`;
  - не правилось: отметка ставится после `Supervisor.start_link/3`, и пачка читателя в это окно при
    `notifications: false` отправила бы `NOTIFY` — первым циклом по таймеру `idle_min_ms` или по `wake`
    записи; перенос отметки до старта перезаписал бы отметку первого дерева при отказе второго. Устойчивое
    падение слушателя от конфигурации — repo без `config/0`, keyword, который отвергает
    `Postgrex.Notifications.start_link/1`, — исчерпывает рестарты и роняет дерево вместе с читателями:
    это ошибка конфигурации, разрывы соединения слушателя не роняют (`auto_reconnect`). Ключи keyword не
    сверяются со списком опций Postgrex, `trap_exit` у слушателя нет — сокет у связанного
    `Postgrex.Notifications`, он гибнет вместе со слушателем; `watch_list/1` не менялся по спеке.
