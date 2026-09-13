# Event-sourced агрегат в :core

Type: map

## Destination

Приняты все решения, нужные `/to-spec`: карта сводится в спеку `.scratch/event-sourcing/spec.md` —
event-sourced агрегат в `:core` рядом со state-stored: восстановление состояния из событий с проверкой
ожидаемой версии, доставка событий в брокер через outbox, асинхронные проекции и их пересборка, снапшоты,
эволюция событий; путь usecase → repo и процесс агрегата.

## Notes

- **Термины** — `CONTEXT.md` («State-stored агрегат», «Event-sourced агрегат», «Процесс агрегата»,
  «Хранилище событий», «Поток событий», «Проекция», «Чекпоинт», «Снапшот», «Апкаст»). Новые фиксировать там же
  по мере разрешения.
- **Сосуществование.** Оба вида агрегатов остаются навсегда, выбор — на уровне агрегата. Общие части
  (`Es.Event`, кодек, outbox) выносить можно; контракт state-stored меняется только с записью в
  `CHANGELOG.md`.
- **Путь команды** — usecase → repo внутри `Transact.run`, как у state-stored; router нет. Второй путь —
  процесс агрегата: процесс на id держит состояние в памяти и исполняет команды по одной, вызывается
  напрямую, внутри — те же decide / evolve и репозиторий, стартует по первому обращению, завершается по
  idle timeout. Зачем: не перечитывать поток на каждую команду и выстроить конкурентные команды в
  очередь вместо `:version_mismatch`.
- **Контракт агрегата** — decider (`decide/2` / `evolve/2`, `use Core.Es.Aggregate`); решение —
  [Контракт event-sourced агрегата](issues/05-prototype-aggregate-contract.md).
- **Запись событий** — в транзакции `DAO`, вместе с outbox и Oban-джобами usecase; доставка в брокер —
  outbox, как у state-stored.
- **Формат хранения** (wire-тег, payload) задаёт кодек `:core`.
- **Проекции** — только асинхронные, по подписке.
- **Пилотного агрегата нет.** Требования задаёт синтетический агрегат в `test/support`; решения,
  зависящие от нагрузки (снапшоты, асинхронные проекции), помечать «не проверено на нагрузке».
- **Хранилище событий** — только PostgreSQL. Главный инвариант: библиотека не знает потребителя
  (`docs/rules/10-architecture.md`).
- **Skills.** Grilling-тикет — `grilling` + `domain-modeling`. Своды — по теме тикета: `architecture`,
  `domain`, `repos`, `events-outbox`, `errors`, `otp-concurrency`, `testing`, `observability`.
- **ADR** (`docs/adr/`) — только если решение трудно откатить, оно неочевидно без контекста и было
  реальным компромиссом.
- **Research** — первичные источники Commanded + EventStore, Marten, Emmett, Message DB. Результат —
  `.scratch/event-sourcing/research/<тема>.md`, без веток и коммитов.
- **Prototype** — `.scratch/event-sourcing/prototype/<name>/`, без веток и коммитов (коммит гоняет весь
  `make` через pre-commit); ссылка из тикета.
- **Отправная точка** (факты на 2026-09-13):
  - таблица событий — своя у каждого агрегата (`Core.Es.Event.Repo.Pg.Schema`, `table:`), миграцию
    пишет потребитель; unique `(aggregate_id, aggregate_version)` — единственная защита от lost update;
  - глобальной позиции нет; `at` — `:utc_datetime` (секунды);
  - версию события поднимает домен, репозиторий только проверяет (ADR-0001);
  - свёртки событий в агрегат, проекций, чекпоинтов, снапшотов, апкастеров нет; `:from_version` /
    `:to_version` в `list_by_aggregate` реализованы, но не вызываются;
  - RabbitMQ Stream — только транспорт outbox; `Mq.ReaderReliable` хранит offset подписчика.

## Decisions so far

<!-- одна строка на закрытый тикет: [название](issues/NN-slug.md): суть ответа -->

