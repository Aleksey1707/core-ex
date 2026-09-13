# Раскладка сводов `docs/rules` под event sourcing

Type: grilling
Status: resolved
Blocked by: 21
Map: [Event-sourced агрегат в :core](../map.md)

## Question

Как нормы event sourcing, решённые в тикетах карты, ложатся в `docs/rules`:

- новый свод про event sourcing (номер, область, «Читать перед», skill и строка в таблице `CLAUDE.md`) или правки
  `13-repos.md`, `14-events-outbox.md`, `17-otp-concurrency.md`, `19-testing.md`, `20-agreements.md`,
  `21-observability.md`; номера 15, 16 и 18 заняты сводами потребителя (`00-index.md`);
- во что переименовать «команда / запрос» в разделе CQS `20-agreements.md`: словарь расходится с термином «Команда» в
  `CONTEXT.md`, где у Usecase уже «изменяющий / читающий»;
- что из перечня ниже — норма свода (MUST / SHOULD / MAY), а что — только moduledoc или README.

Сами нормы решены в тикетах и заново не обсуждаются. Перечень перенесён из «Not yet specified» карты:

- `14-events-outbox.md` — таблица «Совместимость событий» из «Эволюция событий»;
- норма «поднять `version:` в `snapshot:`, если `evolve` зависит от кода вне агрегата, кодека и модулей событий» и
  `refresh` в `13-repos.md`;
- разделы о процессе агрегата и дереве проекций в `17-otp-concurrency.md` с исключением `Registry` из нормы «имя, по
  которому будят, — из конфига» и SHOULD «следующий тик нового периодического цикла — чистая функция с тестом без
  процесса»;
- `Repo.Pg.Es` → `Repo.Pg.StateStored` и удаление триплета `Es.Event.Repo` — `13-repos.md` («Write агрегата с
  событиями», «Event store», «Role Repo vs common Repo.Pg vs Event.Repo», «Наименование»), `14-events-outbox.md`
  («Domain events»), списки модулей `10-architecture.md` / `20-agreements.md`, `DEBT.md`, README «Что предоставляет
  потребитель» (и `Core.Es.Projection.Supervisor` с env `ES_PROJECTIONS_*`);
- норма «голова `evolve` матчит только событие, не значения состояния» — к контракту агрегата;
- `19-testing.md` — «Совместимость событий» на `use Core.Es.EventCompatCase`, раздел «Event-sourced агрегат» (из
  «Тестовая поддержка event-sourced агрегата»), `run_once` проекции и `async: false` у теста с её прогоном;
- из «Тестовая поддержка проекций и процессов» — case `Core.Es.ProjectionCase`, `run_until_idle`, `await: :inline` в
  тестовом дереве, SHOULD запись → `run_until_idle` и MAY прямой `project/1`, shared mode вместо `allow` у процессов,
  стартующих внутри вызова, тесты гонок через `unboxed_run`;
- нормы проекций из «Пересборка проекций» — таблицу read-модели пишет одна проекция, когда поднимать `version:`, рецепт
  новой проекции в три выкладки и запрет удалять таблицы в выкладке, убирающей модуль или ReadRepo, расширяющая миграция
  при пересборке на месте, неизменяемое имя удалённой проекции и `delete_checkpoint/1`;
- `21-observability.md` — раздел event sourcing из «Наблюдаемость event-sourced агрегата и проекций»: словарь
  `Core.Otel.Es`, span только на пачку проекции с работой, трейс в `es_events` не хранится, таблица алертов
  `EsProjection*`;
- `17-otp-concurrency.md` — элемент `watch_list` не включается при выключенном поддереве вместо `required:`;
- `20-agreements.md` — повтор после конфликта в процессе агрегата на `debug`, исчерпание — `warning`;
- страница потока из [«История потока на read-пути»](21-grilling-stream-history-read-path.md) — вместо разделов «Event
  store» и строки `Event.Repo` в «Role Repo vs common Repo.Pg vs Event.Repo» `13-repos.md`: `Core.Es.Store.page_stream/5`,
  MUST проверки прав и существования через `ReadRepo.get` до чтения, `Es.Event` вместо View с обоснованием, ошибка `load`
  на всю страницу, история нескольких агрегатов — проекция потребителя, слово «страница потока», не «история»;
  `Core.Es.Store.Test.events!/2` — `19-testing.md`;
- README — `Core.Es.PromEx` с `projections:` / `processes:`.

## Answer

- **Когда** — здесь только карта размещения; правки `docs/rules`, README, `DEBT.md`, `.claude/skills` — в срезах спеки,
  в коммите с кодом, как `CHANGELOG.md`.
