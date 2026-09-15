# 39: Процесс агрегата на id: очередь команд и кэш состояния

**What to build:** с `enabled: true` команды одного агрегата выстраиваются в очередь процесса на id: процесс держит
состояние в памяти, перед каждой командой дочитывает хвост потока, стартует по первому обращению и уходит по idle
timeout. Корректность по-прежнему держат проверки `append`, поэтому второй процесс того же агрегата и запись в обход
процесса штатны.

**Blocked by:** [38: `Agg.Process.execute` в режиме `enabled: false`](38-aggregate-process-inline.md)

**Status:** resolved

**Spec:** [Event-sourced агрегат в :core](../spec.md) — «Процесс агрегата
(`Core.Es.Aggregate.Process`)»

- [x] `child_spec/1` при `enabled: true` — `Supervisor` из `Registry` и `DynamicSupervisor`; процессы на id —
      `restart: :temporary`; единственность — `Registry` на ноду.
- [x] Старт лениво в первой команде, без запросов в `init/1` и `handle_continue/2`; первая команда — `Agg.Repo.get`,
      дальше `Agg.Repo.refresh(state, version, context)`; состояние процесса меняется только после commit.
- [x] Окружение вызывающего на время команды: `:shadow_copy` в `context` заменяется собственной таблицей `Repo.Sc`
      (`init` → команда → `delete`), OTel-контекст — `Otel.with_ctx/2`, `Logger.metadata()` ставится и снимается;
      `context` между командами не хранится.
- [x] `timeout:` в `opts`, по умолчанию 5 000 мс: дедлайн в сообщении — просроченная команда отбрасывается до
      транзакции; истечение у вызывающего и падение процесса — exit вызывающему, до commit транзакция откатывается;
      `raise` в `decide` / `evolve` роняет процесс; `:noproc` — один повтор со стартом.
- [x] Уход по `idle_timeout:` — `{:stop, :normal}` без записи снапшота; `debug` на старт и уход.
- [x] Span `execute` охватывает ожидание в очереди, span event `dequeued`; telemetry `execute` с `mode: :process` и
      `queue`; `[:es, :aggregate, :process, :start]` и `:stop` с `reason: :idle | :error`.
- [x] Хелпер `watch_list` из `use` — только верхний супервизор под атомом `Agg.Process`,
      `component: "es_aggregate_process:<тип агрегата>"`; при `enabled: false` элемента нет.
- [x] Тесты `async: false`, shared mode `Core.DataCase`, без `allow` и `$callers`: конкурентные команды одного
      агрегата проходят без `:version_mismatch`; запись в обход через репозиторий подхватывается `refresh`; повтор
      `Account.RacyProcess`; уход по idle; просроченная команда; падение на `raise` в `decide`; `:noproc`; окружение
      (`Logger.metadata`, OTel-контекст, `Repo.Sc` вызывающего не затронут).
- [x] `19-testing.md`, «Процессы» — shared mode вместо `allow` у процессов, стартующих внутри вызова.
      `CHANGELOG.md`, «Новое».
- [x] `make` зелёный.

## Comments

- 2026-09-14 — реализация:
  - код разнесён по модулям: `Core.Es.Aggregate.Process` — `use`, `execute`, дерево и `watch_list`;
    `Process.Execution` — транзакция с повтором, общая для обоих режимов (без закэшированного состояния — `get`, с
    ним — `refresh`); `Process.Server` — GenServer на id и сторона вызывающего;
  - дерево — `Supervisor` под именем модуля процесса, `rest_for_one`: `<Agg.Process>.Registry` (`:unique`) и
    `<Agg.Process>.Supervisor`; имена — `Module.concat` на компиляции в `use` с `credo:disable` и причиной, как у
    `Core.Config`; отметка ставится после старта дерева, `info` «запущен»;
  - вызов — `GenServer.call({:via, Registry, …})`; `:noproc` → `DynamicSupervisor.start_child` (гонка старта —
    `{:already_started, pid}`) и один повтор. Повтор срабатывает и на exit `:normal`: процесс, ушедший по простою, пока
    команда стояла в его mailbox, её не исполнял;
  - дедлайн — `monotonic_time(:millisecond) + timeout` в запросе: команда, просроченная к выходу из очереди,
    отбрасывается без ответа; проверка перед commit — последний шаг транзакции, иначе откат. Метки конфликта и
    дедлайна — с именем модуля, чтобы `{:error, _}` колбэка не путался со служебными;
  - `Repo.Sc` процесса ставится на каждую команду, даже если у вызывающего таблицы не было. `context`, пойманный
    колбэком из замыкания, — контекст вызывающего, и его `Repo.Sc` в процессе на id недоступен (приватная ETS); это
    отмечено в `CHANGELOG.md`, API колбэка не менялся;
  - exit у вызывающего — telemetry `result: :exit` с `queue: 0` и `retries: 0` в обоих режимах; статус span'а на exit
    не меняется;
  - span event `dequeued` — новая `Core.Otel.add_event/2` фасада; `Core.OtelFixture` отдаёт имена событий span'а;
  - `start` / `stop` — без измерений; `stop` с `:error` шлёт `terminate/2` на исключении; остановка супервизором
    (`:shutdown`) telemetry не шлёт;
  - `raise` в `decide` в тесте — команда `Unknown` тест-файла без клаузы `decide/2`; причина падения процесса —
    эрланговское `{:function_clause, stack}`;
  - тест ухода по простою шлёт процессу `:timeout` сам, без таймера; тесты дедлайна — `timeout: 50` у вызывающего при
    процессе, заблокированном колбэком до сообщения теста, так что исход детерминирован.
- 2026-09-14 — по ревью:
  - load/save: `get` / `refresh` — в теле транзакции рядом с `append`, без хелпера `load/3`;
  - процесс на id ставит `trap_exit`, `shutdown: 10_000` — запас на команду с `timeout:` по умолчанию (допущение,
    риск низкий); на отброшенную просроченную команду — `warning` вместо `debug`;
  - `{:error, _}` колбэка не с `%Error{}` снова уходит вызывающему как есть: срез ломал его в обоих режимах;
  - добавлены тесты: снятие OTel-контекста после команды, откат при `raise` в колбэке после `append`, `{:error, :expired}`
    колбэка; тест span процесса перенесён в describe «span», на который ссылается `21-observability.md`;
  - `19-testing.md` — пример «плохо / хорошо» к норме shared mode; `13-repos.md` — `refresh` у процесса на id;
    «Область» `17-otp-concurrency.md` и описание skill — процесс на id; порядок `at` / `by` в тестовой команде;
  - оставлено: параметры `cfg, call, target, cached`, путешествующие вместе в `Execution`, имя `target` и развилка по
    `mode` в двух местах — суждения без выигрыша; реальные 50 мс в тестах дедлайна; сужение `@spec` колбэка до
    `Error.t()` — из тикета 38; отдельный пункт CHANGELOG для `Core.Otel.add_event/2` — упомянут в пункте процесса.