- [Готовые решения: схема event store на PostgreSQL и глобальный порядок](issues/01-research-event-store-schema.md):
  все четыре хранят события в общей таблице; пропуск по глобальной позиции закрывают строкой-счётчиком
  `$all` под row lock (EventStore), advisory lock на категорию (Message DB), `xid8 < pg_snapshot_xmin`
  (Emmett) или high-water mark на читателе (Marten) — ценой сериализации записи или сложности чтения.
- [Готовые решения: проекции, подписки и чекпоинты](issues/02-research-projections.md): асинхронные
  проекции везде читают ту же PostgreSQL по глобальной позиции, без брокера; чекпоинт — в одной TX с
  read-моделью, повтор отсекает условный UPDATE (CEP, Marten, Emmett); inline-проекции — Marten и Emmett;
  пересборка — очистка и прогон заново, blue/green (`ProjectionVersion`) — только Marten.
- [Готовые решения: эволюция событий и апкастинг](issues/03-research-upcasting.md): историю никто не
  переписывает, апкаст на чтении (Commanded — struct, Marten — при десериализации, Emmett — `upcast`);
  версия схемы — через тип или содержимое, по `aggregate_version` — нигде; снапшоты не апкастятся, а
  отбрасываются по версии снапшота.
- [Готовые решения: контракт агрегата и снапшоты](issues/04-research-aggregate-snapshots.md): версию сам
  агрегат нигде не поднимает (её ведёт процесс или event store); чистый decider — только Emmett;
  снапшоты у Commanded (раз в N событий, вне транзакции, ручной `snapshot_version`), Marten (inline в TX
  или async, rebuild при смене формы), Eventide (при чтении); у Emmett нет; given/when/then без БД — Emmett.
- [Готовые ES-библиотеки на Elixir и их совместимость с принципами core](issues/11-research-es-libraries.md):
  Commanded исполняет команды только через `Commanded.Application`, router и процесс агрегата, append —
  вне транзакции usecase; EventStore встаёт в `Transact.run` через `conn:` из Ecto, но держит свои процессы
  и пул, сам ведёт `stream_version`, без telemetry; Ariadne Flow — в транзакции repo, но DCB без версии
  агрегата; Maestro — GenServer на агрегат.
- [Проверить EventStore на Elixir 1.20 и append в `Transact.run`](issues/13-task-eventstore-spike.md):
  `eventstore` 1.4.8 работает на Elixir 1.20.3 / OTP 29, append через `conn:` коммитится и откатывается
  вместе с транзакцией Ecto; но до commit любой другой append в store ждёт (`$all`), конфликт версии
  переводит транзакцию в aborted, от 1000 событий рвёт соединение Ecto, `conn: nil` вне транзакции молча
  пишет мимо неё, без запущенного store — `RuntimeError`.
- [Своя реализация или готовая библиотека](issues/12-grilling-build-or-adopt.md): своя реализация на
  `Repo.Pg` / `DAO` без новых зависимостей ([ADR-0007](../../docs/adr/0007-event-sourcing-own-implementation.md));
  EventStore отвергнут за `$all` на всю транзакцию usecase, приватный ключ ecto_sql и aborted-транзакцию при
  гонке; глобальный порядок — без ожидания чужого commit, конфликт версии — без aborted-транзакции.
- [Контракт event-sourced агрегата](issues/05-prototype-aggregate-contract.md): decider — автор пишет команды
  `<Aggregate>.Cmd.<Name>` (`use Core.Es.Cmd`), `decide/2` → `{Event, payload}` и `evolve/2`; `id`, версию, `by` /
  `at` событиям и `id` / `version` состоянию ставит библиотека; `use Core.Es.Aggregate` даёт `fold/2`, `fold/3`,
  `execute/2`.
- [Модель потока и таблица событий](issues/06-grilling-stream-model.md): одна таблица `es_events` для обоих видов
  агрегатов, DDL — библиотека; поток — тип агрегата (`type:` у кодека) и id, unique с версией вместо таблицы потоков;
  позиция `(xid, номер)` с чтением ниже `pg_snapshot_xmin` и отказом append при более позднем `xid` в потоке
  ([ADR-0008](../../docs/adr/0008-shared-event-table-xid8-position.md)); `at` — секунды, перенос истории пишет потребитель.