- **Критерий** — свод: выбор автора, который не ловят компиляция и `StartOpts`, объявление примером `use` с опциями
  выбора, какой тест-кейс взять и что он ловит; moduledoc: полный перечень опций и дефолтов, исходы, устройство; README:
  подключение — миграции, дерево, env, PromEx; ADR: почему. Таблица опций `Repo.Pg.StateStored` не сжимается, в новых
  разделах дефолтов нет.
- **Файлы** — нормы event-sourced агрегата по слоям; проекции — новый свод `22-projections.md`, skill `projections`,
  строки в картах `00-index.md` и `AGENTS.md`.
- **Словарь** — «изменяющая / читающая» функция и usecase во всех сводах: «Разделение изменения и чтения (CQS)»,
  «Наименование читающих функций: `find` / `get` / `get!`»; в `13` / `14` / `21` — «command-flow», «usecase запросов /
  команд», «цепочке команд», «Джоба-команда», «трейс команды», «от команды до обработчика»; «запрос» SQL и HTTP не
  меняется. «Команда» (`CONTEXT.md`) — данные с намерением изменить агрегат любого вида; строка `Cmd.Codec` в `11`
  остаётся.
- **`11-domain.md`**, «Aggregates» — общее (Version, аудит-поля, домен не пишет в БД) и H3:
  - «State-stored» — копит `events`, мутация → `{:ok, %Agg{}}`, soft-delete;
  - «Event-sourced» — `use Core.Es.Aggregate`; `evolve` чистый, без проверки инвариантов и catch-all; голова `evolve`
    MUST матчить только событие (Проверяется: `use Core.Es.EventCompatCase, aggregate:`); `not_found` /
    `already_exists` — ошибки `decide`, `get` их не отдаёт (плохо / хорошо);
  - «Команда» — `<Aggregate>.Cmd.<Name>`, у event-sourced `use Core.Es.Cmd`.
- **`13-repos.md`**:
  - «Write агрегата с событиями» → «Write state-stored агрегата (`use Core.Repo.Pg.StateStored`)»: `event_codec:` вместо
    `event_repo:`, flush через `Core.Es.Store.append`;
  - H2 «Write event-sourced агрегата (`use Core.Es.Aggregate.Repo.Pg`)»: пример `use`; `get` / `get_many` / `append` /
    `refresh`; один репозиторий в `common/<aggregate>/` без `default_filters`, `Repo.Sc` и `delete`; `snapshot:` и MUST
    поднять `version:`, если `evolve` зависит от кода вне агрегата, кодека и модулей событий; H3 «Процесс агрегата» —
    `common/<aggregate>/process.ex`, MAY для команды одного агрегата, несколько агрегатов — MUST usecase → repo,
    колбэк `fun` — под ограничениями `Transact.run`;
  - «Role Repo vs common Repo.Pg» — без `Event.Repo` и абзаца «Чтение истории»;
  - «Event store» → «Хранилище событий (`Core.Es.Store`)»: `append` MUST NOT вне `use Core.Es.Aggregate.Repo.Pg` /
    `use Core.Repo.Pg.StateStored`, MAY — тестовые дублёры в `test/support`;
  - H2 «Страница потока»: `page_stream/5`; MUST проверить права и существование через `ReadRepo.get` до чтения
    (плохо / хорошо); `Es.Event` вместо View — ADR-0010; ошибка `load` на всю страницу; поток нескольких агрегатов —
    проекция (`22-projections.md`); слово «страница потока», не «история»;
  - «Слои и пути» — модули ES, `common/<aggregate>/process.ex`, `<bc>/common/<read_model>/projection.ex` (ReadRepo и
    View — по действующей раскладке с `<read_model>`), без `<aggregate>/event/repo*`; «Наименование» — `es_events` /
    `es_checkpoints` / `es_snapshots` из `Core.Es.Migration`; «Schema», «Тесты», шапка — механически.
- **`14-events-outbox.md`**:
  - «Domain events» — flush обоих видов через `Core.Es.Store.append`; `type:` у кодека MUST; `upcasts:` + `upcast/2`;
    `:version_mismatch` — unique, страж `xid`, у event-sourced непрерывность потока;
  - «Совместимость событий» — таблица из «Эволюция событий», MUST NOT переписывать историю, тег остаётся в кодеке
    навсегда — в `tags:` или `upcasts:`; «Golden-фикстуры» — инварианты 1–4 и полнота `evolve`;
  - «Идемпотентность потребителей» — реакция с внешним эффектом — подписчик, не проекция (`22-projections.md`).
- **`17-otp-concurrency.md`** — `watch_list` без элемента выключенного поддерева вместо `required:`; «Имена процессов» —
  исключение: получатели `wake` регистрируются в `Registry` сами; SHOULD: следующий тик нового периодического цикла —
  чистая функция с тестом без процесса; `Core.Es.Projection.Reader` в таблице `trap_exit`.
