# 39: Процесс агрегата на id: очередь команд и кэш состояния

**What to build:** с `enabled: true` команды одного агрегата выстраиваются в очередь процесса на id: процесс держит
состояние в памяти, перед каждой командой дочитывает хвост потока, стартует по первому обращению и уходит по idle
timeout. Корректность по-прежнему держат проверки `append`, поэтому второй процесс того же агрегата и запись в обход
процесса штатны.

**Blocked by:** [38: `Agg.Process.execute` в режиме `enabled: false`](38-aggregate-process-inline.md)

**Status:** ready-for-agent

**Spec:** [Event-sourced агрегат в :core](../spec.md) — «Процесс агрегата
(`Core.Es.Aggregate.Process`)»

- [ ] `child_spec/1` при `enabled: true` — `Supervisor` из `Registry` и `DynamicSupervisor`; процессы на id —
      `restart: :temporary`; единственность — `Registry` на ноду.
- [ ] Старт лениво в первой команде, без запросов в `init/1` и `handle_continue/2`; первая команда — `Agg.Repo.get`,
      дальше `Agg.Repo.refresh(state, version, context)`; состояние процесса меняется только после commit.
- [ ] Окружение вызывающего на время команды: `:shadow_copy` в `context` заменяется собственной таблицей `Repo.Sc`
      (`init` → команда → `delete`), OTel-контекст — `Otel.with_ctx/2`, `Logger.metadata()` ставится и снимается;
      `context` между командами не хранится.
- [ ] `timeout:` в `opts`, по умолчанию 5 000 мс: дедлайн в сообщении — просроченная команда отбрасывается до
      транзакции; истечение у вызывающего и падение процесса — exit вызывающему, до commit транзакция откатывается;
      `raise` в `decide` / `evolve` роняет процесс; `:noproc` — один повтор со стартом.
- [ ] Уход по `idle_timeout:` — `{:stop, :normal}` без записи снапшота; `debug` на старт и уход.
- [ ] Span `execute` охватывает ожидание в очереди, span event `dequeued`; telemetry `execute` с `mode: :process` и
      `queue`; `[:es, :aggregate, :process, :start]` и `:stop` с `reason: :idle | :error`.
- [ ] Хелпер `watch_list` из `use` — только верхний супервизор под атомом `Agg.Process`,
      `component: "es_aggregate_process:<тип агрегата>"`; при `enabled: false` элемента нет.
- [ ] Тесты `async: false`, shared mode `Core.DataCase`, без `allow` и `$callers`: конкурентные команды одного
      агрегата проходят без `:version_mismatch`; запись в обход через репозиторий подхватывается `refresh`; повтор
      `Account.RacyProcess`; уход по idle; просроченная команда; падение на `raise` в `decide`; `:noproc`; окружение
      (`Logger.metadata`, OTel-контекст, `Repo.Sc` вызывающего не затронут).
- [ ] `19-testing.md`, «Процессы» — shared mode вместо `allow` у процессов, стартующих внутри вызова.
      `CHANGELOG.md`, «Новое».
- [ ] `make` зелёный.