- [Контракт репозитория event-sourced агрегата](issues/07-grilling-repo-contract.md): `get` / `get_many` →
  `Agg.execute/2` → `append(events)` → `:ok` в одном `Transact.run`; `get` без `:not_found` (пустой поток — `version: nil`);
  конфликт ловят версии событий — unique, `xid`, непрерывность потока; `Repo.Sc` и `delete` нет; хранилище —
  модуль `Core.Es.Store`, `outbox:` обязателен.
- [Проекции: источник событий, чекпоинт, порядок](issues/08-grilling-projections.md): читатель `es_events` по
  глобальной позиции, а не брокер; пачка — транзакция `DAO` под `pg_try_advisory_xact_lock` с CAS чекпоинта в
  `es_checkpoints`; ошибка — retry без пропуска; `use Core.Es.Projection, name:, events:` и `project/1`; `await` — до
  последнего события потока ([ADR-0009](../../docs/adr/0009-projections-read-event-store.md)).
- [Эволюция событий: где апкастится история](issues/09-grilling-event-evolution.md): версия схемы — тег; несовместимое
  изменение — новый тег и апкаст при чтении в кодеке агрегата (`upcasts:` + `upcast/2`, тег и нагрузка, одно в одно)
  для всех читателей фасада; история не переписывается, Prim в событии не ужесточается; тег, неизвестный кодеку,
  проекция не пропускает ([ADR-0010](../../docs/adr/0010-event-evolution-tag-upcast.md)).
- [Снапшоты: хранение, политика, инвалидация](issues/10-grilling-snapshots.md): одноразовый кэш свёртки, включается
  `snapshot: [every:, version:]` у `Core.Es.Aggregate.Repo.Pg`; строка на поток в `es_snapshots`, `term_to_binary`,
  маркер — md5 модулей агрегата и событий + `version:`; пишет `get` после commit, свернув ≥ N событий; любой отказ
  снапшота — полная свёртка.
- [Контракт state-stored агрегата поверх общей таблицы событий](issues/16-grilling-state-stored-shared-event-table.md):
  триплет `Es.Event.Repo{,.Pg,.Pg.Schema}` и его чтения уходят, запись — `Core.Es.Store.append`; `Core.Repo.Pg.Es` →
  `Core.Repo.Pg.StateStored` с обязательной `event_codec:`; `type:` у кодека событий обязателен; непрерывность потока —
  только у event-sourced; `:version_mismatch` — detail `Core.Es.Store`; перенос — с остановкой записи, миграции DDL и
  копии.
- [Тестовая поддержка event-sourced агрегата: given / when / then и полнота `evolve`](issues/15-grilling-aggregate-test-support.md):
  `Core.Es.Aggregate.Test.given/3` из результатов `decide` с обязательными `by:` / `at:`, then — короткая форма
  `decide/2`; `use Core.Es.EventCompatCase, aggregate: | event_codec:` в `lib/` — инварианты golden-фикстур и полнота
  `evolve` вызовом на фикстурах; интроспекция кодека `__es_mods__/0`, `__es_upcasts__/0`.
- [Процесс агрегата](issues/14-grilling-aggregate-process.md): кэш и очередь команд на ноду (`Registry`),
  корректность держат проверки `append`; `use Core.Es.Aggregate.Process, repo:` →
  `execute(id, version, cmd, context, fun \\ nil, opts)`; команда — одна транзакция: хвост через `Agg.Repo.refresh/4` →
  `Agg.execute/2` → `append` → колбэк, конфликт — повтор до `retries:`; `enabled: false` — те же шаги в вызывающем
  процессе.
- [Пересборка проекций](issues/17-grilling-projection-rebuild.md): на месте — подъём `version:` проекции: строки
  чекпоинта нет или версия ниже — пачка без событий: обязательный `clear/0` → чекпоинт в начало с целью, старая нода
  пропускает тик; `await` при пересборке — `:projection_rebuilding`; без неполной read-модели — новая проекция в три
  выкладки; таблицу read-модели пишет одна проекция ([ADR-0011](../../docs/adr/0011-projection-rebuild-by-version.md)).
