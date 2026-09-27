# Правила раскладки приложения-потребителя: инвентаризация и разбор

Исследование на 2026-09-27. core-ex HEAD `3acb3b1`, версия `0.5.0` (`mix.exs:4`).

## Вопрос

Какие правила сейчас задают структуру однокомпонентного Mix-проекта (не umbrella) на `Core.*`:
каталоги и файлы, top-level namespaces, bounded context, `common` и actor-срезы, слои и
направление зависимостей, место агрегатов, событий, команд, кодеков, репозиториев, Schema,
проекций, outbox, процессов, usecases, web-слоя, миграций, тестов и конфигурации,
композиционный корень. Цель — полная инвентаризация и разбор, без решений.

## Методика

Только чтение; `make` / `mix` не запускались, в репозиториях ничего не менялось.

- Ярус потребителя: все 13 файлов `docs/rules/app/*.md` целиком.
- Свод библиотеки: `docs/rules/10-architecture.md` целиком; `00-index.md`, `11-domain.md`,
  `12-errors.md`, `13-repos.md`, `14-events-outbox.md`, `17-otp-concurrency.md`,
  `19-testing.md`, `22-projections.md` — разделы о раскладке потребителя (grep по `lib/my_app`,
  `common`, `otp_app`, `<Aggregate>.…`, `раскладк`, `test/`, `config/`) и их окрестности;
  `DEBT.md` целиком.
- `docs/adr/0006`, `0020` целиком; grep по всем ADR, `CONTEXT.md`, `README.md`.
- `CHANGELOG.md`: раздел `0.5.0` целиком, grep по раскладке во всех разделах; `git show --stat
  e1f94d8`.
- Фикстуры: `fixtures/consumer/**` (дерево, `README.md`, `mix.exs`, `config/config.exs`),
  `test/support/**` (дерево, `defmodule`-структура).
- Код: grep `Module.concat|safe_concat|Module.split` и имён-конвенций по `lib/`; чтение
  `lib/core/config.ex`, `lib/core/es/projection.ex`, `lib/core/es/aggregate/process.ex`,
  `lib/core/es/{event_compat_case,projection_case}.ex`, `lib/core/es/event/tags_case.ex`.
- Линтеры: `scripts/{boundary,layout,rules}_lint.exs` — константы путей и режим `--consumer`.
- Реальные потребители (`../*/mix.exs` с `{:core,`): потребитель A
  (`b4f2347`, `tag: "v0.5.0"` — `mix.exs:51`) прочитан подробно: дерево `lib/`,
  `test/`, `priv/`, `config/`, локальные `docs/rules/{10,13,15}-*.md` и `DEBT.md`. Остальные —
  только дерево каталогов: потребитель C (`branch: "develop"`, `mix.exs:44`), потребитель F
  (`develop`, `:50`), потребитель B (`v0.1.0`, `:53`), потребитель D (`v0.2.0`, `:61`),
  потребитель E (`v0.3.3`, `:60`). Umbrella (`apps_path`) нет ни у одного.

Номера строк в `docs/rules/app/*.md` — `app/NN:строка`; в своде библиотеки — `NN:строка`
(`docs/rules/NN-*.md`). Нумерация модальностей — по `00-index.md:117-130`: текст без
MUST / SHOULD / MAY — «пояснение, а не норма» (`00-index.md:119`).

## 1. Инвентаризация правил структуры

Формат пункта: правило — где — модальность — чем держится механически. Модальность `—` —
модального слова нет.

### 1.1. Namespaces, BC, срезы, слои

- **R1.** Таблица top-level namespaces: `Application`, `Codec`, `Domain.<BC>`, `Outbox`,
  `Projections`, `PromEx`, `ContextFactory`, `DAO`, `MyAppWeb` — app/10:13-26 — `—` — ничем.
- **R2.** Модуль вне таблицы — подсистема приложения либо ошибка слоя — app/10:28-29 — `—` —
  ничем.
- **R3.** `MyApp.Domain.<BC>` ↔ `lib/my_app/domain/<bc>/`; пути — snake_case — app/10:20,
  00:115 — `—` — ничем.
- **R4.** BC = `common` + actor-срезы; состав `<BC>.Common` и `<BC>.<Actor>` — app/10:92-98 —
  `—` — ничем.
- **R5.** Срез, вызываемый не из web, берёт актора у `ContextFactory` — app/10:101-102 — MUST —
  ничем.
- **R6.** Actor-репозиторий — только под свой ACL-фильтр среза — app/10:103-104,
  app/13:115-121 — `—` — ничем.
- **R7.** Имя usecase — `MyApp.Domain.<BC>.<Actor>.Usecases.<Aggregate>` — app/10:108 — `—` —
  ничем.
- **R8.** Mix-таски вне `MyApp.*`, `use Boundary, classify_to: MyApp` — app/10:81 — `—` —
  сборка `boundary` (app/10:88).
- **R9.** Boundary `MyApp`, `MyAppWeb`, `MyApp.Application`, `MyApp.PromEx` — app/10:69-74 —
  `—` — `mix compile --warnings-as-errors`.
- **R10.** `Core.*` в `deps:` boundary не перечислять — app/10:76-77 — MUST NOT — ничем.
- **R11.** App-слой не ссылается на `MyAppWeb` — app/10:78-80 — MUST NOT — сборка `boundary`.
- **R12.** Web не ссылается на `*Repo` и `DAO`, архитектурный тест — app/10:83-86,
  app/19:102 — MUST — тест, который пишет приложение.
- **R13.** Слои Web / Worker → UC → Domain, Repo → Store → DAO; domain без Ecto —
  app/10:189-217 — MUST NOT (web → repo / DAO) — только R12: `Domain` и `Codec` в одном
  boundary (app/10:83-84).
- **R14.** Типовые конфликты имён — таблицей в локальном своде — app/20:129-131 — MUST — ничем.

### 1.2. Композиционный корень и конфигурация

- **R15.** `MyApp.Application` — корень, `:one_for_one`; проверки конфигурации до детей —
  app/10:18,54-65, app/17:15-17 — MUST — ратчет только на `check_singleton!` (app/19:105).