- **`19-testing.md`** — «Case-модули» + `Core.Es.EventCompatCase` / `Core.Es.ProjectionCase`; «Совместимость событий» →
  `use Core.Es.EventCompatCase, aggregate: | event_codec:`; H2 «Event-sourced агрегат» (`given/3`, then SHOULD —
  короткая форма `decide/2`, состояние — `evolve` через `fold`), «Записанные события» (`Core.Es.Store.Test.events!/2`),
  «Проекции» (`ProjectionCase`, SHOULD запись → `run_until_idle` → ReadRepo, MAY прямой `project/1`, `async: false` у
  прогона, `await: :inline`); «Процессы» — shared mode вместо `allow` у процессов, стартующих внутри вызова,
  `enabled: false` у процесса агрегата, гонки — `Sandbox.unboxed_run`.
- **`20-agreements.md`** — словарь CQS; абзац `Transact.run` — `await` и `Agg.Process.execute` MUST NOT внутри;
  «Load/save в одной функции» — пример `get` → `Agg.execute/2` → `append`; «Логирование» — повтор после
  `:version_mismatch` на `debug`, исчерпание предела — `warning`; исключения `@spec` и «Safe vs bang» — новые имена модулей.
- **`21-observability.md`** — `Core.Otel.Es` в словарях; «Где ставить span» — только пачка проекции с работой, у
  восстановления агрегата span'а нет, span команды — у вызывающего `Agg.Process.execute`; MUST NOT хранить контекст
  трейса в `es_events`, связь — `event_id`.
- **`22-projections.md`** — «Объявление» (`use Core.Es.Projection, name:, events:, version:`, `project/1` без `Context`,
  MUST NOT внешних эффектов), «Read-модель» (MUST один писатель, ReadRepo MAY читать несколько), «Версия и пересборка»
  (когда MUST поднять `version:`, SHOULD расширяющая миграция), «Новая проекция» (три выкладки, MUST NOT удалять таблицы
  в выкладке, убирающей модуль или ReadRepo), «Удаление» (`delete_checkpoint/1`, имя MUST NOT переиспользовать),
  «Read-after-write» (`await`), «Дерево» (один `Core.Es.Projection.Supervisor` со всем списком), «Эксплуатация» (алерты
  `EsProjectionRetrying`, `EsProjectionLagging`, `EsProjectionRebuildLong`, `EsProjectionOutdated`: имя, PromQL, смысл).
- **`10-architecture.md` / `12-errors.md`** — списки макросов и OTP-процессов: `Repo.Pg.StateStored`,
  `Es.Aggregate.Repo.Pg`, `Es.Projection`, `Es.Projection.Supervisor`, `Agg.Process`; «Источники `%Error{}`» —
  `Core.Es.Store`, кодек событий, `:projection_timeout` / `:projection_rebuilding`.
- **Skills** — `.claude/skills/projections/SKILL.md`; новые модули и триггеры в `description` у `domain`, `repos`,
  `events-outbox`, `otp-concurrency`, `testing`, `observability`.
- **`DEBT.md`** — `Core.Repo.Pg.Es` → `Core.Repo.Pg.StateStored`, новых строк нет.
- **README** — шапка и «Состав»; «Что предоставляет потребитель»: без п. 3 (Ecto-тип jsonb), миграции —
  `Core.Es.Migration`, supervision — `Core.Es.Projection.Supervisor` с env `ES_PROJECTIONS_*` и `{Agg.Process, enabled:}`,
  PromEx — `Core.Es.PromEx` с `projections:` / `processes:`.
- **`CHANGELOG.md`** — строка `22-projections.md` в таблицы «Файл библиотеки» сводов потребителей.
- ADR не заводится: раскладка откатывается правкой файлов. `CONTEXT.md` — «Команда». Вне тикета: ссылка
  `20-agreements.md` на таблицу «Что можно внутри `Transact.run`» в `10-architecture.md` висит — таблицы в библиотеке нет.

## Comments

- 2026-09-13 — из тикета [«История потока на read-пути»](21-grilling-stream-history-read-path.md): страница потока
  нужна и state-stored потребителю, а все нынешние потребители — state-stored; норма чтения потока не может жить только
  в своде, который читают при работе с event-sourced агрегатом.