- [OTP-дерево асинхронных проекций](issues/18-grilling-projection-process-tree.md): библиотечный
  `Core.Es.Projection.Supervisor` со списком `projections:` — `Registry` по типу агрегата для `wake` из `append` и
  читатель на проекцию под именем её модуля; опции общие через `StartOpts`, `enabled:` обязательна; исходы цикла
  `:processed` / `:idle` / `:locked` / `:retry` / `:outdated`, retry без рестарта; `trap_exit`, `shutdown` 30 с;
  `run_once/1` в вызывающем процессе видит события своей транзакции (sandbox).
- [Тестовая поддержка проекций и процессов](issues/20-grilling-test-support-projections-processes.md):
  `use Core.Es.ProjectionCase` — полнота `project/1` на golden-фикстурах и `clear/0` по разнице
  `pg_stat_xact_user_tables`; `Core.Es.Projection.Test.run_until_idle/2`; `await: :inline` у супервизора, отметка в
  `:persistent_term` при любом старте; процесс агрегата — shared sandbox, конфликт — `RacyRepo`; тик читателя — чистая
  функция; гонки `Core.Es.Store` — `unboxed_run`; синтетический `Core.EsFixture.Account` со снапшотом и проекцией.
- [Наблюдаемость event-sourced агрегата и проекций](issues/19-grilling-observability.md): трейс в `es_events` не
  хранится; словарь `Core.Otel.Es` — span'ы команды процесса, пачки проекции с работой и `await`, у восстановления
  span'а нет; telemetry `[:es, …]` восстановления, снапшота, цикла, `await` и процесса; отставание проекции и gauge
  `rebuilding` / `outdated` / `checkpoint.orphan` — polling одного `Core.Es.PromEx`; `watch_list` без элемента при
  `enabled: false`; четыре рекомендованных алерта `EsProjection*`.
- [История потока на read-пути](issues/21-grilling-stream-history-read-path.md): `Core.Es.Store.page_stream/5` →
  `Pagination.Result` из `Es.Event` через фасад с апкастом, `limit` / `offset` + `count` по версии; права и существование
  — `ReadRepo.get` в usecase до чтения, пустой поток — пустая страница; ошибка `load` — на всю страницу; несколько
  агрегатов — проекция потребителя; в тестах — `Core.Es.Store.Test.events!/2`.
- [Раскладка сводов `docs/rules` под event sourcing](issues/22-grilling-rules-layout.md): правки свода — в срезах спеки
  вместе с кодом; нормы event-sourced агрегата — по слоям (`11` / `13` / `14` / `17` / `19` / `20` / `21`), процесс агрегата —
  в write-пути `13-repos.md`; проекции с алертами `EsProjection*` — новый `22-projections.md`; CQS — «изменяющая /
  читающая», «Команда» — у агрегата любого вида; `Core.Es.Store.append` вне write-репозиториев — MUST NOT.

## Not yet specified

## Out of scope

- **Синхронные проекции** — все read-модели асинхронные; решено при разборе прототипа контракта
  агрегата.
- **Таймеры, дедлайны и реакция процесса агрегата на чужие события** — это поведение process manager.
- **Process manager / саги** — вне пункта назначения: он ограничен агрегатом, его хранением и
  проекциями.
- **Перевод state-stored агрегата в event-sourced** — оба вида сосуществуют, миграция данных между
  ними не требуется.
- **Хранилища кроме PostgreSQL** — библиотека строится на `Repo.Pg`.
- **Router и middleware команд** — команда идёт через usecase или прямо в процесс агрегата; маршрутизация
  команд по агрегатам не нужна ни тому, ни другому.
- **Физическое удаление и архивация потоков** — удаление event-sourced агрегата — доменное событие; retention и
  персональные данные — отдельное усилие. Решено в
  [«Контракт репозитория event-sourced агрегата»](issues/07-grilling-repo-contract.md).