- **R16.** Порядок детей: метрики → БД → кластер → брокер → кеши → очередь и проекции → HTTP —
  app/17:19-29 — `—` — ничем.
- **R17.** Поддерево с внутренним порядком — свой `Supervisor` `:rest_for_one` — app/17:31-32,
  17:15-17 — MUST (в 17) — ничем.
- **R18.** Проекции — один `Core.Es.Projection.Supervisor`, список — `MyApp.Projections.opts/0`
  — app/17:94-96, 22:96-97 — MUST — отказ старта второго дерева (22:118-119).
- **R19.** Процесс агрегата — элемент `{<Aggregate>.Process, enabled: …}` дерева — app/17:143,
  app/13:204 — `—` — `RuntimeError` при вызове (19:510).
- **R20.** `otp_app` — в `config.exs` — app/10:41-42 — MUST — падение сборки `repo!/1`
  (`lib/core/config.ex:171-180`).
- **R21.** Тумблеры и env подсистем — только `config/runtime.exs` — app/17:67-69 — MUST NOT
  (дубль) — ничем.
- **R22.** Ключи под `:my_app` — подмена `<Behaviour>.Pg` и подсистемы — app/10:51-52 — `—` —
  `boundary_lint --consumer` частично.
- **R23.** DI через `Core.Config.repo!/1`, реализация в `<Behaviour>.Pg` — 13:1017-1044,
  app/13:398-409 — MUST — `CompileError` и `boundary_lint --consumer`.
- **R24.** `MyApp.DAO` — `use Core.DAO`, единственный `Ecto.Repo` — app/10:25,36 — MUST —
  `Core.Config.validate!/0` (экспорт `transact/1`).

### 1.3. Раскладка домена

- **R25.** Всё агрегата — в его каталоге; `<aggregate>_repo.ex` не бывает — app/13:16-17 — `—`
  — ничем.
- **R26.** Дерево state-stored: `repo`, `repo/pg{,/schema,/specs}`, `view`, `read_repo{,/pg…}`,
  `event{,/<name>,/codec}`, `outbox` — app/13:19-34 — `—` — частично, см. §3.
- **R27.** Добавка event-sourced: `cmd{,/<name>}`, `process`, `<name>_key`,
  `common/projection.ex`, `projector.ex` — app/13:36-46 — `—` — ничем.
- **R28.** Write-схема — под `Repo.Pg.Schema`, read — под `ReadRepo.Pg.Schema` — app/13:48-49,
  13:71,293 — MUST — ничем.
- **R29.** Кодек событий и `Outbox` — в `common/<aggregate>/` — app/13:52 — `—` — ничем.
- **R30.** Repo, схема, View — в `Common`, пока пишут несколько акторов — app/13:53-54 — `—` —
  ничем.
- **R31.** В срезе `<aggregate>/` — namespace actor-domain — app/13:55-56 — `—` — ничем.
- **R32.** View — в каталоге агрегата, не под репозиторием — app/13:57-58 — `—` — ничем.
- **R33.** Событие и команда — по файлу; вложенные `defmodule` в `event.ex` / `cmd.ex` —
  app/13:63-70 — MUST / MUST NOT — ничем (`CHANGELOG.md:16-17`).
- **R34.** Репозиторий event-sourced агрегата — один, в common — 13:621-624, app/13:120-121 —
  MUST — ничем.
- **R35.** Проекция — одна на BC, `common/projection.ex`; строки —
  `<Aggregate>.ReadRepo.Pg.Projector` — app/13:337-339 — `—` — ничем.
- **R36.** Таблицу read-модели пишет ровно одна проекция — 22:70 — MUST — `ProjectionCase`
  (`clear/0`).
- **R37.** Read-Specs — `read_repo/pg/specs.ex`; ACL `default/1` — в Specs своего среза —
  app/13:368-377 — `—` — ничем.
- **R38.** Каталог — `MyApp.Domain.<BC>.Common.<Aggregate>.Errors`, `ns` на агрегат —
  app/12:17,32 — `—` — сборка сверяет коды, не место (12:280-281).
- **R39.** Каталог не зависит от usecases и репозиториев — app/12:50 — MUST NOT — ничем.
- **R40.** Prim — вложенные модули владельца; namespace «все примитивы» запрещён —
  app/11:97-100, 11:149-165 — MUST NOT (вторая часть) — ничем.
- **R41.** Профилей Codec — ровно два; фасады и реестр `MyApp.Codec.plugins/0` —
  app/11:17-22,35-46 — `—`, MUST (плагин в реестре) — предупреждение сборки фасада.
- **R42.** Модуль ключа `<Aggregate>.<Name>Key` — `common/<aggregate>/<name>_key.ex` —
  app/13:43,263-266 — `—` (путь) — ничем.
- **R43.** Namespace UUIDv5 — одна функция приложения (`MyApp.StreamID.namespace()`) —
  app/13:224-226 — MUST — ничем.
- **R44.** Процесс агрегата — `common/<aggregate>/process.ex` — app/13:42,200, 13:836-838 —
  `—` — ничем.
- **R45.** Кеш: `<ReadRepo>.Cached`, `.Invalidator`, backend `<ReadRepo>.Cache` — app/13:29,
  app/16:3,47,66,85 — `—` — контрактный тест (19:428-429).
- **R46.** Имена таблиц, схем, soft delete — app/13:411-419 — `—` — ничем.

### 1.4. Web, миграции, тесты, наблюдаемость, свод

- **R47.** Web: `<api>/<version>/<resource>/{controller,schemas}`, общие схемы, презентеры,
  плаги — app/15:27-41 — `—` — ничем.
- **R48.** Версия API — соседний каталог (`v1`, `v2`) — app/15:20-21 — `—` — ничем.
- **R49.** Ответ 202 собирает один хелпер `MyAppWeb.Helper.Projection` — app/15:136-143 — `—`,
  MUST NOT (`await` внутри хелпера) — сборка (`await/3`).
- **R50.** Миграции — `priv/dao/migrations`, модули `MyApp.DAO.Migrations.*` — app/18:3,35,115
  — `—` — ничем.