- 2026-09-13 — факты для раскладки:
  - размеры: `13-repos.md` 668 строк, `20-agreements.md` 535, `11-domain.md` 512, `14-events-outbox.md` 387,
    `19-testing.md` 186, `21-observability.md` 136, `17-otp-concurrency.md` 122; `00-index.md`: дом правила — по слою,
    новое правило — пример «плохо / хорошо» или «Проверяется:», README — подключение для потребителя;
  - `make rules-check` сверяет файлы с картами `00-index.md` и `AGENTS.md` и требует skill `.claude/skills/<тема>/SKILL.md`;
  - своды `quality-control-back`, `gar-back`, `messages-back`, `ecom-example-ex` — дельты поверх
    `deps/core/docs/rules` с таблицей «Файл библиотеки» в своём `00-index.md`; номера ≥ 22 свободны у всех;
  - CQS-смысл «команды / запроса» — ещё в `13-repos.md` («command-flow», «Usecases запросов / команд», «цепочке
    команд»), `14-events-outbox.md` («Джоба-команда», «трейс команды»), `21-observability.md` («от команды до
    обработчика»);
  - `11-domain.md`, слои Codec: `<Aggregate>.Cmd.Codec` — «кодек команд»; в библиотеке `Cmd` нет, в `ecom-example-ex`
    state-stored `Product` применяет `Product.Cmd.*` (`create_by_command/2`, `apply_command/3`), команды без `by` /
    `at` хранятся в jsonb операции черновика;
  - `13-repos.md` держит таблицы опций `use Repo.Pg.Es` и перечень генерируемого — прецедент опций макроса в своде.
- 2026-09-13 — раунд 1:
  - в ответе тикета — карта размещения (норма → файл и раздел, модальность); правки `docs/rules`, README, `DEBT.md`,
    skills — в срезах спеки, в коммите с кодом, как `CHANGELOG.md`; правка свода до кода отвергнута — объявит дефектом
    нынешний код;
  - нормы event-sourced агрегата — по слоям: `11-domain.md`, `13-repos.md`, `17-otp-concurrency.md`,
    `20-agreements.md`; свод `22-event-sourcing.md` отвергнут — дом правила по слою, write-путь разошёлся бы по двум
    файлам;
  - нормы проекций — новый свод `22-projections.md`, skill `projections`; тесты, OTP и наблюдаемость проекций — в `19` /
    `17` / `21`; раздел в `14-events-outbox.md` отвергнут — проекция отдельный слой со своим жизненным циклом, а `14`
    грузится на любую правку outbox; строка в таблицы «Файл библиотеки» сводов потребителей — пункт `CHANGELOG.md`;
  - словарь CQS — «изменяющая / читающая» функция и usecase во всех сводах: заголовок «Разделение изменения и чтения
    (CQS)», «Наименование читающих функций: `find` / `get` / `get!`», «запрос» в смысле SQL и HTTP не меняется;
    правка только `20-agreements.md` и оговорка при старом словаре отвергнуты;
  - «Команда» — данные с намерением изменить агрегат любого вида (`CONTEXT.md` поправлен); у event-sourced —
    `use Core.Es.Cmd` с `by` / `at`; строка `<Aggregate>.Cmd.Codec` в `11-domain.md` остаётся; термин только для
    event-sourced отвергнут — `Product.Cmd` в `ecom-example-ex` то же понятие;
  - критерий: свод — выбор автора, не пойманный компиляцией и `StartOpts`, объявление примером `use` с опциями выбора,
    какой тест-кейс взять и что он ловит; moduledoc — полный перечень опций и дефолтов, исходы, устройство; README —
    подключение (миграции, дерево, env, PromEx); ADR — почему; таблица опций `Repo.Pg.Es` → `Repo.Pg.StateStored` не
    сжимается, в новых разделах дефолтов нет; полные таблицы опций в своде отвергнуты.
- 2026-09-13 — раунд 2:
  - процесс агрегата — H3 write-пути event-sourced в `13-repos.md`, запрет `Agg.Process.execute` в `Transact.run` —
    абзац CQS `20-agreements.md`, тесты — `19-testing.md`, в `17-otp-concurrency.md` только общее; раздел «Процесс
    агрегата» в `17` отвергнут — путь команды выбирают рядом с `get` → `execute/2` → `append`, а процесс потребитель не
    пишет;
  - алерты `EsProjection*` — «Эксплуатация» в `22-projections.md`, по образцу runbook outbox в `14`; таблица в
    `21-observability.md` отвергнута;
  - раскладка проекции — `<bc>/common/<read_model>/projection.ex`, ReadRepo и View — по действующей раскладке с
    `<read_model>`; `<bc>/projections/<name>.ex` отвергнут — отрывает проекцию от ReadRepo её таблиц; отказ нормировать
    до первого потребителя отвергнут — у процесса агрегата раскладка уже задана;
  - `Core.Es.Store.append` вне `use Core.Es.Aggregate.Repo.Pg` / `use Core.Repo.Pg.StateStored` — MUST NOT, MAY —
    тестовые дублёры в `test/support`, usecase зовёт только `page_stream`; предупреждение только в moduledoc отвергнуто —
    событие мимо outbox компилятор не ловит;
  - карта остального принята без правок; таблицы «Что можно внутри `Transact.run`» в `10-architecture.md` библиотеки
    нет — запрет `await` и `execute` ложится в абзац CQS `20-agreements.md`.
