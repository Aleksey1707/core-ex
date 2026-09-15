# 38: `Agg.Process.execute` в режиме `enabled: false`: команда с повтором после конфликта

**What to build:** автор usecase исполняет команду одного event-sourced агрегата вызовом
`Agg.Process.execute(id, version, cmd, context, fun, opts)`: `get` → `Agg.execute/2` → `append` → колбэк
сопутствующих записей идут в одной транзакции, а штатный конфликт на `:current` повторяется сам до `retries:`. В этом
тикете дерево стартует с `enabled: false`, и команда исполняется в вызывающем процессе — тот же API, что тикет 39 отдаст
процессу на id.

**Blocked by:** [31: Write-репозиторий event-sourced агрегата](31-event-sourced-repo.md)

**Status:** resolved

**Spec:** [Event-sourced агрегат в :core](../spec.md) — «Процесс агрегата
(`Core.Es.Aggregate.Process`)»

- [x] `use Core.Es.Aggregate.Process, repo: Agg.Repo` (реализация — по ADR-0006) генерирует `execute/6` и
      `child_spec/1`; опции старта через `StartOpts`: `enabled:` обязательна, `retries:` 3, `idle_timeout:` 60 000 мс.
- [x] `enabled: false` → `:ignore`, `info` и отметка в `:persistent_term`; дерево не запущено и отметки нет — `raise`.
- [x] Команда — один `Transact.run`: `Agg.Repo.get(id, version, context)` → `Agg.execute/2` → `append` →
      `fun.(events)` (`:ok | {:error, _}`); ошибка `decide` или колбэка — откат и `{:error, _}`.
- [x] `:version_mismatch` из `append` при `:current` — повтор новой транзакцией до `retries:`, колбэк зовётся заново;
      `debug` на повтор, `warning` `type= aggregate_id= retries=` на исчерпание. `%Version{}` мимо версии потока, в том
      числе пустого, — `:version_mismatch` без повтора.
- [x] `execute` внутри `Transact.run` — `raise`.
- [x] Span `Core.Otel.Es.execute(type, aggregate_id, command, fun)` — `"execute <тип>"` у вызывающего,
      `core.es.aggregate.type` / `.id`, `core.es.command`, `core.es.execute.mode`, `core.es.retries`; telemetry
      `[:es, :aggregate, :process, :execute]` (`duration`, `queue: 0`, `retries`; `type`, `mode: :inline`,
      `result: :ok | :version_mismatch | :error | :exit`), код доменной ошибки в теги не идёт.
- [x] `Account.RacyRepo{,.Pg}` в `test/support` (перед первыми K `append` дописывает конкурирующее событие через
      `Core.Es.Store.append`) и `Account.RacyProcess` с `repo: Account.RacyRepo`. Тесты: успех; колбэк пишет через
      `DAO` в той же транзакции и откатывается вместе с ней; повтор и исчерпание `retries:`; устаревшая версия; оба
      `raise`; span и telemetry.
- [x] `13-repos.md` — H3 «Процесс агрегата» в write-пути event-sourced агрегата (MAY для команды одного агрегата,
      несколько агрегатов — MUST usecase → repo, колбэк — под ограничениями `Transact.run`); `20-agreements.md` —
      `Agg.Process.execute` MUST NOT внутри `Transact.run`, повтор после `:version_mismatch` на `debug`, исчерпание
      предела — `warning`; `21-observability.md` — span команды у вызывающего; `19-testing.md` — тесты потребителя с
      `enabled: false`; README — `{Agg.Process, enabled:}`; `CHANGELOG.md`, «Новое».
- [x] `make` зелёный.

## Comments

- 2026-09-14 — реализация:
  - агрегат и Prim id `use Core.Es.Aggregate.Process` берёт из интроспекции behaviour — новая `@doc false`
    `__es_aggregate_repo__/0` у `use Core.Es.Aggregate.Repo`; тип — `type:` кодека событий агрегата на компиляции;
    реализация — `Core.Config.repo!/1` в атрибуте `@es_aggregate_process` модуля потребителя;
  - транзакция команды — `Core.Config.dao/0`, id в span и логах — `Core.Config.codec/0`;
  - `enabled: true` пока `ArgumentError` («ожидается false: процесса на id ещё нет») — снимает тикет 39;
  - `opts` — `Keyword.validate!` с `timeout: 5_000` и проверкой значения: положительное целое, в вызывающем процессе
    не действует;
  - `result: :exit` при исполнении в вызывающем процессе не возникает — его вводит тикет 39 вместе с процессом на id;
  - span: режим и число повторов — `Core.Otel.Es.executed/2` по исходу; прикладная ошибка — `record_error/1`,
    доменный отказ (в том числе `:version_mismatch` после повторов) статус span'а не меняет — норма в
    `21-observability.md` и спеке;
  - колбэк вызывается после `append`: попытка с конфликтом до него не доходит, колбэк успешной попытки — один; возврат
    вне `:ok | {:error, _}` — `CaseClauseError` в транзакции, до commit;
  - `Account.RacyRepo.Pg` делегирует в `Account.Repo.Pg` (ошибка — `module: Account.Repo`); конкурирующее `Renamed`
    той же версии пишется в транзакции команды и откатывается вместе с попыткой: sandbox `Core.DataCase` не даёт
    закоммитить его отдельно, а коммит вне sandbox поднял бы страж `xid` на каждой попытке. Счётчик K —
    `race/2`, публичная ETS-таблица процесса теста: гонку увидит и `append` процесса на id в тикете 39. Новый `get`
    каждой попытки тест проверяет числом `[:es, :aggregate, :load]` с `op: :get`;
  - неподнятый процесс в тесте — модуль `Unstarted` в тест-файле, отметка остальных стирается в `on_exit`.
- 2026-09-14 — по ревью:
  - дубль нормы «`execute` внутри `Transact.run`» снят из `13-repos.md` — строка-ссылка на `20-agreements.md`;
  - пункт `19-testing.md` получил пример «плохо / хорошо»;
  - `@type cfg` вместо `map()`, `appended/2` → `tag_conflict/2`, `refresh/4` фикстуры — до `append`;
  - оставлено: `fun \\ nil` — сигнатура спеки; `idle_timeout:`, `timeout:`, `queue: 0`, `mode: :process` в
    `executed/2` — API тикетов 38/39; строка метрики в PromEx — тикет 40; ссылка `20-agreements.md` на таблицу
    «Что можно внутри `Transact.run`», которой нет в `10-architecture.md`, — существовала до правки; общий модуль
    отметки старта и проверки транзакции с `Core.Es.Projection.Await` — вне задачи.