- **R51.** DDL библиотеки — делегирующая миграция, своей копии колонок нет — app/18:110-131 —
  MUST NOT (копия) — ничем.
- **R52.** Case-модули `MyApp.DataCase`, `MyAppWeb.ConnCase`; `test/support/data_case.ex` —
  app/19:14-20,38 — MUST (sandbox) — ничем.
- **R53.** Состав `test/support`: `*_fixture`, `*_seed`, `*_contract`, `fixtures/events/**` —
  app/19:46-54 — `—` — ничем.
- **R54.** Ратчеты и их пути: `test/my_app/enum_docs_test.exs`, `…/es/event_tags_test.exs`,
  `…/repo/constraint_errors_test.exs` — app/19:93-117 — MUST (наличие) — ничем.
- **R55.** Golden-фикстуры `test/support/fixtures/events/<тип>/<тег>.json` — 14:183,
  app/14:49-50 — MUST (наличие) — `EventCompatCase`.
- **R56.** Тест-модули домена — `test/my_app/domain/<bc>/common/…` — 19:131,138,253,278 — `—`
  (пути только в примерах) — ничем.
- **R57.** `lib/my_app/prom_ex*`, `MyApp.PromEx.plugins/0`, провайдеры `MyApp.PromEx.*` —
  app/21:3,31,35 — `—` — ратчет состава (app/21:52).
- **R58.** `lib/my_app/metrics_server.ex` — app/21:3 (только область) — `—` — ничем.
- **R59.** `CONTEXT.md` в корне: глоссарий и перечень компонентов — app/20:135,172 — MUST —
  ничем.
- **R60.** Локальный свод `docs/rules/00-index.md`, `AGENTS.md`, скиллы — app/00:155-223 —
  MUST — `rules_lint.exs --consumer`.
- **R61.** Состав `make` = `.pre-commit-config.yaml`; скрипты — из `deps/core/scripts/` —
  app/20:24,47-49 — MUST — ничем.

## 2. Эталонное дерево потребителя

Узел без явного пути в правилах, выведенный из имени модуля, помечен `≈`. Узел, которого нет
ни в пути, ни в имени модуля, в дерево не включён (см. §4.3).

```text
<root>/
├── AGENTS.md, CLAUDE.md → AGENTS.md          app/00:155-210; scripts/rules_lint.exs:28-29
├── CONTEXT.md                                app/20:135,172
├── Makefile, .pre-commit-config.yaml         app/20:24
├── config/
│   ├── config.exs    config :core (otp_app, dao, codec, telemetry_prefix); DI-подмены; кеш
│   │                 10:74-84; app/10:41-43; 13:1035; app/16:119-127
│   ├── runtime.exs   тумблеры и env: OUTBOX_*, ES_PROJECTIONS_*, кеш, фоновые задачи
│   │                 app/17:67-69,97-98; app/14:147-150; app/17:184
│   └── test.exs      overlay: outbox off, Process enabled: false, await: :inline, PromEx off
│                     app/14:172-173; 19:314,513-515; app/21:62; app/16:129-130
├── docs/rules/{00-index.md, NN-*.md, DEBT.md} app/00:184-191
├── lib/
│   ├── my_app/
│   │   ├── application.ex                    app/10:18
│   │   ├── dao.ex                            app/10:25; app/13:3
│   │   ├── context_factory.ex                app/10:24
│   │   ├── projections.ex                    app/10:23
│   │   ├── prom_ex.ex ≈, prom_ex/*.ex ≈      app/10:24 (`lib/my_app/prom_ex*`); app/21:31,35
│   │   ├── metrics_server.ex                 app/21:3
│   │   ├── stream_id.ex ≈                    app/13:226 (только имя `MyApp.StreamID`)
│   │   ├── codec.ex ≈                        app/11:36 (`MyApp.Codec.plugins/0`)
│   │   ├── codec/{internal,external}.ex ≈    app/10:19; app/11:35
│   │   ├── codec/prim/{internal,external}.ex ≈  app/11:21-22
│   │   ├── outbox/                           app/10:22 (writer + поллер + cleaner)
│   │   └── domain/<bc>/                      app/10:20
│   │       ├── common/
│   │       │   ├── projection.ex             app/13:44,337
│   │       │   └── <aggregate>/
│   │       │       ├── errors.ex ≈           app/12:3,32
│   │       │       ├── repo.ex, repo/pg.ex   app/13:20-21,41
│   │       │       ├── repo/pg/{schema.ex,schema/*.ex,specs.ex}   app/13:22-24 (state-stored)
│   │       │       ├── view.ex               app/13:25,57
│   │       │       ├── read_repo.ex, read_repo/pg{,/schema.ex,/specs.ex}  app/13:26-28
│   │       │       ├── read_repo/pg/projector.ex                  app/13:45
│   │       │       ├── read_repo/{cached,invalidator}.ex          app/13:29
│   │       │       ├── read_repo/supervisor.ex ≈                  app/16:3 (только область)
│   │       │       ├── event.ex, event/<name>.ex, event/codec.ex  app/13:30-32
│   │       │       ├── outbox.ex             app/13:33
│   │       │       ├── cmd.ex, cmd/<name>.ex app/13:39-40 (event-sourced)
│   │       │       ├── process.ex            app/13:42 (опционально)
│   │       │       └── <name>_key.ex         app/13:43 (опционально)
│   │       └── <actor>/
│   │           ├── usecases/<aggregate>.ex ≈ app/10:108 (только имя модуля)
│   │           └── <aggregate>/              app/13:55-56 (actor-domain, actor-repo, View)
│   ├── my_app_web/
│   │   ├── <api>/<version>/<resource>/{controller.ex,schemas/*.ex}  app/15:30-31
│   │   ├── <api>/<version>/schemas/*.ex      app/15:32
│   │   ├── presenters/*.ex, plugs/*.ex       app/15:33-34
│   │   ├── {error_mapper,fallback_controller}.ex  app/15:35
│   │   └── helper/projection.ex ≈            app/15:137 (только имя `MyAppWeb.Helper.Projection`)
│   └── (mix-таски)                           app/10:81 — только «вне `MyApp.*`», пути нет
├── priv/dao/migrations/*.exs                 app/18:3,23-26
└── test/
    ├── support/data_case.ex                  app/19:38
    ├── support/{*_fixture,*_seed,*_contract}.ex, дублёры   app/19:48-53
    ├── support/fixtures/events/<тип>/<тег>.json            app/19:54; 14:183
    ├── my_app/enum_docs_test.exs             app/19:108
    ├── my_app/es/event_tags_test.exs         app/19:111
    ├── my_app/repo/constraint_errors_test.exs  app/19:115
    └── my_app/domain/<bc>/common/<aggregate>/event_compat_test.exs,
        …/common/projection_case_test.exs, …/<aggregate>/<name>_key_test.exs   19:131,138,253,278
```

