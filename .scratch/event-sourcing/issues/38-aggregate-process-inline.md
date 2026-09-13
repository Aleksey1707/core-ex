# 38: `Agg.Process.execute` в режиме `enabled: false`: команда с повтором после конфликта

**What to build:** автор usecase исполняет команду одного event-sourced агрегата вызовом
`Agg.Process.execute(id, version, cmd, context, fun, opts)`: `get` → `Agg.execute/2` → `append` → колбэк
сопутствующих записей идут в одной транзакции, а штатный конфликт на `:current` повторяется сам до `retries:`. В этом
тикете дерево стартует с `enabled: false`, и команда исполняется в вызывающем процессе — тот же API, что тикет 39 отдаст
процессу на id.

**Blocked by:** [31: Write-репозиторий event-sourced агрегата](31-event-sourced-repo.md)

**Status:** ready-for-agent

**Spec:** [Event-sourced агрегат в :core](../spec.md) — «Процесс агрегата
(`Core.Es.Aggregate.Process`)»

- [ ] `use Core.Es.Aggregate.Process, repo: Agg.Repo` (реализация — по ADR-0006) генерирует `execute/6` и
      `child_spec/1`; опции старта через `StartOpts`: `enabled:` обязательна, `retries:` 3, `idle_timeout:` 60 000 мс.
- [ ] `enabled: false` → `:ignore`, `info` и отметка в `:persistent_term`; дерево не запущено и отметки нет — `raise`.
- [ ] Команда — один `Transact.run`: `Agg.Repo.get(id, version, context)` → `Agg.execute/2` → `append` →
      `fun.(events)` (`:ok | {:error, _}`); ошибка `decide` или колбэка — откат и `{:error, _}`.
- [ ] `:version_mismatch` из `append` при `:current` — повтор новой транзакцией до `retries:`, колбэк зовётся заново;
      `debug` на повтор, `warning` `type= aggregate_id= retries=` на исчерпание. `%Version{}` мимо версии потока, в том
      числе пустого, — `:version_mismatch` без повтора.
- [ ] `execute` внутри `Transact.run` — `raise`.
- [ ] Span `Core.Otel.Es.execute(type, aggregate_id, command, fun)` — `"execute <тип>"` у вызывающего,
      `core.es.aggregate.type` / `.id`, `core.es.command`, `core.es.execute.mode`, `core.es.retries`; telemetry
      `[:es, :aggregate, :process, :execute]` (`duration`, `queue: 0`, `retries`; `type`, `mode: :inline`,
      `result: :ok | :version_mismatch | :error | :exit`), код доменной ошибки в теги не идёт.
- [ ] `Account.RacyRepo{,.Pg}` в `test/support` (перед первыми K `append` дописывает конкурирующее событие через
      `Core.Es.Store.append`) и `Account.RacyProcess` с `repo: Account.RacyRepo`. Тесты: успех; колбэк пишет через
      `DAO` в той же транзакции и откатывается вместе с ней; повтор и исчерпание `retries:`; устаревшая версия; оба
      `raise`; span и telemetry.
- [ ] `13-repos.md` — H3 «Процесс агрегата» в write-пути event-sourced агрегата (MAY для команды одного агрегата,
      несколько агрегатов — MUST usecase → repo, колбэк — под ограничениями `Transact.run`); `20-agreements.md` —
      `Agg.Process.execute` MUST NOT внутри `Transact.run`, повтор после `:version_mismatch` на `debug`, исчерпание
      предела — `warning`; `21-observability.md` — span команды у вызывающего; `19-testing.md` — тесты потребителя с
      `enabled: false`; README — `{Agg.Process, enabled:}`; `CHANGELOG.md`, «Новое».
- [ ] `make` зелёный.
