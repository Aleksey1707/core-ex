# 26: Хранилище событий: `es_events` и `Core.Es.Store.append`

**What to build:** библиотека даёт одно хранилище событий на приложение: миграцию `Core.Es.Migration`, создающую
`es_events`, и `Core.Es.Store.append`, который пишет события пачкой в транзакции `DAO` и отвергает конкурентную запись
доменной `:version_mismatch`, не переводя транзакцию в aborted. Проверяется напрямую: записать события, прочитать их
`Core.Es.Store.Test.events!/2`, воспроизвести гонку двух настоящих транзакций.

**Blocked by:** [24: Обязательный `type:` у кодека событий](24-event-codec-mandatory-type.md)

**Status:** resolved

**Spec:** [Event-sourced агрегат в :core](../spec.md) — «Схема хранилища», «Хранилище событий»,
ADR-0008

- [x] `Core.Es.Migration` `up/0` / `down/0` (делегирование у потребителя, как у `Core.Outbox.Migration`) создаёт
      `es_events`: тип агрегата, `aggregate_id`, `aggregate_version`, id события, тег, `payload` jsonb, `by_id` без FK,
      `at` с точностью до секунды, `xid xid8 default pg_current_xact_id()`, номер из identity; unique
      `(тип, aggregate_id, aggregate_version)`; индексы `(xid, номер)` и `(тип, xid, номер)`. Тестовые миграции
      библиотеки её вызывают.
- [x] `append` — пачка событий нескольких потоков одного типа агрегата (тип — из кодека): `insert_all` с
      `on_conflict: :nothing` и сверкой числа строк; страж — отказ, если в потоке есть событие с `xid` больше
      `pg_current_xact_id()`.
- [x] Опция непрерывности потока: первая версия потока в пачке = `max + 1` (пустой поток — 1), иначе
      `:version_mismatch`; версии не подряд внутри пачки — `raise`. Без опции поток может начинаться не с 1 и иметь
      разрывы.
- [x] Любой отказ — `:version_mismatch` с detail `%{aggregate_id, expected, actual}`: `expected` — первая версия потока
      в пачке, `actual` — `max` версии отдельным `SELECT` только на пути ошибки; ns и код ошибки задаёт вызывающий
      write-репозиторий; после отказа транзакция пригодна для дальнейших запросов.
- [x] Запись не опирается на приватные API Ecto / ecto_sql.
- [x] `Core.Es.Store.Test.events!(event_codec, %Agg.ID{})` — `[Es.Event]` всего потока через фасад по возрастанию
      версии; ошибка `load` — `raise`.
- [x] Тесты гонок: `ExUnit.Case, async: false`, участники в `Sandbox.unboxed_run` с настоящими commit, шаги —
      сообщениями без `sleep`, `TRUNCATE` в `on_exit`, без тега (входят в `make`): unique при конкурентной записи одной
      версии; страж `xid` — транзакция получила xid до commit конкурента и пишет следующую версию → `:version_mismatch`.
- [x] `13-repos.md`: новый раздел «Хранилище событий (`Core.Es.Store`)» (старый «Event store» убирает тикет 28);
      «Наименование» — `es_events`. README, «Что предоставляет потребитель»: миграция `Core.Es.Migration`.
      `CHANGELOG.md`, «Новое»: хранилище событий.
- [x] `make` зелёный.