## 3. Конвенции имён, зашитые в код библиотеки

Формат: что выводится ← из чего — где в коде — что при нарушении.

- `<Behaviour>.Pg` ← имя behaviour в `Config.repo!/1` — `lib/core/config.ex:83-94,169` —
  `CompileError`, если нет ни модуля, ни ключа (`:99-110`).
- `Core.Outbox.Repo.Pg` ← `Core.Outbox.Repo` — `lib/core/config.ex:122` — отказ
  `validate!/0` (`:153-157`).
- `<Aggregate>.Event.Codec` ← модуль события `<Aggregate>.Event.<Name>` в `events:` проекции —
  `lib/core/es/projection.ex:385,436` — `CompileError` «кодек … не найден» (`:402-408`).
- `<X>.Codec` ← модуль-семейство `<X>` в `events:` — `lib/core/es/projection.ex:425-430` —
  `CompileError` «семейство событий» (`:387-389`).
- Модуль агрегата для `await/3` ← кодек `…<Aggregate>.Event.Codec` без `Event.Codec` —
  `lib/core/es/projection.ex:282-293` — молча: clause `await/3` не появляется
  (комментарий `:282-283`).
- `<View>.Codec` ← модуль `use Core.View` — `lib/core/view/dumper.ex:29` — генерируется.
- Имена процессов `<Process>.Registry`, `<Process>.Supervisor` ← модуль процесса агрегата —
  `lib/core/es/aggregate/process.ex:195-196,258` — генерируются.
- Реализация `repo:` процесса агрегата ← `Config.repo!(behaviour)` —
  `lib/core/es/aggregate/process.ex:192` — как у `repo!/1`.
- `test/support/fixtures/events/<тип>` ← `type:` кодека —
  `lib/core/es/event_compat_case.ex:42-43,55` — провал теста; путь меняет опция `fixtures:`.
- `test/support/fixtures/events` ← корень проекта — `lib/core/es/projection_case.ex:39-40,52` —
  путь меняет опция `fixtures:`.
- Набор проверяемых модулей ← `Application.spec(otp_app, :modules)` —
  `lib/core/es/event/tags_case.ex:235-237`, `lib/core/enum/docs_case.ex:110-111`,
  `lib/core/repo/constraint_errors_case.ex:17` — провал «приложение не загружено».
- DI-ключ «руками» ← последний сегмент `Repo` / `ReadRepo` ключа `compile_env` —
  `scripts/boundary_lint.exs:24,113-125` — нарушение линтера.

Следствия, видимые только по коду:

- Раскладка «кодек событий рядом с событиями, агрегат — родитель `Event`» (app/13:30-32, без
  модальности) держится компиляцией проекции и молчаливым отсутствием `await/3`. Код ссылается
  на `11-domain.md` как на источник этой раскладки (`lib/core/es/projection.ex:282,432`), но в
  `11-domain.md` раскладки нет: она в `app/13-repos.md` (см. Д7).
- Каталог golden-фикстур привязан к `type:` кодека, а не к пути модуля агрегата.
- Какие модули проверяют ратчеты, решает принадлежность к OTP-приложению, а не каталог.

## 4. Находки

### 4.1. Дубли и расхождения формулировок

- **Д1. Место View и ReadRepo: common или срез.** Ярус кладёт их в common:
  `<bc>/common/<aggregate>/view.ex` и `read_repo.ex` (app/13:25-27), «лежат в `Common`, пока
  агрегат читают и пишут несколько акторов» (app/13:53-54). В других местах они стоят в срезе:
  - `defmodule MyApp.Domain.<BC>.<Actor>.<Aggregate>.View` (13:88);
  - `behaviour: MyApp.Domain.<BC>.<Actor>.<Aggregate>.Repo` / `.ReadRepo` (13:226,272);
  - «представлением (`<Actor>.<Aggregate>.View`)» (11:534);
  - `config :my_app, MyApp.Domain.<BC>.<Actor>.<Aggregate>.ReadRepo` (app/16:121-124);
  - «у роли свои репозиторий записи, представление и операции» (`CONTEXT.md:101-103`).

  Последствие видно у потребителя A. Его `docs/rules/DEBT.md:57-68` записывает View в `Common` как
  отступление: «`13-repos.md` относит View к actor-срезу». По ярусу это и есть норма.
- **Д2. Пример DI без `Common`.** `@repo Config.repo!(MyApp.Domain.Orders.Order.Repo)`
  (13:1026,1036,1051-1052; `README.md:254-262`). В остальных местах —
  `MyApp.Domain.<BC>.Common.<Aggregate>.Repo`: app/13:20, `lib/core/config.ex:71`,
  `docs/adr/0006-repo-impl-resolved-by-convention.md:13`.
- **Д3. Репозиторий уровня BC.** Свод библиотеки называет behaviour `<BC>.Common.Repo` и файл
  `repo.ex` для `Repo` (common) (13:14,32). В ярусе репозиторий бывает только у агрегата
  (app/13:16-17,20).
- **Д4. Гранулярность и имя проекции.** Ярус: «модуль проекции — один на BC, в
  `common/projection.ex`» (app/13:337). Примеры в других местах:
  - `MyApp.Domain.Accounts.AccountList.Projection` (`README.md:312-315`);
  - `AccountList.Projection`, `AccountListV2.Projection` (22:171,244-248; 17:34);
  - в прошлых выпусках — `<BC>.<Actor>.AccountList.Projection` (`CHANGELOG.md:1644,1793`).

  «Новая проекция тремя выкладками» (22:244-248) заводит второй модуль проекции рядом с первым.
  Как это сочетается с «одной на BC», свод не говорит.
- **Д5. Имя модуля миграций.** `MyApp.DAO.Migrations.*` (app/18:35,115) против
  `MyApp.Repo.Migrations.*` (`README.md:201,218,234`).
- **Д6. Namespace без `Domain`.** `{MyApp.<BC>.Subscribe, …}` (app/17:49, пример «плохо»).
- **Д7. Ссылка на несуществующую раскладку.** Код и CHANGELOG ссылаются на «раскладку
  `11-domain.md`» для `<Aggregate>.Event.Codec`: `lib/core/es/projection.ex:282,432`,
  `CHANGELOG.md:1705`. В `11-domain.md` есть только имя модуля (11:306,574), а раскладка — в
  app/13:30-32. Так же 12:283-284 обещает «путь» каталога в app/12 «Каталоги агрегатов», но там
  только имя модуля (app/12:32).
- **Д8. Состав common в двух местах расходится.** Таблица app/10:97 даёт `<BC>.Common`
  «агрегаты, Prim, события, кодеки событий, outbox-маппинг, репозитории и схемы». View,
  read-репозиториев, проекции, процесса и модуля ключа, которые app/13:25-46 кладёт в common,
  в ней нет.
- **Д9. Область файла шире раскладки.** app/16:3 включает `read_repo/supervisor.ex`, раскладка
  app/13:29 — только `{cached,invalidator}.ex`. app/12:3 — `lib/my_app/domain/**/errors.ex`,
  в раскладке app/13:19-46 файла `errors.ex` нет.

### 4.2. Противоречия: правило против фикстур, потребителя и кода

- **П1. «По файлу на событие и команду» не выполняется в фикстурах библиотеки.** Норма — MUST
  (app/13:63-70). `fixtures/consumer` переведён коммитом `e1f94d8` (`git show --stat`: 39
  файлов). `test/support` не переведён:
  - события вложены в `test/support/es_fixture/account/event.ex:10,33,56,65,74`;
  - команды вложены в модуль агрегата: `test/support/es_fixture/account.ex:43-90`,
    `test/support/es_fixture/catalog.ex:17-20`;
  - события вложены в `test/support/event_fixture.ex:35-63`.

  Это фикстуры библиотеки, а не код потребителя. Но исследование 02 собирало потребителя
  «по образцу `test/support/es_fixture`»
  (`.scratch/es-type-safety/research/02-core-es-blind-spots.md`, «Потребитель»).
- **П2. Prim отдельными файлами.** Правило: «Prim объявляются вложенными модулями внутри
  владельца» (app/11:97-98), образец — `defmodule` внутри агрегата (11:149-165). У потребителя A:
  - `common/claim_act/id.ex`, `common/item_inspection/id.ex`, `…/status.ex` — отдельные файлы.
    Причина записана в `lib/app_a/domain/acceptance/common/claim_act/id.ex:5`: «Живёт в
    отдельном модуле, а не внутри агрегата: приемка ссылается на акт…»;
  - Prim уровня BC без агрегата-владельца: `common/measure/{weight,quantity,…}.ex`,
    `common/full_name.ex`, `common/comment.ex`.

  В `fixtures/consumer` `delivery_id.ex`, `user_id.ex`, `inspection_id.ex` лежат в корне
  `lib/consumer/`. Правило не уточняет, что значит «вложенный»: namespace или физически внутри
  файла.
- **П3. BC — не только common и срезы.** «Bounded context делится на `common` и actor-срезы»
  (app/10:92). У потребителя A в корне BC `perms` лежат `declare.ex`, `errors.ex`, `namespace.ex`,
  `ops.ex`, `perm_checker.ex` и `registry/`. Потребитель A описывает это в локальной таблице namespaces
  отдельной строкой `Domain.Perms` (`docs/rules/10-architecture.md:23` потребителя A). У потребителя C срезы BC
  `addresses` названы по функции: `importer`, `indexer`, `public` (дерево
  `lib/app_c/domain/addresses/`).
- **П4. Зависимость common → срез.** Раскладка кладёт проектор в
  `common/<aggregate>/read_repo/pg/projector.ex` (app/13:45). У потребителя A `users/common/projection.ex`
  зовёт `Admin.User.ReadRepo.Pg.Projector` из среза `admin` (`:21,40-49`). Направление
  зависимостей между common и срезами свод не нормирует.
- **П5. Дерево тестов.** Примеры свода библиотеки — `test/my_app/domain/…` (19:131,138,253,278).
  У потребителя A — `test/app_a/domains/…` (множественное число), у потребителя C — `test/app_c/domain/…`.
- **П6. Web-слой потребителя A отличается от яруса.** Ярус: `lib/my_app_web/{error_mapper,
  fallback_controller}.ex` и общие схемы в `<api>/<version>/schemas/` (app/15:32,35). У потребителя A:
  - `lib/app_a_web/controllers/fallback_controller.ex` и `controllers/error_json.ex`;
  - общие схемы — в `lib/app_a_web/schemas/` поперёк поверхностей;
  - каталоги `parse/` и `helper/`.

  Локальный свод потребителя A переписывает раскладку со своими путями
  (потребителя A `docs/rules/15-web-api.md:26-40`). Строки в `DEBT.md` потребителя A об этом нет (grep по
  `раскладк`).
- **П7. Фикстура-потребитель без BC.** `fixtures/consumer/lib/consumer/<aggregate>/…`: нет
  `domain/<bc>/common/`, проекция — `lib/consumer/projection.ex`, usecase —
  `lib/consumer/usecase.ex`. Фикстура держит только типы: «Credo и линтеры библиотеки
  фикстуру не проверяют» (`fixtures/consumer/README.md:21-22`). В репозитории библиотеки нет
  ни одного живого образца раскладки BC / common / срез.
- **П8. Норма раскладки держится кодом частично и молча** (см. §3).
  - `<Aggregate>.Event.Codec` не рядом с событиями — `CompileError` проекции.
  - Кодек с другим именем — `await/3` без clause, без ошибки (`lib/core/es/projection.ex:282-283`).
  - Сама норма (app/13:30-32) модальности не имеет.

### 4.3. Пробелы: куда класть X

Свод не отвечает (ни пути, ни имени модуля — либо только имя):

- **Пр1. Файл самого агрегата.** `<bc>/common/<aggregate>.ex` нет ни в app/13:19-46, ни в
  app/11. Есть только имя `MyApp.Domain.<BC>.Common.<Aggregate>` (11:152).
- **Пр2. `<Aggregate>.Codec`** — entity-плагин агрегата (11:386-391; `CONTEXT.md:65-67`), в
  раскладке нет. У потребителя A — `common/<aggregate>/codec.ex`.
- **Пр3. Каталог ошибок** — только имя и glob (app/12:3,32); каталог уровня BC (у потребителя A
  `perms/errors.ex`) правилом «свой `ns` у каждого агрегата» (app/12:17) не покрыт.
- **Пр4. Enum и Prim отдельными файлами, общие значения BC** — см. П2.
- **Пр5. Usecases.** Только имя модуля (app/10:108); файл `<bc>/<actor>/usecases/<aggregate>.ex`
  выводится из имени. Так у потребителя A.
- **Пр6. Воркеры (Oban), подписчики брокера, DLQ-writer, их супервизоры.** Путей нет
  (app/14:92-109; app/17:34-53,178-186). У потребителя A — `<bc>/system/workers/*.ex` и
  `notifications/common/subscriber{,/supervisor}.ex`.
- **Пр7. Actor-domain и read-путь среза.** Нормировано только «каталог `<aggregate>/` в срезе —
  namespace actor-domain» (app/13:55-56). Неясно:
  - где модуль `<Actor>.<Aggregate>` с операциями (пример `Actor.Agg.mutate`, app/10:160);
  - где проектор read-модели среза — у потребителя A `users/admin/user/read_repo/pg/projector.ex`.
- **Пр8. Инфраструктурные швы и подсистемы.** Сказано только «подсистема приложения
  (актуализация, хранилище, интеграция)» (app/10:28-29) и «шов … резолвится `compile_env`»
  (app/13:405-406). Путей и имён нет: объектное хранилище, внешние сервисы, адаптеры каналов,
  Kafka-клиент `use Klife.Client` «остаются в app-слое» (10:140-142). У потребителя A: `lib/app_a/storage/`,
  `notifications/common/channel/adapters/`; у потребителя C — `lib/app_c/<источник>/`.
- **Пр9. Аксессор текущего пользователя.** `CurrentUser` (app/10:111; app/11:123) — места нет.
  У потребителя A это отдельный BC `auth/common/current_user.ex`, у потребителя F — `auth/common/`.
- **Пр10. Модули уровня BC вне common и срезов** (политики, реестры) — см. П3.
- **Пр11. Зависимости между BC.** Ссылка на Prim чужого BC показана как штатная
  (`by: MyApp.Domain.Users.Common.User.ID`, app/13:83,98). Мельче `MyApp` boundary не режет
  (app/10:83-84), и о допустимых направлениях между BC правил нет.
- **Пр12. Проекция на события нескольких BC** и вторая проекция при пересборке по новой таблице
  (22:244-248): при «одной на BC в `common/projection.ex`» (app/13:337) место не задано.
- **Пр13. Web.** Для этих модулей ни пути, ни имени нет:
  - `ApiSpec` поверхности (app/15:18-19 требует «свой `ApiSpec`»);
  - `router.ex`, `endpoint.ex` (только в области app/15:3-4);
  - модули разбора тела «отдельным модулем» (app/15:64-65);
  - `MyAppWeb.Response.Code` (10:202);
  - вложенные ресурсы и группы (у потребителя A `system_api/v1/security/*`, `users/profile/`);
  - схемы, общие для нескольких поверхностей.

  «Поднимается в общий каталог» (app/15:39-40) называет только каталог версии одной
  поверхности (app/15:32).
- **Пр14. Mix-таски** — только namespace (app/10:81). У потребителей A и C — `lib/mix/tasks/`.
- **Пр15. Модули, которые нормы называют, а таблица namespaces (app/10:13-26) — нет:**
  `MyApp.StreamID` (app/13:226), `lib/my_app/metrics_server.ex` (app/21:3). `MyApp.Release`
  есть у всех шести потребителей (`lib/<app>/release.ex`); grep по
  `docs/rules` его не находит.
- **Пр16. Тесты.**
  - Правила «дерево тестов повторяет `lib/`» нет — есть пути в примерах (П5).
  - Нет пути архитектурного теста (app/10:85): у потребителя A — `test/app_a_web/architecture_test.exs`, у
    потребителя C — `test/app_c/architecture_test.exs`.
  - Нет пути `ConnCase`.
- **Пр17. Конфигурация.** Описания раскладки `config/` одним местом нет: роли `config.exs`,
  `runtime.exs` и `test.exs` рассеяны по восьми файлам (§2). `dev.exs` / `prod.exs` не
  упомянуты (grep по `docs/rules`).

### 4.4. Неявное допущение «один проект = один `otp_app`» (umbrella)

Umbrella не цель. Ниже — места, где свод или код молча предполагают одно OTP-приложение.
Явные упоминания umbrella: `docs/rules/app/19-testing.md:112-113` («зонтичное приложение
перечисляет в `otp_app:` все приложения одной базы») и
`docs/adr/0020-event-tag-ratchet.md:49`.

- **У1. Один `otp_app` на всё.** `config :core, otp_app:` — один атом (10:76;
  `lib/core/config.ex:17-19,56`). `repo!/1` читает `compile_env` только этого приложения
  (`lib/core/config.ex:84-89`). DI-ключи всех приложений umbrella должны лежать под одним
  атомом — свод это не обсуждает.
- **У2. Один DAO и один фасад.** `dao:` и `codec:` — по одному значению (10:77-78). Кроме того,
  «единственный `Ecto.Repo`» (app/10:25) и «профилей Prim — ровно два» (app/11:17).
- **У3. Одно дерево проекций на ноду.** Второе дерево — отказ старта (22:96-97,119), список —
  одна функция `MyApp.Projections.opts/0` (app/17:94-96). Проекции всех приложений должны
  собираться в одном корне.
- **У4. Ратчеты.** `TagsCase` принимает список приложений (`tags_case.ex:134-147`, ADR-0020:49).
  `DocsCase` и `ConstraintErrorsCase` — только атом (`docs_case.ex:68`,
  `constraint_errors_case.ex:102`). Расхождение принято сознательно (ADR-0020:63-64). Хранилище
  событий — одно на базу (13:903).
- **У5. Пути от корня проекта**, равного корню приложения:
  - в своде: `lib/my_app/`, `lib/my_app_web/` (app/10:13-26; app/15:30-35), `test/my_app/`
    (app/19:108-115), `priv/dao/migrations` (app/18:3);
  - в коде: корень фикстур `test/support/fixtures/events` (`event_compat_case.ex:55`,
    `projection_case.ex:52`).
- **У6. Линтеры считают от cwd.**
  - `boundary_lint --consumer` по умолчанию смотрит `["lib"]` (`scripts/boundary_lint.exs:17`).
  - `layout_lint` — `lib/**`, `test/support/**` (`scripts/layout_lint.exs:16-17`).
  - `rules_lint` — `deps/core/docs/rules`, `AGENTS.md` (`scripts/rules_lint.exs:23-29`).

  В umbrella `deps/` лежит в корне, а `lib/` — в `apps/*/`. Из какого каталога запускать —
  не описано.
- **У7. Boundary: web и app — один Mix-проект.** Таблица boundary (app/10:69-74) это
  предполагает. Аргумент «чужое OTP-приложение его проверками не покрыто» (app/10:76-77) в
  umbrella относился бы уже к своим приложениям.
- **У8. Один композиционный корень и один поллер.** `MyApp.Application` (app/10:18;
  app/17:15); поллер outbox — один на топик-группу (app/14:70-90),
  `config :core, Core.Outbox, poller_name:` — одно значение (10:82).
- **У9. Плейсхолдеры** в единственном числе: `MyApp` — «корневой namespace», `:my_app` — «его OTP
  app atom» (00:109-110).
- **У10. Префиксы.** Префикс метрик — `otp_app` из `use PromEx` (app/21:24-28);
  `telemetry_prefix` по умолчанию `[otp_app()]` (10:80).

### 4.5. Правила без механической проверки

- **Б1. Почти вся раскладка — не норма в смысле свода.** Нормы пишутся модальными словами,
  остальное — «пояснение, а не норма» (00:119). Модальности нет у:
  - таблицы namespaces (R1);
  - деления BC (R4);
  - дерева файлов агрегата (R25-R27, R29-R32);
  - раскладки web (R47), миграций (R50) и путей тестов (R54, R56).

  Модальные — только отдельные пункты: R28, R33, R34, R40.
- **Б2. MUST / MUST NOT без проверки:**
  - R5 (актор от `ContextFactory`), R21 (дубль тумблеров), R28 (где лежат схемы);
  - R33 — по файлу на событие; `CHANGELOG.md:16-17`: «сборка кода на старой раскладке не
    ломается»;
  - R34 (один ES-репозиторий), R39 (зависимости каталога), R40 (namespace примитивов);
  - R43 (одна функция namespace UUIDv5), R52 (sandbox `DataCase`);
  - R54 и R55 — наличие ратчетов и тест-модулей: сами кейсы работают, если подключены, но
    обязательность подключения держит ревью (ADR-0020:57-58);
  - R59 (`CONTEXT.md`), R61 (состав `Makefile` = pre-commit).
- **Б3. Требование к новым правилам не выполнено для раскладки.** «Новое правило MUST приносить
  … пример „плохо / хорошо“, либо строку `Проверяется: …`» (app/00:231-232). У «Раскладки» в
  app/13:14-59, app/15:27-41 и у таблицы app/10:13-29 нет ни того, ни другого. Пример есть
  только у R33 (app/13:75-111).
- **Б4. Что держится механически:**
  - `<Behaviour>.Pg` (R23) — `CompileError` + `boundary_lint --consumer`;
  - boundary между `MyApp` и `MyAppWeb` (R9, R11) — сборка;
  - web → Repo / DAO (R12) — тест, который пишет само приложение;
  - `<Aggregate>.Event.<Name>` → `<Aggregate>.Event.Codec` — сборка проекции (§3);
  - одно дерево проекций (R18) — старт;
  - локальный свод (R60) — `rules_lint --consumer`.

## 5. Открытые вопросы

1. Раскладка — норма или конвенция? Если норма, чем её держать:
   - модальностью в тексте;
   - скриптом в `deps/core/scripts/` (сверка пути файла с именем модуля и с деревом app/13);
   - case-модулем по образцу `TagsCase` / `DocsCase` над `Application.spec(otp_app, :modules)`;
   - только ревью.
2. Место View и ReadRepo по умолчанию: common (app/13:25-27,53) или срез (13:88,226,272;
   11:534; app/16:121-124; `CONTEXT.md:101-103`)? От ответа зависит, какие тексты править и
   снимать ли строку `DEBT.md:57-68` у потребителя A.
3. Гранулярность проекции: «одна на BC в `common/projection.ex`» (app/13:337) или «одна на
   read-модель» (`AccountList.Projection` — `README.md`, 22)? Где живёт вторая проекция при
   пересборке по новой таблице (22:244-248) и проекция на события нескольких BC?
4. Prim и Enum: «вложенный» — это namespace или физически внутри файла агрегата? Разрешены ли
   отдельные файлы `id.ex` / `status.ex` (у потребителя A, причина — циклы компиляции) и общие значения BC
   (`common/measure/*`)?
5. Модули уровня BC вне common и срезов (`perms/*.ex` у потребителя A) — допустимы? Если да, как называется
   этот уровень? Функциональные срезы (`importer` / `indexer` / `public` у потребителя C) — это actor-срезы?
6. Куда кладутся воркеры, подписчики, DLQ-writer и их супервизоры: в срез `system`
   (как у потребителя A), в common, в top-level подсистему? Нужно ли имя среза `system` в своде?
7. Допустима ли зависимость common → срез (у потребителя A проекция common зовёт проектор `admin`)? И
   зависимость BC → BC: только идентификаторы или любые модули?
8. Где файл агрегата, `<Aggregate>.Codec`, `errors.ex`, usecases, actor-domain: достроить
   дерево в app/13 или вывести общее правило «файл = имя модуля в snake_case»?
9. Дерево тестов: повторяет `lib/` один в один (`test/my_app/domain/…`) или свободно
   (`domains` у потребителя A)? Путь архитектурного теста и `ConnCase`?
10. Web: где общие схемы нескольких поверхностей, `fallback_controller.ex` (корень или
    `controllers/`), `parse/` и `helper/`, `api_spec.ex`, вложенные ресурсы?
11. Таблица top-level namespaces: дополнить `StreamID`, `MetricsServer`, `Release`,
    `Mix.Tasks.*` или оставить открытой («подсистема приложения», app/10:28-29)?
12. Umbrella: записать ли в своде явное допущение «один Mix-проект = один `otp_app` = один DAO =
    один корень», или привести `DocsCase` / `ConstraintErrorsCase` к списку, как `TagsCase`?
13. Фикстуры библиотеки (`test/support/es_fixture`, `event_fixture.ex`) — перевести на
    раскладку потребителя (П1) или записать исключение? Нужен ли в репозитории библиотеки живой
    образец раскладки BC / common / срез (П7)?
14. Примеры с `MyApp.Domain.Orders.Order.Repo` и `MyApp.Repo.Migrations.*` (`README.md`, 13) —
    свести к форме яруса?

## Источники

1. `docs/rules/app/00-index.md` — стандарт яруса, критерий «сюда или в локальный свод», доставка.
2. `docs/rules/app/10-architecture.md` — namespaces, обязательства, boundary, срезы, usecases,
   слои.
3. `docs/rules/app/11-domain.md` — профили Codec, реестр плагинов, Prim и Enum, `ContextFactory`.
4. `docs/rules/app/12-errors.md` — `ns` и каталоги агрегатов.
5. `docs/rules/app/13-repos.md` — раскладка агрегата, события и команды, проекции, DI.
6. `docs/rules/app/14-events-outbox.md` — теги, outbox, подписчики, конфигурация.
7. `docs/rules/app/15-web-api.md` — раскладка web, хелпер ожидания проекции.
8. `docs/rules/app/16-caching.md` — `.Cached`, `.Invalidator`, конфигурация подмены.
9. `docs/rules/app/17-otp-concurrency.md` — дерево, порядок детей, `MyApp.Projections`.
10. `docs/rules/app/18-migrations.md` — путь и имя миграций, таблицы библиотеки.
11. `docs/rules/app/19-testing.md` — case-модули, `test/support`, ратчеты, umbrella (`:112-113`).
12. `docs/rules/app/20-agreements.md` — пайплайн, алиасы, `CONTEXT.md`.
13. `docs/rules/app/21-observability.md` — PromEx, сервер метрик.
14. `docs/rules/00-index.md` — плейсхолдеры (`:105-115`), модальность (`:117-130`).
15. `docs/rules/10-architecture.md` — инвариант, контракт `config :core` (`:72-91`).
16. `docs/rules/11-domain.md` — Prim вложенными модулями (`:149-165`), кодеки (`:296-391`),
    команда (`:513-529`), агрегат против View (`:531-544`).
17. `docs/rules/12-errors.md` — каталог агрегата (`:262-284`).
18. `docs/rules/13-repos.md` — слои и пути (`:10-33`), View (`:79-140`), ES-репозиторий
    (`:540-640`), процесс (`:833-850`), хранилище (`:901-930`), DI (`:1011-1063`).
19. `docs/rules/14-events-outbox.md` — golden-фикстуры (`:181-200`).
20. `docs/rules/17-otp-concurrency.md` — дерево процессов (`:10-38`).
21. `docs/rules/19-testing.md` — пути тест-модулей в примерах.
22. `docs/rules/22-projections.md` — объявление (`:10-33`), одна таблица — одна проекция
    (`:70`), дерево (`:94-119`), `await` (`:129-140`), новая проекция (`:244-248`).
23. `docs/rules/DEBT.md` — отступление `Core.Config` (`:9-22`).
24. `docs/adr/0006-repo-impl-resolved-by-convention.md`.
25. `docs/adr/0020-event-tag-ratchet.md` — `otp_app:` списком (`:49`), цена (`:55-66`).
26. `CONTEXT.md` — Actor (`:101-104`), кодек (`:65-67`).
27. `README.md` — DI (`:246-262`), миграции (`:201-240`), проекции (`:292-371`).
28. `CHANGELOG.md` — `0.5.0` (`:3-62`), ярус (`:981-1068`), проекции 0.3.0 (`:1636-1799`);
    `git show --stat e1f94d8`.
29. `fixtures/consumer/{README.md,mix.exs,config/config.exs,lib/**}`.
30. `test/support/{es_fixture/**,event_fixture.ex,state_stored_fixture.ex}`.
31. `lib/core/config.ex`, `lib/core/es/projection.ex`, `lib/core/es/aggregate/process.ex`,
    `lib/core/view/dumper.ex`, `lib/core/es/{event_compat_case,projection_case}.ex`,
    `lib/core/es/event/tags_case.ex`, `lib/core/enum/docs_case.ex`,
    `lib/core/repo/constraint_errors_case.ex`.
32. `scripts/boundary_lint.exs`, `scripts/layout_lint.exs`, `scripts/rules_lint.exs`.
33. Потребитель A (`b4f2347`): `mix.exs`, деревья `lib/`,
    `test/`, `priv/`, `config/`; `docs/rules/{10-architecture,13-repos,15-web-api}.md`,
    `docs/rules/DEBT.md`.
34. Потребители C, F, B, D, E — `mix.exs` и деревья `lib/*/domain`.
35. `.scratch/es-type-safety/research/02-core-es-blind-spots.md` — «Потребитель собран по
    образцу `test/support/es_fixture`».
