# Changelog

## Не выпущено

### Ломающие изменения контракта

- **Раскладка контекста — вертикаль по агрегату, контекст — граница Boundary**
  (`docs/rules/app/10-architecture.md`, «Состав контекста», «Модуль-оглавление», «Направления
  зависимостей», «Boundary», «Usecases»; `docs/rules/app/11-domain.md`, «Фасады и реестр плагинов»,
  «Prim и Enum»; `docs/rules/app/12-errors.md`; `docs/rules/app/13-repos.md`, «Read-модель»,
  «Репозитории актора»; решение — `docs/adr/0037-vertical-layout-context-boundary.md`, заменяет
  ADR-0023 и пункты ADR-0025 о циклах, типе модели в `Common` и корне контекста; запись и чтение
  между контекстами — `docs/adr/0038-one-context-per-transaction.md`; стартовая инициализация
  нескольких контекстов — `docs/adr/0048-bootstrap-session-lock.md`; общая модель нескольких
  агрегатов — `docs/adr/0049-concept-catalog.md`). `Common` и срезы
  инициаторов разносили агрегат, его чтение и его usecases по разным деревьям: чтение копировалось в
  срезах, а направления между контекстами держали правила линтера и ревью. Теперь всё об агрегате —
  в его каталоге, usecases — модулем на актора в подкаталоге актора, а то, что не принадлежит одному
  агрегату, — в каталогах уровня контекста по виду (`values/`, `errors.ex`, read-модель по
  назначению, `reactions/`). Каждый контекст — граница Boundary верхнего уровня: ссылку мимо его
  `exports` и цикл между контекстами ловит сборка; цикл, который пока не развязать, — `dirty_xrefs`
  и строка `DEBT.md`. Одна транзакция пишет один контекст, а таблицы read-модели другого контекста
  не читаются join: такие связи сборка не видит, и граница держалась бы ревью. Плагины кодека
  объявляет контекст, и новый кодек не правит центральный список.

  `boundary_lint --consumer`: правила `common-slice`, `foreign-slice`, `sibling-slice` и
  `subsystem-slice` удалены — направления держит Boundary. `bc-root` ловит `<BC>.Common` и срез на
  уровне контекста — одно нарушение на часть; `projection-layout` ждёт
  `<BC>.<ReadModel>.Projection`; `module-path` проверяет события и команды семейства на глубине
  каталога агрегата; `bc-index` требует `use Boundary` в оглавлении. Режима старой раскладки нет.

  Как править приложение (было → стало):
  - `MyApp.Domain.<BC>.Common.<Aggregate>…` в `<bc>/common/<aggregate>/` →
    `MyApp.Domain.<BC>.<Aggregate>…` в `<bc>/<aggregate>/`;
  - usecases среза `MyApp.Domain.<BC>.<Actor>.Usecases.<Aggregate>` →
    `MyApp.Domain.<BC>.<Aggregate>.<Actor>.Usecases` в `<bc>/<aggregate>/<actor>/usecases.ex`;
    чтение, общее нескольким акторам, — `<Aggregate>.Usecases`, у read-модели по назначению —
    `<ReadModel>.<Actor>.Usecases` и `<ReadModel>.Usecases`; операция над равноправными
    агрегатами `<Actor>.Usecases.<Usecase>` → `<BC>.<Operation>.<Actor>.Usecases` в
    `<bc>/<operation>/<actor>/usecases.ex`; хелпер `<Actor>.Usecases.<Aggregate>.Query` →
    `<Aggregate>.Query` в каталоге агрегата;
  - actor-репозитории среза `<BC>.<Actor>.<Aggregate>.{Repo,ReadRepo}` и View среза →
    `<Aggregate>.<Actor>.{Repo,ReadRepo,View}` в подкаталоге актора; ACL-фильтр — `default/1` в
    `Specs` актора; ключи кеша `.Cached` — под новым именем ReadRepo;
  - значение без владельца `<BC>.Common.<Value>` → `<BC>.Values.<Value>`; read-модель `Common` не по
    агрегату → каталог по назначению `<BC>.<ReadModel>`; тип модели контекста — в каталог
    агрегата-владельца или в `values/`; модель нескольких агрегатов, которая не значение и не
    read-модель (правила и шаблоны расчёта, их реестр, кодеки и ошибки), → каталог понятия
    `<BC>.<Concept>`, имя понятия — не `Process`; тип в каталоге агрегата, чьё имя совпало с актором
    (`Users.User.System` рядом с `Users.User.System.Usecases`), → переименовать тип
    (`User.Superuser`); адаптер канала, которому нужны данные другого контекста, → остаётся в
    контексте и берёт их через `exports` владельца, его сетевой транспорт — подсистема без чтения
    контекстов; каталог ошибок нескольких владельцев `<BC>.Common.Errors` → `<BC>.Errors` в
    `<bc>/errors.ex`; аксессор `<BC>.Common.CurrentUser` → `<BC>.<Aggregate>.CurrentUser` в каталоге
    агрегата учётной записи; значения, аксессор и каталог ошибок, на которые ссылаются другие
    границы, — в `exports` контекста;
  - список `MyApp.Codec.plugins/0` с плагинами всех контекстов → оглавление контекста объявляет
    `codec_plugins/0`, `MyApp.Codec.plugins/0` склеивает их и добавляет `Core.Outbox.Codec`;
  - usecase, который пишет второй контекст через его `Common` (репозиторий, агрегат), → вторая
    запись — задача второго контекста, поставленная в той же транзакции его экспортированной
    функцией, или его реакция на событие; нужна атомарная запись двух контекстов — контексты
    склеиваются; стартовая инициализация под одной `advisory_xact!` на два контекста → usecases
    каждого контекста своими транзакциями внутри `Core.Helper.Lock.with_advisory!/4`, шаги
    идемпотентны;
  - join ReadRepo на таблицы read-модели `Common` чужого контекста → нужные поля копирует своя
    проекция из экспортированных событий другого контекста; join — только внутри своего контекста;
  - оглавление `MyApp.Domain.<BC>` без кода → корень границы: `use Boundary` с `deps` (контексты,
    от которых зависит, `MyApp.Codec`, модули приложения, которые он зовёт) и `exports` (модули
    usecases, View, типы ID, события, плагины кодека);
  - граница `MyApp` на весь домен → её нет; `MyApp.Codec` — граница с `check: [out: false]`;
    `MyApp.DAO` и `MyApp.StreamID` → `MyApp.Infra.DAO` и `MyApp.Infra.StreamID` границы-стока
    `MyApp.Infra` (`config :core, dao:`, `config :my_app, MyApp.Infra.DAO` и `ecto_repos:` — вместе
    с ним); каждый модуль `lib/` принадлежит границе. Префикс telemetry репозитория Ecto выводится
    из имени модуля и становится `[:my_app, :infra, :dao]`: прежние имена событий сохраняет
    `telemetry_prefix: [:my_app, :dao]` в конфигурации репозитория, иначе правятся обработчики и
    `OpentelemetryEcto.setup/2`; метка `repo` метрик (`…_es_projection_signal_*`) становится
    `MyApp.Infra.DAO` — дашборды и алерты по ней правятся. Существующие миграции
    `MyApp.DAO.Migrations.*` не переименовываются: каталог `priv/dao/migrations` прежний;
  - `MyAppWeb` с `deps: [MyApp]` → `deps` — контексты и `MyApp.Codec`, без `MyApp.Infra`;
  - `MyApp.Application` и `MyApp.PromEx` с `top_level?: true` и `deps: [MyApp, …]`, mix-таски
    `classify_to: MyApp` → граница корня `MyAppApp` (пункт «Корень приложения — граница
    `MyAppApp`…» ниже);
  - взаимные ссылки контекстов (`SHOULD NOT`) → цикл — ошибка сборки, отступление — `dirty_xrefs`
    на одной стороне и строка `DEBT.md`;
  - маркеры `boundary-lint: allow` правил `common-slice`, `foreign-slice`, `sibling-slice`,
    `subsystem-slice` и их строки `DEBT.md` удаляются.

- **Корень приложения — граница `MyAppApp`, контекст объявляет проекции, процессы и детей**
  (`docs/rules/app/10-architecture.md`, «Top-level namespaces», «Корень и сток», «Состав
  контекста», «Модуль-оглавление», «Направления зависимостей», «Boundary»;
  `docs/rules/app/11-domain.md`, «Context»; `docs/rules/app/17-otp-concurrency.md`, «Дерево
  процессов», «Объявления контекста», «Проекции и процессы агрегата», «Фоновые задания»,
  «Наблюдение за процессами»; `docs/rules/app/19-testing.md`; `docs/rules/app/20-agreements.md`;
  пометка в `docs/adr/0024-component-owns-its-subtree.md`; фабрика контекста —
  `docs/adr/0044-context-factory-boundary.md`). Модули, которые собирают приложение целиком, —
  `Application`, `PromEx`, дерево очереди, сервер метрик, задачи релиза — были модулями верхнего
  уровня `MyApp.*`, а `Application` и `PromEx` — соседними границами, которые не могли ссылаться
  друг на друга; без границы `MyApp` остальные оказались бы вне границ. Списки проекций, процессов и
  наблюдаемых процессов были центральными: новая проекция правила `MyApp.Projections`, новый
  компонент — `Application` и провайдер `watch_list`. Теперь корень — одна граница `MyAppApp`, и
  `watch_list/0` приложения живёт в `Application` рядом с детьми, которых наблюдает. Контекст сам
  объявляет свои проекции, процессы агрегатов, корни компонентов и их списки для метрик модулем
  `<BC>.Supervision`, а корень склеивает их по списку контекстов. Объявления лежат не в
  оглавлении: от оглавления фасад кодека зависит на компиляции, и ссылки на проекции и компоненты,
  которые зовут фасад, замкнули бы цикл — правка любого модуля контекста пересобирала бы фасад.
  Архитектурный тест «web не ссылается на `*Repo` и `DAO`» заменён сборкой: `check: [aliases: true]`
  у `MyAppWeb` видит и модуль, переданный значением (`Transact.run(DAO, …)`). Обвязка тестов —
  граница `MyAppTest`: `boundary` относит модуль к границе по префиксу имени, и `MyApp.DataCase`
  без границы `MyApp` оказался бы вне границ. Фабрика контекста `MyApp.ContextFactory` тоже
  оказалась бы вне границ, а экспортом контекста учётной записи держала бы в нём обвязку всего
  приложения: теперь она — своя граница над границей аксессора текущего пользователя. Её зовут
  изнутри контекстов, и лежит она ниже всех вызывающих; граница аксессора от неё не зависит,
  иначе цикл.

  Как править приложение (было → стало):
  - `MyApp.Application`, `MyApp.PromEx`, `MyApp.MetricsServer`, `MyApp.Release` в `lib/my_app/` →
    `MyAppApp.Application`, `MyAppApp.PromEx`, `MyAppApp.MetricsServer`, `MyAppApp.Release` в
    `lib/my_app_app/`; `MyApp.Outbox` не переезжает, а уходит — пункт «Очередь outbox — готовое
    дерево `Core.Outbox.Supervisor`»; корень границы — модуль
    `MyAppApp` в `lib/my_app_app.ex`: `use Boundary` с `deps` (контексты, подсистемы,
    `MyApp.Infra`, `MyAppWeb`) и `contexts/0`;
  - границы `MyApp.Application` и `MyApp.PromEx` с `top_level?: true`, mix-таски
    `classify_to: MyApp` → одна граница `MyAppApp`, `use Boundary, classify_to: MyAppApp`;
  - `mod: {MyApp.Application, []}` в `mix.exs` → `mod: {MyAppApp.Application, []}`; команды
    `bin/my_app eval 'MyApp.Release.<fun>(…)'` в скриптах выката, образе и runbook →
    `bin/my_app eval 'MyAppApp.Release.<fun>(…)'`; имя `MyApp.Supervisor` корня дерева →
    `MyAppApp.Supervisor`;
  - новый модуль контекста `MyApp.Domain.<BC>.Supervision` в `lib/my_app/domain/<bc>/supervision.ex`
    с `projections/0`, `processes/0`, `children/0`, `watch_list/0`, а при плагинах `Core.Mq.PromEx`
    и `Core.Cache.PromEx` — `readers/0`, `kafka_readers/0`, `caches/0` (имена Cachex, `[atom()]`);
    пустая часть — `[]`; контекст экспортирует `Supervision`, `MyAppApp.contexts/0` перечисляет
    такие модули в порядке зависимостей контекстов;
  - `MyApp.Projections.opts/0` со списком проекций → `MyAppApp.Application.projection_opts/0`
    склеивает `projections/0` объявлений; ключ `config :my_app, MyApp.Projections` в
    `config/runtime.exs` и `config/test.exs` → `config :my_app, Core.Es.Projection.Supervisor`;
    `projections:` плагина `Core.Es.PromEx` → `{MyAppApp.Application, :projection_opts, []}`;
  - `MyApp.Processes.list/0` и `opts/1` → `MyAppApp.Application.processes/0` склеивает
    `processes/0` объявлений, опции — `process_opts/1`; `processes:` плагина `Core.Es.PromEx` →
    `{MyAppApp.Application, :processes, []}`;
  - корни компонентов контекста детьми `Application` → `children/0` объявлений; `start/2` ставит их
    после разделяемой инфраструктуры, включая планировщик задач, в порядке `contexts/0`;
  - провайдер `MyApp.PromEx.Workers.watch_list/0` → `MyAppApp.Application.watch_list/0`, в нём —
    `watch_list/0` объявлений вместо корней компонентов контекстов; `watch:` плагина
    `Core.Workers.PromEx` → `{MyAppApp.Application, :watch_list, []}`; провайдеры читателей и
    размеров кешей `MyApp.PromEx.*` → `MyAppApp.PromEx.*`, части контекстов — из `readers/0`,
    `kafka_readers/0` и `caches/0` объявлений;
  - архитектурный тест `MyApp.ArchitectureTest` и строка ратчета «web-слой не ссылается на `*Repo`
    и `DAO`» → удаляются; граница `MyAppWeb` → `check: [aliases: true]`;
  - `MyApp.ContextFactory` без своей границы → `use Boundary, deps: [<граница аксессора>]` в
    модуле фабрики: контекст учётной записи или `MyApp.Auth`; фабрика — в `deps` контекстов,
    `MyAppWeb`, `MyAppIngest` и корня; зависимость границы аксессора от фабрики (прямая или через
    её `deps`) → контекст воркеров и подписчиков этой границы собирается там
    `Core.Context.new/0`, `Core.Repo.Sc.init/1` и аксессором;
  - `MyApp.DataCase`, `MyAppWeb.ConnCase` и прочая обвязка `test/support/` под `MyApp.*`
    (контрактные наборы, дублёры) → `MyAppTest.DataCase`, `MyAppTest.ConnCase`, `MyAppTest.*`;
    корень границы — модуль `MyAppTest` в `test/support/` с
    `use Boundary, check: [in: false, out: false]`; заготовка `test/my_app_test.exs` от `mix new` →
    удалить: имя занято границей;
  - модули верхнего уровня вне таблицы границ → Ecto-типы схем — `MyApp.Infra.Types.<Type>` в
    стоке, настройка трассировки и сэмплер — `MyAppApp.Otel.*` в корне, прочее — подсистема
    `MyApp.<Subsystem>` со своей границей; модули telemetry компонентов, на которые ссылаются
    плагины PromEx корня, — в `exports` их контекста, а литерал имени события компонента в плагине
    корня → функция его модуля telemetry (`docs/rules/app/21-observability.md`, «Метрики»);
  - сервер метрик `MyAppApp.MetricsServer` в начале `children` → в конце, перед
    `MyAppWeb.Endpoint`: поднятый раньше компонентов, он отдавал `up=0` до их старта;
  - плаг аутентификации web, который кладёт пользователя аксессором в собранный контекст, →
    `MyApp.ContextFactory.with_user/2`;
  - исключение Credo `Refactor.IoPuts` для `lib/my_app/release.ex` и `lib/my_app/release/` →
    `lib/my_app_app/release.ex` и `lib/my_app_app/release/`;
  - компилятор `boundary` не во всех окружениях → `compilers: [:boundary] ++ Mix.compilers()` в
    `project/0`.

- **Проекцию ждёт usecase по `wait:`, web выбирает только статус**
  (`docs/rules/22-projections.md`, «Read-after-write»; `docs/rules/20-agreements.md`, «Разделение
  изменения и чтения (CQS)»; `docs/rules/app/10-architecture.md`, «Usecases», «Слои и зависимости»;
  `docs/rules/app/15-web-api.md`, «Ожидание проекции»; `docs/rules/app/19-testing.md`, «Event
  sourcing»; `docs/rules/19-testing.md`, «Ветка неготовой read-модели»; решение —
  `docs/adr/0039-usecase-awaits-projection-by-wait.md`, заменяет ADR-0030 в пунктах «usecase
  проекцию не ждёт» и «хелпер получает колбэк ожидания»; запрос с `wait:`, чтение без отставания и
  исходы без представления — `docs/adr/0047-query-awaits-projection.md`; пустой пакет —
  `docs/adr/0051-batch-command-unchanged.md`). Ожидание проекции было делом экшена: литеральный
  захват `&Projection.await(Agg, id, &1)` повторялся в каждом контроллере, воркер и подписчик ждали
  своим кодом, а с границей Boundary на контекст проекция и ReadRepo в его `exports` не входят —
  экшен ждать и читать read-модель больше не может. Теперь изменяющий usecase event-sourced агрегата
  принимает `wait: :none | pos_integer()` и после commit, вне транзакции, сам ждёт проекцию
  литеральным `Projection.await/3` с ID, суженным до `%Agg.ID{}`, — сборка сверяет агрегат и ID, как
  прежде в экшене. Дождавшись, команда отдаёт представление, прочитанное запросом актора, создание,
  удаление и upsert — `{id, version}`; не дождавшись или не прочитав — `{id, version}` с тегом
  `:accepted`. Экспортированный запрос MAY принимать тот же `wait:` и ждать до чтения: так реакция
  другого контекста исполняет «дождаться проекции читаемой read-модели». Прежние ответы API, схемы
  `Written` и `Prefer`, заголовок `Preference-Applied` не меняются; новый — 204 пакетной команды с
  пустым пакетом, строкой таблицы `Prefer`.

  Как править приложение (было → стало):
  - команда event-sourced агрегата `take(id, version, context) :: {:ok, Version.t()}` →
    `take(id, version, context, opts \\ [])` с `wait: :none | pos_integer()`, по умолчанию `:none`,
    `:: {:ok, {:projected, View.t()}} | {:ok, {:accepted, ID.t(), Version.t()}}`; после записи —
    хелпер ожидания `awaited/2` в модуле usecases (`docs/rules/22-projections.md`,
    «Read-after-write»), `:projected` — чтение представления запросом `get` актора, отказ чтения —
    `:accepted`;
  - создание, удаление и upsert `{:ok, {ID.t(), Version.t()}}` / `{:ok, Version.t()}` →
    `{:ok, {:projected | :accepted, ID.t(), Version.t()}}`; команда агрегата без read-модели —
    `{:ok, {:accepted, ID.t(), Version.t()}}`, `wait:` она не принимает; пакетная команда с пустым
    пакетом (`{:ok, nil}`) → `{:ok, :unchanged}`, `MyAppWeb.Accepted.respond/3` отвечает на него 204
    без `Preference-Applied`, операция объявляет ответ 204;
  - правило реакции, которое ждёт проекцию другого контекста и читает его ReadRepo, → его
    экспортированный запрос с `wait:`, ошибка ожидания — `{:error, _}` и повтор; чтение учётной
    записи свёрткой потока через репозиторий другого контекста → его read-модель без таблицы и её
    `<ReadModel>.Usecases` (`docs/rules/app/13-repos.md`, «Read-модель»);
  - вызывающие, которые read-модель после записи не читают (воркер, подписчик, mix-таска), —
    `{:ok, version}` → `{:ok, {:accepted, _id, version}}`, `wait:` не передают; своё ожидание
    проекции у них → `wait:` usecase;
  - `MyAppWeb.Accepted.respond` / `written` с колбэком ожидания `&Projection.await(Agg, id, &1)`
    или результатом ожидания (любой арности, например
    `respond(conn, &Projection.await(Agg, id, &1), {id, version}, render)`) →
    `MyAppWeb.Accepted.respond(conn, result, render)`, где `result` — результат usecase, вызванного
    с `wait: MyAppWeb.Accepted.wait(conn)`, а `render` — `(conn, view -> conn)` вместо перечитывания
    read-модели; `written(conn, &Projection.await(Agg, id, &1), id, version)` →
    `written(conn, result)`; новая `wait/1` переводит `Core.Web.Prefer.mode/2` в `wait:`
    (`:respond_async` → `:none`, `{:wait, ms}` → `ms`);
  - `defp` экшена с захватом `&Projection.await(Agg, id, &1)` и сужением ID → удаляется: ожидание и
    сужение — в хелпере ожидания usecase;
  - тест ветки 202 в `MyAppTest.ConnCase` через `Core.Es.Projection.Test.with_rebuilding/2` → тест
    ветки `:accepted` usecase в `MyAppTest.DataCase, async: false`, один на модуль usecases с
    ожиданием; тест хелпера — `wait/1` в трёх ветках `Prefer`, `respond/3` и `written/2` — 200 на
    `:projected` и 202 на `:accepted`, `respond/3` — 204 на `:unchanged`;
  - тесты, которые сопоставляли `{:ok, version}` и `{:ok, {id, version}}` команд event-sourced
    агрегата, → `{:ok, {:accepted, ^id, version}}` и `{:ok, {:accepted, id, version}}`.

- **Компонент лежит у исполнителя, вход внешней системы — граница `MyAppIngest`**
  (`docs/rules/app/17-otp-concurrency.md`, «Дерево процессов», «Место компонента», «Наблюдение за
  процессами», «Фоновые задания»; `docs/rules/app/10-architecture.md`, «Top-level namespaces»,
  «Состав контекста», «Направления зависимостей», «Boundary»; `docs/rules/app/14-events-outbox.md`,
  «Подписчики», «DLQ в Postgres»; решение — `docs/adr/0040-component-at-executor.md`, дополняет
  ADR-0024 в пункте о месте компонента; от чьего имени исполняется задача —
  `docs/adr/0041-consequence-job-runs-as-system.md`). Компонент, который зовёт usecases, лежал в
  срезе своего инициатора, воркер — в срезе постановщика, задача по расписанию — в срезе `System`. С
  границей на контекст такой компонент делает инициатора зависимым от usecases исполнителя: с
  реакцией в своём контексте производитель события знает, кто на него реагирует, и замыкает цикл с
  реагирующим, которому нужны его события, а воркер у постановщика знает аргументы и ключ чужой
  задачи. Теперь компонент лежит у исполнителя: реакция — в реагирующем контексте, рядом с usecases,
  которые зовёт; воркер — в каталоге агрегата, чей usecase исполняет, а постановку исполнитель
  отдаёт своей функцией с аргументами — своими типами. Задача-следствие исполняется от системной
  учётной записи: права её автора проверены при постановке, а их перепроверка при исполнении
  отказала бы в том, что commit уже обещал; автор решения, нужный аудиту, — аргумент операции, а не
  `%Context{}`. Формат внешней системы и DLQ отклонённого — не модель контекста: их держит граница
  входа `MyAppIngest` рядом с web, с теми же запретами точки входа.

  Как править приложение (было → стало):
  - подписчик топика своего приложения в срезе инициатора, в `Common` или в контексте-производителе
    события → реакция в реагирующем контексте: каталог агрегата, чей usecase она зовёт,
    `<bc>/<aggregate>/<component>/`, при usecases нескольких агрегатов —
    `<bc>/reactions/<component>/`; корень — в `children/0` и `watch_list/0` объявлений реагирующего
    контекста; модули событий производителя — через его `exports`;
  - компонент контекста, который зовёт изменяющий usecase другого контекста, → реакция или воркер
    того контекста;
  - воркер `Oban.Worker` в срезе постановщика → `<Aggregate>.<Name>` в каталоге агрегата, чей
    usecase он исполняет (у операции над равноправными агрегатами — в каталоге операции);
    постановка — функция модуля воркера (`enqueue/N`), вызывающий зовёт её в своей транзакции;
    воркер, которого ставит другой контекст, — в `exports` исполнителя; `Oban.insert/2` с
    аргументами чужого воркера → его функция постановки;
  - задача по расписанию в срезе `System` → воркер в каталоге агрегата-исполнителя; модуль в
    `crontab` планировщика (`config/runtime.exs`) — под новым именем;
  - функция постановки с типом постановщика в аргументах → типы исполнителя; исполнителю нужны
    данные постановщика → реакция исполнителя на его событие;
  - задача-следствие, исполняемая от имени поставившего (`ContextFactory.as_user/1` с ID из
    `args`), → `ContextFactory.system/0`; `%Context{}` в её функции постановки → явный аргумент
    автора решения, если он нужен аудиту, — в операции исполнителя и в нагрузке его события;
    отложенная команда пользователя (отправка от его имени по расписанию, выгрузка его данных)
    по-прежнему исполняется от его имени;
  - задачи, уже стоящие в `oban_jobs`, хранят имя модуля воркера в колонке `worker`: переименование
    выкатывается, когда очередь старого имени опустела, либо вместе с `UPDATE oban_jobs SET worker`
    на новое имя;
  - подписчики топиков внешней системы, разбор её формата и дерево DLQ в контексте → граница
    `MyAppIngest`: корень `MyAppIngest` в `lib/my_app_ingest.ex` с
    `use Boundary, deps: [<контексты>, <подсистемы>], check: [aliases: true]`, корень компонента —
    `MyAppIngest.<Source>.Supervisor` в `lib/my_app_ingest/<source>/`; `repo:` литералом репозитория
    у `Core.Mq.Dlq.Writer`, `Core.Mq.Dlq.Reader` и `Core.Mq.Kafka.Reader` → опция компонента в
    `config/runtime.exs`; ошибки разбора её формата, которые строились каталогами агрегатов
    контекста, → каталог входа `MyAppIngest.Errors`; `MyAppIngest` — в `deps` корня `MyAppApp`,
    корни её компонентов — детьми `Application` после детей контекстов и в
    `MyAppApp.Application.watch_list/0`, её читатели — в провайдерах `readers:` и `kafka_readers:`;
  - при переносе реакции или входа строки `subscriber_name:` и `component:` не меняются: по ним
    живут смещения читателей Stream и Kafka, записи `mq_dlq` и ряды метрик; меняются только имена
    модулей и процессов.

- **Проверка доступа — порт `MyApp.Authz`, ключи пространств объявляет контекст**
  (`docs/rules/app/10-architecture.md`, «Top-level namespaces», «Состав контекста»,
  «Модуль-оглавление», «Направления зависимостей», «Обязательства перед библиотекой», «Файлы
  `config/`», «Boundary», «Проверка доступа», «Usecases»; `docs/rules/app/17-otp-concurrency.md`,
  «Дерево процессов»; `docs/rules/app/13-repos.md`, «Read-модель», «DI»;
  `docs/rules/app/19-testing.md`, «Проверка доступа»; `docs/rules/19-testing.md`, «Контрактные тесты
  behaviour»; `docs/rules/app/12-errors.md`, «Словарь `ns`»; решение —
  `docs/adr/0042-authz-port.md`, заменяет пункты ADR-0025 «механизм над моделью — подсистема» и
  «ключ механизма лежит у механизма»; несколько пространств, операции, общее чтение и 401 —
  `docs/adr/0046-authz-port-namespaces-ops.md`; тест доступа на модуль декларации и контрактный
  набор на дублёрах — `docs/adr/0052-authz-test-per-declaration-doubles-under-contract.md`).
  Механизм прав был подсистемой, которая читает контекст прав, а usecases контекста прав сами зовут
  механизм: с границей на контекст это цикл границ. Ключ пространства лежал в реестре механизма, и
  каждый новый агрегат правил центральный список, а тест любого usecase готовил роли, учётные записи
  и проекции контекста прав. Теперь проверка доступа — порт без `deps` на контексты: реализует его
  контекст прав или заглушка, реализацию называет ключ конфигурации, порт читает его в рантайме —
  литерал реализации `boundary` репортит. Ключи пространств, их описание и операции объявляет
  контекст в оглавлении, макрос декларации сверяет ключи при компиляции, порт сверяет операции с
  реестром, корень склеивает реестр. Декларация стоит и на модуле общего чтения
  `<Aggregate>.Usecases` — со списком типов учётной записи, а второе пространство своего контекста
  usecase проверяет `check_user/3`. Отказ — `:access_denied` (403) или `:unauthorized` (401). Тест
  usecase идёт с моком порта, авторизацию модуля декларации держит интеграционный тест с боевой
  реализацией, операции — табличный тест в нём; общий контрактный набор — MUST на боевых реализациях
  и дублёрах одного behaviour, на моке — нет.

  Как править приложение (было → стало):
  - подсистема механизма прав (макрос декларации, проверка, реестр и каталог пространств) → порт
    `MyApp.Authz` в `lib/my_app/authz.ex`: `use Boundary, deps: [], exports: [Errors]`, behaviour
    `check/4` (первый аргумент — список типов учётной записи), макрос `use MyApp.Authz` с
    `account:` (атом или список), `namespace:` и `namespaces:`, дающий `check_user/2` и
    `check_user/3`, `namespaces/0`, `registry!/1`, `validate!/0`; проверка второго пространства
    своего контекста в usecase → ключ в `namespaces:` декларации и
    `check_user(:<ns>, ops, context)`; чтение нескольких акторов в `<Aggregate>.Usecases` →
    декларация на нём с `account: [<типы акторов>]`; декларация в тестовом модуле → убрать: usecase
    тестируется через свой модуль с моком порта; проверка над моделью прав → реализация
    `MyApp.Domain.<BC>.Authz` контекста прав с `@behaviour MyApp.Authz`; у приложения без модели
    прав — заглушка `MyApp.Authz.Stub`;
  - каталог ошибок отказа механизма → `MyApp.Authz.Errors`, отказ —
    `%Error{kind: :domain, code: :access_denied}`, а учётной записи нет или она заблокирована —
    `%Error{kind: :domain, code: :unauthorized}` (401);
  - ключ пространства в реестре механизма или `<Aggregate>.ns/0` → `authz_namespaces/0` оглавления
    контекста (`[<key>: {"<описание>", ~w(<операции>)a}]`); реестр, собранный обходом модулей или
    ручным списком, → `MyAppApp.authz_namespaces/0` склеивает `authz_namespaces/0` оглавлений
    через `MyApp.Authz.registry!/1`; каталог ролей → модель контекста прав, пространства и операции
    он берёт из `MyApp.Authz.namespaces/0`;
  - выбор реализации → `config :my_app, MyApp.Authz, impl: <реализация>,
    namespaces: {MyAppApp, :authz_namespaces, []}` в `config/config.exs`;
    `MyAppApp.Application.start/2` зовёт `MyApp.Authz.validate!/0` до подъёма дерева;
  - `deps` контекста на подсистему механизма или контекст прав ради проверки → `MyApp.Authz`;
    `deps` корня `MyAppApp` — плюс `MyApp.Authz`;
  - тест usecase с ролями и прогоном проекций контекста прав → мок
    `Mox.defmock(MyAppTest.Authz, for: MyApp.Authz)` в `test/support/mocks.ex`,
    `config :my_app, MyApp.Authz, impl: MyAppTest.Authz` в `config/test.exs`,
    `{:mox, "~> 1.2", only: :test}` в `deps`; на каждый модуль декларации — интеграционный тест с
    `Mox.stub_with(MyAppTest.Authz, MyApp.Domain.<BC>.Authz)`: отказ без права и успех с ним, а
    операции модуля — таблицей в том же тесте; у приложения с заглушкой мок и интеграционные тесты
    доступа не нужны;
  - общий контрактный набор, который гонялся и на моке, → на боевых реализациях и дублёрах (своя
    реализация с поведением), на моке Mox — нет.

- **Очередь outbox — готовое дерево `Core.Outbox.Supervisor`, wake — по его отметке**
  (`docs/rules/14-events-outbox.md`, «Outbox lifecycle», «Единственность поллера»;
  `docs/rules/app/14-events-outbox.md`, «Единственность поллера», «Конфигурация»;
  `docs/rules/app/17-otp-concurrency.md`, «Готовое дерево без корня», «Очередь outbox»; решение —
  `docs/adr/0045-outbox-ready-tree.md`; один репозиторий и выключенное дерево без опций —
  `docs/adr/0050-outbox-tree-one-repo-disabled-bare.md`). Корень очереди писал каждый потребитель:
  порядок детей и две проверки старта держали ревью и ратчет, проверка единственности у большинства
  была своей копией с разной трактовкой пустого `DNS_CLUSTER_QUERY`. Wake после вставки читал имена
  поллеров из `config :core, Core.Outbox`, корень — из своего ключа, и их расхождение было видно
  только задержкой доставки до `poll_interval_ms`. Теперь очередь поднимает только дерево
  библиотеки: соединение → на каждый поллер его writer и сам поллер → cleaner под `rest_for_one`,
  проверки единственности на кластере и непересечения фильтров при старте, тумблер `enabled:` и
  `watch_list/1`. До подъёма детей дерево пишет в `:persistent_term` отметку с именами и фильтрами
  поллеров, и wake читает только её; `config :core, Core.Outbox` библиотека не читает нигде.
  `Core.Outbox.Poller` вне дерева не стартует — `ArgumentError`, поэтому приложение со старым корнем
  после обновления падает на старте, а не теряет wake молча.

  Как править приложение (было → стало):
  - рукописный корень очереди (`MyAppApp.Outbox.Supervisor` или `MyApp.Outbox.Supervisor`:
    writer → поллер(ы) → cleaner) → удалить; в `MyAppApp.Application` ребёнком —
    `{Core.Outbox.Supervisor, outbox_opts()}`, где `MyAppApp.Application.outbox_opts/0` собирает
    опции из `config :my_app, Core.Outbox.Supervisor`; соединение Stream, у которого других
    пользователей нет, → опция `connection: {Core.Mq.Stream.Connection, opts}` дерева;
  - `config :core, Core.Outbox` в `config/runtime.exs` → `config :my_app, Core.Outbox.Supervisor`:
    `enabled:`, `cluster_query:` (обязательна; прежнее значение `DNS_CLUSTER_QUERY`, `nil` — нет
    кластера; база `nil` в общей части блока, `DNS_CLUSTER_QUERY` — в prod-блоке), `allow_cluster:`
    (было `allow_cluster?:` у проверки), `poll_interval_ms:`, `idle_min_ms:`, `batch_size:`,
    `lock_duration_seconds:`, `max_attempts:`, `published_ttl_seconds:`, `cleaner_interval_ms:` —
    голыми положительными целыми, без `new!` в Prim; дефолтов у tunables нет, обязательны они только
    при `enabled: true`; `repo:` дерево не принимает — репозиторий поллеров и cleaner тот же,
    которым пишут записи, `Core.Config.outbox_repo/0` (`config :core, Core.Outbox.Repo`, по
    умолчанию `Core.Outbox.Repo.Pg`);
  - `poller_name:` / `pollers: [[name:, topics:]]` → `pollers:` дерева, элемент —
    `[name:, label:, topics:]` и ровно один из `writer: {Core.Mq.Stream.Writer, opts с name:}`
    (writer, который поднимало приложение, — теперь его поднимает дерево перед поллером) или
    `via: {Core.Mq.Kafka.Writer, client}` (процесс, которым владеет приложение); `label:` —
    строка, метка компонента; `delivery_module:` / `delivery:` поллера собирает дерево; поллер
    выключенного транспорта в список не входит — его топики ждут в `pending`;
  - `reference_prefix` из ключа очереди → в опции `writer:` элемента (`outbox_opts/0` вынимает его
    из ключа приложения, если он лежит там);
  - `context_factory:` поллеров и cleaner'а корня → одна опция `context_factory:` дерева; без неё
    дерево берёт `&Context.new/0` — контекст без системной учётной записи, и переход молча меняет
    контекст доставки и чистки; фабрика приложения — `&MyApp.ContextFactory.system/0`;
  - вызовы `Core.Outbox.check_singleton!/1` и `Core.Outbox.validate_partition!/1` → удалить:
    функций нет, обе проверки делает дерево; строку ратчета «корень очереди зовёт
    `check_singleton!/1`» и его тест — удалить;
  - тестовый overlay `config :core, Core.Outbox, enabled: false, poller_name: nil` →
    `config :my_app, Core.Outbox.Supervisor, enabled: false` — прочие опции выключенному дереву не
    нужны;
  - `watch_list/0` корня очереди → `Core.Outbox.Supervisor.watch_list(outbox_opts())` в склейке
    `MyAppApp.Application.watch_list/0`; метки компонентов — `outbox_connection`,
    `outbox_writer:<label>`, `outbox_poller:<label>`, `outbox_cleaner`: дашборды и алерты на
    прежние метки (`outbox_poller`, `outbox:poller` и т. п.) правятся при переезде.

### Новое

- **`Core.Helper.Lock.with_advisory!/4`** — сессионная advisory-блокировка одного соединения на
  всё время колбэка (`docs/rules/app/10-architecture.md`, «Usecases»; решение —
  `docs/adr/0048-bootstrap-session-lock.md`). Блокировка транзакции снимается на её commit, и
  задача, которая пишет несколькими транзакциями, теряла взаимоисключение после первой. Колбэк идёт
  в `repo.checkout/1`, его транзакции берут то же соединение; блокировка снимается в `after`,
  `lock_timeout` ставится на сессию только на время взятия; внутри транзакции — `ArgumentError`.
  Приложение: своя сессионная блокировка или одна транзакция ради взаимоисключения →
  `Core.Helper.Lock.with_advisory!(MyApp.Infra.DAO, key, fn -> … end)`.

- **`Core.Helper.StartOpts.process!/3` и `unique!/4`** — проверки готового дерева: процесс
  `{модуль, опции}` с `name:` атомом (`%{module:, opts:, name:}`, тип `StartOpts.process()`) и
  значения без повторов. Их держали копиями `Core.Outbox.Supervisor` и
  `Core.PubSub.MqSubscriberReliable.Supervisor`; своё дерево приложения берёт их вместо копии.

- **Нормы совместимости действуют с первого релиза приложения** (`docs/rules/app/00-index.md`,
  «Первый релиз»; решение — `docs/adr/0035-compatibility-after-first-release.md`). Первый релиз —
  один момент на приложение: первое из «появилась база, которую нельзя пересоздать» и «у любого
  контракта (API, топик, wire событий) появился потребитель вне команды». До него не действуют
  новый тег и апкаст на несовместимую правку события, неизменность golden-фикстур и применённых
  миграций, expand / contract, следующая версия API и миграция, заполняющая резервы ключа; базы
  после pull пересоздаются. Было — исключение неровное: история миграций — MAY, wire событий — MAY
  до выката контракта наружу с записью каждого случая в `DEBT.md`, остальные нормы исключения не
  имели. Исключения в `app/14` и `app/18` заменены ссылкой на общую норму; на неё же теперь
  ссылаются `app/13`, `app/15` и свод библиотеки (`14-events-outbox.md`, «Совместимость событий»).

  Новое требование к локальному своду: индекс `docs/rules/00-index.md` приложения MUST нести строку
  «Первый релиз: не состоялся» или «Первый релиз: <дата>, <версия>». Строки нет — нормы
  совместимости действуют, отсутствие не читается как «до релиза». `rules_lint.exs --consumer`
  отказывает, если строки нет, она не в одной из двух форм (`ГГГГ-ММ-ДД, X.Y.Z`) или их две: забытая
  строка иначе видна только ревью. Строки внутри блока кода — пример, а не состояние, и не
  считаются; строка в разметке (`**Первый релиз:**`) — нарушение формы.

  Как править приложение: было — строки `DEBT.md` на каждую правку до выката («строк с этим тегом
  не существует») и своя норма «до первого релиза» в локальном своде → стало — строка
  «Первый релиз» в локальном индексе, записи `DEBT.md` о правках до релиза и своя норма удаляются.

- **`DEBT.md` приложения — только отступления** (`docs/rules/app/00-index.md`, «`DEBT.md`
  приложения»): раздел называет, что не чинится, одну причину и условие снятия. Нормы яруса
  требовали записывать туда инвентарь и бэклог, и объём реестра перестал говорить о несогласии со
  сводом. Сняты два требования: перечень циклов компиляции (`app/20`, «Граф зависимостей»; их
  показывает `make xref`, норма о гейте на каскад остаётся) и запись пробелов покрытия (`app/19`,
  «Пробелы»; теперь — задача в трекере приложения, `DEBT.md` MAY ссылаться на его раздел).
  Неподключённый SDK трассировки (`app/21`), маркер `boundary-lint`, отклонение `poll_rate` и
  исключения ратчетов остаются строками `DEBT.md`: за ними стоит отступление от нормы.

  Как править приложение: было — раздел `DEBT.md` с перечнем циклов, разделы о ненаписанных тестах
  и отложенной функциональности → стало — перечень циклов удаляется, пробелы покрытия и отложенная
  функциональность переносятся задачами в трекер, у оставшихся разделов — причина и условие снятия.

- **Три узких случая перестали быть отступлениями.**
  - Bang в `evolve/2` (`docs/rules/20-agreements.md`, «Safe vs bang»; `docs/rules/app/11-domain.md`,
    «Event-sourced»): исключение расширено с конверсии Prim до любой чистой операции над событием и
    константами кода (Prim, реестр, заданный литералом в коде). Довод прежний — колбэк возвращает
    голое состояние, вернуть `{:error, _}` ему некуда.
  - Выборка кандидатов через ReadRepo (`docs/rules/13-repos.md`, «Read (`<Aggregate>.ReadRepo`)»;
    `docs/rules/app/13-repos.md`, «Write и read»): изменяющий фоновый прогон MAY выбирать кандидатов
    через ReadRepo, если в мутацию уходят только id и версия, а каждый кандидат читается и
    сохраняется отдельным load/save в одной функции. Пачка через Repo оседала эталоном в `Repo.Sc`
    на всё задание; View в мутацию по-прежнему не уходит.
  - Read-модель с доменным значением (`docs/rules/app/13-repos.md`, «Read-модель»;
    `docs/rules/app/16-caching.md`, «Когда кешировать»): read-модель без таблицы, которую не отдаёт
    граница, MAY возвращать неизменяемое доменное значение (не агрегат) вместо View из примитивов и
    кешировать его так же. Презентер по-прежнему получает только View.

  Как править приложение: было — строки `DEBT.md` об этих трёх случаях → стало — строки
  удаляются, код не меняется, если выполнены условия MAY.

### Изменения контракта макросов

- **`use Core.Prim.UUID, version: :external` — внешний идентификатор.** Id потока event-sourced
  агрегата, чей неизменяемый естественный ключ — сам UUID внешнего источника, уникальный на все виды
  агрегатов из этого источника, MAY быть этим UUID как есть (`docs/rules/app/13-repos.md`,
  «Уникальность без индекса состояния»; решение — `docs/adr/0036-stream-id-external-uuid.md`).
  UUIDv5 от такого ключа дал бы второй идентификатор того же объекта, а Prim с генерирующей
  версией и `check_version: false` генерирует `new/0`, которым id выпускается в обход источника, и
  компилятор этого не видит. У `version: :external` нет ни `new/0`, ни `from_key/1` — вызов
  `new/0` ловится на сборке; разбор принимает UUID любой версии; `check_version:`, `namespace:` и
  `scope:` рядом с ним — `CompileError`. Прочие значения `version:` не меняются.

  Как править код потребителя, у которого Prim над UUID источника:

  ```elixir
  # было
  use Core.Prim.UUID,
    name: first_line(@moduledoc),
    version: 1,
    check_version: false

  # стало
  use Core.Prim.UUID,
    name: first_line(@moduledoc),
    version: :external
  ```

  Вызовы `Agg.ID.new()` такого Prim после правки — предупреждение компилятора: id берётся из
  источника через `Agg.ID.new/1`, в фикстурах — `Ecto.UUID.generate() |> Agg.ID.new!()`. `:external`
  описывает происхождение значения, а не роль: им объявляется и ссылка агрегата на объект источника,
  которая id потока не является (`docs/rules/11-domain.md`, «Prim (value object)»).

- **`use Core.Es.Outbox` генерирует `topic/0`.** Модуль `<Aggregate>.Outbox` отдаёт топик из опции
  `topic:` строкой (`docs/rules/14-events-outbox.md`, «Aggregate → Outbox.Record»). Подписчик на
  топик своего приложения берёт его оттуда, а модуль outbox входит в `exports`
  контекста-производителя (`docs/rules/app/14-events-outbox.md`, «Топики и запись в очередь»):
  литерал топика в контексте подписчика не узнаёт о переименовании в `use Es.Outbox`, и подписчик
  молча остаётся читать старый топик. Строка — та же форма, что у `topic:` подписчика; читателю
  брокера топик — `Core.Mq.Topic.new!/1` над ней.

  Как править подписчик на топик своего приложения:

  ```elixir
  # было
  reader: {Core.Mq.Stream.Reader, topic: Core.Mq.Topic.new!("orders"), …},
  subscriber: [topic: "orders", …]

  # стало
  reader: {Core.Mq.Stream.Reader, topic: Core.Mq.Topic.new!(Order.Outbox.topic()), …},
  subscriber: [topic: Order.Outbox.topic(), …]
  ```

  и `Order.Outbox` — в `exports` оглавления контекста-производителя `MyApp.Domain.Orders`. Своя
  функция `topic/0` в модуле outbox сталкивается с генерируемой: её нужно убрать. Топик в паттерне
  головы подписчика или в опции его макроса — атрибутом `@topic Order.Outbox.topic()`, а не
  литералом: сборка пересобирает подписчика при смене топика производителя.

## 0.10.0

### Ломающие изменения контракта

- **Адаптер Kafka — на клиенте `:brod` вместо `:klife`.** Читать с кластера без KIP-848 `:klife`
  может только через свои внутренние модули; `:brod` читает партицию без consumer group публичным
  API, а два клиента к одному кластеру — две конфигурации подключения и два набора нативных
  зависимостей. Решение и отвергнутые варианты — `docs/adr/0034-kafka-adapter-on-brod.md`.
  `put` / `put_many` по-прежнему публикуют строго по порядку со стопом на первой ошибке, ключ
  попадает в ту же партицию, что и раньше, и что у Java-клиентов (murmur2 `DefaultPartitioner`).

  Правка `deps`: было — `{:klife, "~> 1.2"}` → стало — `{:brod, "~> 4.7"}`. Обязательная нативная
  зависимость — `crc32cer`; `snappyer` больше не обязателен, кодеки сжатия (`snappyer`, `lz4b`,
  `ezstd`) объявляются по выбору. `Core.Mq.Kafka.ensure_available!/0` проверяет `:brod`.

  Правка клиента и handle: было — модуль `use Klife.Client, otp_app: :my_app` с конфигурацией
  в `config :my_app, MyApp.Kafka` и handle `Kafka.Writer.put_many(MyApp.Kafka, messages)` → стало —
  клиент `:brod` в дереве приложения, handle — его id:
  `{:brod, :start_link_client, [endpoints, MyApp.Kafka, [auto_start_producers: true]]}` и
  `Kafka.Writer.put_many(MyApp.Kafka, messages)`. Подключение, SASL и TLS переписываются в опции
  клиента `:brod` (README, «Опциональные зависимости»).

  Идемпотентного продюсера у `:brod` нет: повтор отправки внутри клиента может задвоить запись.
  Outbox и без того at-least-once — подписчик обязан быть идемпотентным.

  `body: ""` — `{:error, %Error{code: :kafka_publish_failed, detail: :empty_body}}` до отправки:
  `:brod` пишет пустое значение как null, и сообщение стало бы tombstone, молча удаляющим ключ
  компактного топика. Было — пустое тело публиковалось.

  `detail` ошибки `:kafka_publish_failed` — причины `:brod`: было — `:unknown_metadata_for_topic`
  → стало — `:unknown_topic_or_partition`; `{:error_code, code}` — код брокера атомом
  (`:message_too_large`), а не числом; клиент не запущен — `:client_down`. Разбор `detail` на
  call site правится по этим формам.

- **`Mq.Message` моделирует запись чужого топика: `nil`-тело, байтовый ключ, любые имена
  заголовков, позиция источника.** Библиотека читает топики, которыми не владеет: ключ с Schema
  Registry — Avro-байты, имена заголовков задаёт владелец топика, удаление в компактном топике —
  запись без значения. Решение и отвергнутые варианты —
  `docs/adr/0032-mq-message-models-foreign-topic-record.md`.

  - `Message.body :: binary() | nil`: `nil` — tombstone. `Kafka.Writer` публикует его как
    удаление, `Kafka.Reader` отдаёт пустое значение как `nil`. `from_message` подписчика: было —
    тело всегда `binary()` → стало — клоза на `%Mq.Message{body: nil}`.
  - `Mq.Key` — непустые байты без предела длины и без UTF-8; модуль и API (`new/1`, `value/1`)
    прежние. Код, выводящий `Mq.Key.value/1` в лог или JSON, проверяет `String.valid?/1`.
  - `Mq.HeaderKey` — любая непустая строка UTF-8 в lowercase (было — `^[a-zA-Z0-9._-]+$` до 100
    символов). `Message.new/4,5` принимает заголовки и списком пар: при повторе имени — последнее
    значение, `nil`-значение — `""`.
  - `Message.position :: Mq.Position.t() | nil` (`%Mq.Position{partition:, offset:}`) и
    `Message.new/5` с позицией пятым аргументом. `Stream.Reader` заполняет смещение при
    `partition: nil`, у публикуемого сообщения — `nil`. Код, матчащий `%Mq.Message{}` целиком
    литералом, дополняется полем.
  - `Stream.Codec.encode/1` на tombstone, ключе или значении заголовка не в UTF-8 —
    `{:error, _}` (`:invalid_body`, `:invalid_key`, `:invalid_headers`): было — исключение или
    `:encode_failed`. Выброс такого сообщения в Stream-DLQ отказывает, и оно остаётся без commit.

- **Таблицы читателя Kafka — миграция потребителя.** `Core.Mq.Kafka.Reader` хранит смещения и
  аренду топика в БД приложения (`mq_kafka_offsets`, `mq_kafka_leases`). Приложение, которое
  поднимает читатель, заводит миграцию со своим timestamp и делегирует DDL
  `Core.Mq.Kafka.Migration` (`defdelegate up/down`, README, «Миграции»); без читателя миграция
  не нужна.

- **Метка `reason` у `mq_subscriber_dlq_total`** (`rejected` — отказ обработчика `{:reject, _}`,
  `exhausted` — исчерпание `max_attempts`): выброс по отказу и после повторов требуют разного
  разбора, а ряд без метки их не различает. Метка делит ряд надвое. Запрос без агрегации по меткам
  правится: было — `my_app_prom_ex_mq_subscriber_dlq_total{topic="orders"}` → стало —
  `sum by (topic, dlq_topic) (my_app_prom_ex_mq_subscriber_dlq_total{topic="orders"})`; алерт
  `MqSubscriberDlq` из `docs/rules/21-observability.md` уже агрегирует и не меняется.

### Новое

- **`Core.Mq.Kafka.Reader`** — `Mq.ReaderReliable` для Kafka: `Core.PubSub.MqSubscriberReliable`,
  `{:skip, _}` с commit и путь DLQ работают поверх Kafka. Подписка на `brod_consumer` каждой
  партиции без consumer group — работает на любой Kafka ≥ 0.11, в том числе без KIP-848; одна
  активная нода на топик по аренде с fencing-токеном, смещения — в таблице БД приложения, без
  смещения — чтение с начала топика (`initial_offset:`). Сообщение несёт ключ, заголовки, тело
  как есть и позицию (партиция, смещение). Смещение вне лога — `error` и переподписка с начала,
  событие `[:core, :mq, :kafka, :offset_reset]`. Решение и цена —
  `docs/adr/0033-kafka-reader-without-consumer-group.md`. `Core.Mq.Kafka.ensure_available!/0`
  проверяет и читателя.

  Метрики чтения — в `Core.Mq.PromEx`: смещения читателя не видны мониторингу групп брокера, и
  отставание видно только по ним. Счётчики `mq_kafka_offset_reset_total{topic}`,
  `mq_kafka_decode_drop_total{topic}`, `mq_kafka_read_errors_total{topic, reason}` и
  `mq_kafka_commit_errors_total{topic, reason}` — по событиям читателя `offset_reset`,
  `decode_drop`, `read_error`, `commit_error`; серии засеваются нулём при старте читателя. Опция
  `kafka_readers:` плагина (провайдер — `Core.PubSub.MqSubscriberReliable.Supervisor.kafka_readers/1`)
  строит gauge'и `mq_kafka_reader_lease{component, topic}` и по партиции
  `mq_kafka_reader_lag_messages` / `mq_kafka_reader_lag_seconds`; отставание снимает владелец
  аренды, нода без неё отдаёт нули. Алерты `MqKafkaReaderLagging`, `MqKafkaReaderBacklog`,
  `MqKafkaReaderNoLease`, `MqKafkaOffsetReset`, `MqKafkaReadErrors`, `MqKafkaCommitErrors` и
  Kafka-вариант `MqDecodeDrops` — `docs/rules/21-observability.md`, «Отставание чтения Kafka».
  Подключение: было — `{Core.Mq.PromEx, readers: …}` → стало — плюс
  `kafka_readers: {MyApp.PromEx.Mq, :kafka_readers, []}`, провайдер склеивает `kafka_readers/1`
  деревьев подписчиков (`docs/rules/app/17-otp-concurrency.md`, «Наблюдение за процессами»).

- **`Core.Mq.Kafka.Partitioner`** — раскладка ключа по партициям, совместимая с
  `DefaultPartitioner` Kafka (`partition/2`, `murmur2/1`). Клиента не требует и компилируется
  всегда.

- **Фильтр `filter:` у `Core.PubSub.MqSubscriberReliable`** — предикат `Mq.Message.t() -> boolean()`
  по заголовкам, ключу и топику до `from_message`. Раньше решение «пропустить» принимал только
  `on_message`, то есть после декодирования тела, которое фильтр по заголовкам и должен сэкономить.
  `false` коммитит offset без `from_message` и без span'а `"process <topic>"`; исход `run_once/1` и
  метка `result` у `mq_subscriber_cycles_total` — `filtered`, отдельно от `{:skip, _}` обработчика
  (`processed`). Исключение в фильтре и не-boolean — ошибка обработки без commit, с повторами и
  выходом в DLQ. Без опции подписчик пропускает всё, как раньше; опция проходит и через
  `MqSubscriberReliable.Supervisor`. Правка подписчика, которому хватает заголовков: было —
  `on_message` возвращает `{:skip, :irrelevant_event}` по `message.headers` после разбора тела →
  стало — `filter: &(&1.headers["type"] in @types)`, `from_message` видит только нужное
  (`docs/rules/app/14-events-outbox.md`, «Подписчики»).

- **Отказ без повторов `{:reject, %Error{}}` у `Core.PubSub.MqSubscriberReliable`** — исход
  `on_message` (`PubSub.handler_result()`) и `from_message` (новый тип
  `PubSub.decode_result(message)`) для сообщения, которое не обработать никогда: тело не
  разбирается, запись нарушает инвариант. Раньше такое сообщение проходило `max_attempts`
  повторов с backoff до `retry_max_ms`, и всё это время партиция стояла. Отказ публикует сырое
  сообщение в DLQ сразу и коммитит offset; исход `run_once/1` — `:dlq`. Отказ отличим от
  исчерпания попыток: заголовок DLQ-сообщения `x-dlq-reason` (`rejected` / `exhausted`), ключ
  `reason` в metadata `[:mq, :subscriber, :dlq]`, метка `reason` у `mq_subscriber_dlq_total`,
  атрибут `core.pubsub.dlq_reason` span'а `"process <topic>"`. Без `dlq_writer` отказ — как
  исчерпание попыток без DLQ: `error` в лог, без commit, повторы. Правка подписчика: было — неразбираемое тело даёт
  `{:error, _}` (повторы) или `{:skip, :unprocessable}` (сообщение теряется) → стало —
  `{:reject, error}` при настроенном `dlq_writer` (`docs/rules/app/14-events-outbox.md`,
  «Подписчики»).

- **DLQ подписчиков в Postgres — `Core.Mq.Dlq`.** Топики внешнего источника принадлежат не
  потребителю: завести рядом `<topic>.dlq` он не может, а Stream-DLQ не принимает tombstone и
  байтовый ключ. `Core.Mq.Dlq.Writer` — `Mq.Writer` в таблицу `mq_dlq` БД приложения, подключается
  `dlq_writer:` подписчика: строка `dead` с топиком источника, ключом, заголовками, телом, позицией
  источника (`NULL`, если адаптер её не отдал), причиной (`x-dlq-reason`), ошибкой и временем.
  Оператор возвращает записи в обработку — `mix mq.dlq.requeue --all` / `--topic <топик>` /
  `--id <id>` или `Core.Mq.Dlq.Release.requeue/2` в задаче релиза; `Core.Mq.Dlq.Reader` —
  `Mq.ReaderReliable` из таблицы, под подписчиком с тем же обработчиком, что у исходного топика;
  `commit` помечает запись `processed`, не удаляя. Tombstone, байтовый ключ, `key: nil` и значения
  заголовков не в UTF-8 переживают выброс и перечитывание без искажения. Подписчик теперь
  передаёт в DLQ-сообщение позицию источника; writer'ы брокеров её по-прежнему не читают.

  Подключение: миграция со своим timestamp, делегирующая `Core.Mq.Dlq.Migration` (README,
  «Миграции»); было — `dlq_writer: {Core.Mq.Stream.Writer, …}` у подписчика на Kafka → стало —
  `dlq_writer: {Core.Mq.Dlq.Writer, repo: MyApp.DAO, subscriber_name: …, name: …}` и отдельное
  дерево перечитывания (`docs/rules/app/14-events-outbox.md`, «DLQ в Postgres»). Метрика —
  опция `dlq_repo:` плагина `Core.Mq.PromEx`: gauge `mq_dlq_count{subscriber, topic, status}`;
  алерт `MqDlqRequeuedStuck` — `docs/rules/21-observability.md`, «Рекомендованные алерты».

## 0.9.0

### Ломающие изменения контракта

- **`wait` в `Prefer` принимает десятичную дробь; поле `%Core.Web.Prefer{}` — `wait_ms`**
  (`docs/rules/app/15-web-api.md`, «Ожидание проекции»). Клиенту нужно ждать проекцию меньше секунды,
  а RFC 7240 даёт `wait` только целым: `wait=0.2` был неразборчив, игнорировался, и клиент ждал полный
  предел хелпера. Теперь `wait=N` MAY с дробной частью — шире RFC, точность — миллисекунда, разряды
  дальше округляются вверх (положительное `N` не становится нулём, `wait=0.0` — как `wait=0`).
  `Core.Web.Prefer.applied/3` сообщает применённое тоже с дробной частью и без округления предела
  вверх: было — `wait=1` при пределе 50 мс → стало — `wait=0.05`; целое по-прежнему без точки.
  Решение и отвергнутые варианты — `docs/adr/0031-prefer-wait-accepts-decimal.md`.

  Правка кода нужна, только если он матчит поле структуры: было — `%Core.Web.Prefer{wait: seconds}`
  в секундах → стало — `%Core.Web.Prefer{wait_ms: ms}` в миллисекундах. Хелпер `MyAppWeb.Accepted`,
  который зовёт `parse/1`, `mode/2` и `applied/3`, не меняется.

  Правка операций — описание параметра-заголовка `Prefer` в `MyAppWeb.Schemas.Prefer`, если оно
  называет `N` целым или задаёт `pattern`: было — «`wait=N`, `N` — целые секунды» → стало — «`N` —
  секунды, MAY с дробной частью (`wait=0.2`)».

## 0.8.0

### Ломающие изменения контракта

- **`Core.PromEx.Safe.execute/4` и `collect/4` вместо `/2`.** Обёртка сбора теперь эмитит
  событие отказа, и ей нужны имя плагина для события и закрытое имя polling-группы для тега
  `collector` (пункт «Отказ сбора gauge'ей» ниже). Свой плагин потребителя, зовущий `Safe`: было —
  `Safe.execute("my label", fun)` → стало — `Safe.execute(:my_plugin, :my_group, "my label", fun)`
  и `Safe.error_metric(metric_prefix, :my_plugin)` в event-метриках плагина.

- **Ожидание проекции после команды управляется заголовком `Prefer` клиента**
  (`docs/rules/app/15-web-api.md`, «Ожидание проекции»). Ярус обязывал каждую команду event-sourced
  агрегата ждать проекцию до ответа, даже когда клиенту read-модель после команды не нужна, — он
  платил за это временем ответа до таймаута хелпера. Теперь без заголовка поведение прежнее
  (дождался — 200, нет — 202), а клиент отказывается от ожидания или ограничивает его по RFC 7240:
  `Prefer: respond-async` (и `wait=0`) — сразу 202 с `{id, version}` без `await`, `wait=N` — ждать не
  дольше `min(N с, предел хелпера)`; применённое сервер сообщает в `Preference-Applied` по итоговому
  статусу (`respond-async` — только на 202). Без ожидания ответ всегда 202 — 200 по-прежнему значит
  «`GET` уже видит запись». `Prefer` MUST понимать каждая команда event-sourced агрегата; usecase
  проекцию не ждёт ни на одной границе
  (`docs/rules/app/10-architecture.md`, «Usecases»; `docs/rules/22-projections.md`,
  «Read-after-write»). Решение и отвергнутые варианты — `docs/adr/0030-prefer-controls-projection-await.md`.

  Правка хелпера `MyAppWeb.Accepted`: было — `respond(conn, awaited, {id, version}, render)` и
  `written(conn, awaited, id, version)` с результатом ожидания → стало — колбэк ожидания вместо
  результата; хелпер разбирает `Prefer` через `Core.Web.Prefer`, ставит `Preference-Applied` и зовёт
  колбэк с таймаутом из `Core.Web.Prefer.mode/2` либо не зовёт вовсе. Пока хелпер не переведён —
  строка `DEBT.md` приложения.

  Правка экшенов: было — `MyAppWeb.Accepted.respond(conn, Projection.await(Agg, id, 5_000), …)` →
  стало — `MyAppWeb.Accepted.respond(conn, &Projection.await(Agg, id, &1), …)`; то же у `written/4`.
  Сборка сверяет агрегат и ID и внутри захвата; ID по-прежнему сужен до `%Agg.ID{}`.

  Правка операций: параметр-заголовок `Prefer` и заголовок ответа `Preference-Applied` на 200 и 202
  каждой команды event-sourced агрегата — общими определениями `MyAppWeb.Schemas.Prefer` в корне web.
  Тест хелпера как чистой функции проходит три ветки `Prefer` (`docs/rules/app/19-testing.md`,
  «Event sourcing»).

### Новое

- **`name:` в `watch:` у `Core.Workers.PromEx` принимает `GenServer.name()`**
  (`docs/rules/app/17-otp-concurrency.md`, «Наблюдение за процессами»). Элемент был
  `%{component, name: atom()}` с `Process.whereis/1`, и процесс под `{:via, …}` (`Oban` — через
  `Oban.Registry`) под наблюдение не вставал: `WorkerDown` его падения не ловил. Теперь имя
  разрешает `GenServer.whereis/1` — атом, `{:global, _}` и `{:via, _, _}`. Незапущенный или
  отвечающий исключением реестр даёт сэмпл отсутствующего процесса (`up` 0), а не отказ всего цикла;
  процесс на другой ноде кластера — `up` 1 с mailbox и памятью 0: их публикует его нода. Метка
  `component`, имена метрик и сведение элементов с одной меткой не менялись. Атомарный `name:`
  работает как раньше; новый элемент: `%{component: "oban", name: Oban.Registry.via(Oban)}`.

- **Алерты на единичное событие поднимаются на первое событие новой серии счётчика**
  (`docs/rules/21-observability.md`, «Первое событие серии счётчика»). Серия `counter` появляется
  после первого события сразу с 1, и `increase(x[5m]) > 0` этот инкремент не видел: единичное
  сообщение в DLQ или единичный отказ публикации после старта ноды проходили молча. Засеять эти
  серии нулём нельзя — у всех шести счётчиков есть открытая метка (`topic`, `dlq_topic`, `cache`).
  Условия `OutboxFailedDelivery`, `MqPublishErrors` (и варианта Kafka), `MqDecodeDrops`,
  `MqSubscriberDlq`, `CacheUnavailable`, `CacheStoreErrors` получили правую ветку — серию, у которой
  не было точек окно назад: `last_over_time(x[5m] offset 5m)`, фильтр повторён в каждом `x`.
  Мгновенный `x offset 5m` не годится: единичный пропуск скрейпа оставляет staleness marker, и через
  окно алерт поднялся бы по каждой ненулевой серии цели. Цена — ложное срабатывание после разрыва
  скрейпа дольше окна. Решение и отвергнутые варианты — `docs/adr/0029-counter-first-event.md`.

  Правка правил алертов у себя: было — `sum by (topic, dlq_topic)
  (increase(my_app_prom_ex_mq_subscriber_dlq_total[5m])) > 0` → стало — то же
  `or sum by (topic, dlq_topic) (my_app_prom_ex_mq_subscriber_dlq_total unless
  last_over_time(my_app_prom_ex_mq_subscriber_dlq_total[5m] offset 5m)) > 0`; для остальных пяти —
  строки таблицы.
  Код и конфигурацию `Core.*.PromEx` менять не нужно.

- **Отказ сбора gauge'ей: `…_collect_errors_total{collector}` и алерт `PromExCollectFailing`**
  (`docs/rules/21-observability.md`, «Рекомендованные алерты»). Сбор polling-метрик под
  `Core.PromEx.Safe` при недоступной БД или провайдере писал `warning` и ничего не эмитил: gauge
  держал последнее значение, и `EsProjectionLagging`, `OutboxOldestNewHigh` и соседи молчали ровно
  тогда, когда что-то сломано. Теперь каждый пропущенный цикл, кроме `warning`, считает счётчик
  `my_app_prom_ex_<плагин>_collect_errors_total{collector}` — он объявлен во всех пяти плагинах
  (`Core.Es.PromEx`, `Core.Mq.PromEx`, `Core.Outbox.PromEx`, `Core.Cache.PromEx`,
  `Core.Workers.PromEx`), `collector` — имя polling-группы: `projections`, `processes`, `readers`,
  `queue`, `sizes`, `workers`; отказ одного reader'а засчитывается группе `readers`. Счётчик, а не
  gauge времени последнего успешного сбора: у gauge нет серии, если сбор не удался ни разу с
  запуска ноды, — решение в moduledoc `Core.PromEx.Safe`. Норма `docs/rules/app/21-observability.md`
  о сбое провайдера уточнена: сбой виден `PromExCollectFailing`.

  Что завести у себя: алерт `PromExCollectFailing` из таблицы со своим `for:`. Конфигурацию
  плагинов менять не нужно.

- **Исход резерва ключа: `my_app_prom_ex_es_key_reservation_total{scope, result}` и алерт
  `EsKeyReservationUnresolved`** (`docs/rules/21-observability.md`, «Рекомендованные алерты»).
  `:reservation_unresolved` у `Core.Es.KeyReservation` — аномалия состязания (`:app`), но уходила
  только вызывающему: рост таких отказов был виден лишь по ошибкам на границе. Теперь итоговый исход
  каждого `{:reserve, value}` эмитит telemetry `[:es, :key_reservation]` с метаданными `scope` и
  `result` (`:reserved` / `:taken` / `:unresolved`), а event-группа `Core.Es.PromEx` считает его
  счётчиком `my_app_prom_ex_es_key_reservation_total`. Повтор внутри резерва второго события не
  даёт, `:release` и `:keep` событий не дают; значения ключа и `aggregate_id` в метках нет — ПДн и
  растущая кардинальность. Условие алерта — с правой веткой `x unless last_over_time(x[5m] offset
  5m)`: отказ единичный, а серии нулём засеять некому — у резервов нет процесса-владельца.

  Что завести у себя: алерт `EsKeyReservationUnresolved` из таблицы. Код и конфигурацию
  `Core.Es.PromEx` менять не нужно — метрика строится всегда.

- **Метрики сигнала чекпоинта и алерт `EsProjectionSignalLost`** (`docs/rules/22-projections.md`,
  «Эксплуатация»). Потеря соединения слушателя `Core.Es.Projection.Listener` и `LISTEN` за pgbouncer
  в transaction mode не были видны ничем: `await` молча доходил шагами страховки. Теперь event-группа
  `Core.Es.PromEx` отдаёт `es_projection_signal_sent_total` — сигналы, отправленные пачками читателей
  ноды после commit, — и `es_projection_signal_received_total` — полученные её слушателем, обе с
  меткой `repo`. Каждая слушающая нода получает все уведомления канала, поэтому нода, не получившая
  ничего, пока кластер отправлял, — отказ быстрого пути. Слушатель засевает обе серии нулём при
  старте; при `notifications: false` серий нет. Флаг подписки не ловит pgbouncer, где `LISTEN`
  проходит, а уведомления теряются, — решение и отвергнутые варианты —
  `docs/adr/0028-checkpoint-signal-observability.md`.

  Что завести у себя: алерт `EsProjectionSignalLost` из таблицы «Эксплуатация» со своим `for:` и
  тест `promtool test rules` по примеру оттуда. Код и конфигурацию `Core.Es.PromEx` менять не
  нужно — метрики строятся всегда.

- **`Core.Web.Prefer` — разбор заголовка `Prefer` (RFC 7240) для ожидания проекции.** `parse/1`
  разбирает значения заголовков (`respond-async`, `wait=N`; регистр, кавычки и параметры после `;`
  учтены, неизвестное и неразборчивое игнорируется, из повторов учитывается только первое),
  `mode/2` при серверном пределе отдаёт `:respond_async | {:wait, ms}`, `applied/3` — значение
  `Preference-Applied` по итоговому статусу 200 / 202 либо `nil`.

## 0.7.0

### Ломающие изменения контракта

- **Создание отвечает `{id, version}` / `{id}` общими схемами корня web**
  (`docs/rules/app/15-web-api.md`, «Раскладка», «Controller», «Ожидание проекции»). Ярус описывал
  ответ команды event-sourced агрегата представлением, а создание не выделял: версию после создания
  клиент не угадает (создание пишет несколько событий), без неё не пошлёт следующий `If-Match`, а
  202 с `{id, version}` отдавал её только тогда, когда представление не готово. Теперь создание
  event-sourced агрегата ждёт проекцию, как любая команда, и отвечает `{id, version}` одной схемой
  `MyAppWeb.Schemas.Written` на 200 и на 202 — статус несёт готовность представления. Ответ собирает
  `MyAppWeb.Accepted.written/4` (`conn`, результат ожидания, `id`, `version`) рядом с `respond/4`;
  операция команды объявляет `Written` в `accepted:`, операция создания — ещё и в `ok:`. Создание
  state-stored агрегата отвечает `{id}` схемой `MyAppWeb.Schemas.Created`. `Written` и `Created`
  MUST лежать в корне `MyAppWeb.Schemas` при любом числе поверхностей — исключение из лестницы схем.
  Решение и отвергнутые варианты — `docs/adr/0027-create-responds-id-and-version.md`.

  Правка экшена создания event-sourced агрегата: было — `json(conn, Response.success(%{id: …}))`
  или представление после ожидания → стало — `{:ok, {id, version}}` из usecase и
  `MyAppWeb.Accepted.written(conn, Projection.await(Agg, id, timeout), id, version)` в `defp` с
  суженным ID.

  Правка операций: схема 202 любой команды event-sourced агрегата, своя у ресурса или версии →
  `MyAppWeb.Schemas.Written` в `accepted:`; схема `{id}` state-stored создания в namespace
  поверхности → `MyAppWeb.Schemas.Created`. Строка `DEBT.md` приложения об ответе создания
  `{id, version}` вместо представления снимается.

## 0.6.0

### Ломающие изменения контракта

- **Путь файла = имя модуля, модуль-оглавление и направления зависимостей контекста:
  `boundary_lint --consumer` проверяет раскладку `lib/`** (`docs/rules/app/10-architecture.md`,
  «Раскладка»). Таблица namespaces и деревья файлов свода потребителя не несли модальности и
  формально были пояснением, а модуль не по пути не находился по имени ни читателем, ни агентом.
  Теперь путь файла от `lib/` MUST совпадать с `Macro.underscore` имени модуля (`MyApp.HTTPClient` —
  `lib/my_app/http_client.ex`), в файле MUST быть один верхнеуровневый модуль (вложенные следуют за
  родителем), mix-таска лежит по конвенции Mix (`Mix.Tasks.Foo.Bar` — `lib/mix/tasks/foo.bar.ex`).
  Проверка включена сразу ошибкой шага `boundary-check`; событие и команда, вложенные в семейство
  `<Aggregate>.Event` / `<Aggregate>.Cmd`, — нарушение `module-path`; правила видят и вложенные
  модули, `defprotocol` и `defimpl` (ссылки `defimpl` — ссылки модуля из `for:`), а файл, который не
  разбирается, даёт код 2 с путём; `test/` проверяется, как и прежде, только на DI. Таблица
  namespaces дополнена `MyApp.StreamID`, `MyApp.MetricsServer`, `MyApp.Release`, `Mix.Tasks.*`; явно
  записано: потребитель — один Mix-проект, один `otp_app`, один `DAO`, umbrella не поддерживается.
  Решение и отвергнутые варианты — `docs/adr/0023-consumer-layout-enforced.md`.

  Bounded context состоит из `<BC>.Common` и срезов: срез — операции одного инициатора (роли
  пользователя или системного процесса, `System` — пример), модулей в корне контекста нет (правило
  `bc-root`: срез — namespace, объявленный модуль `MyApp.Domain.<BC>.<X>` при `X` не `Common` —
  модуль в корне; ссылки на него правила срезов не считают), часть приложения без агрегатов MUST
  быть подсистемой `MyApp.<Subsystem>`, а не контекстом; аксессор текущего пользователя без агрегата
  учётной записи — в подсистеме `MyApp.Auth` («Состав контекста», `docs/rules/app/11-domain.md`,
  «Context»). Тип, который вводит модель контекста и который его агрегат хранит в состоянии, MUST
  лежать в `<BC>.Common` этого контекста, а механизм над моделью (макрос DSL, проверка, реестр
  механизма) SHOULD быть подсистемой — кроме билдера, который модель сама подключает, и реестра
  адаптеров одного контекста; собственный тип подсистемы остаётся в ней, значение, общее нескольким
  контекстам, — в `Common` контекста, который его вводит. Ключ механизма, который агрегат сам не
  читает, а читают механизм и его декларации в usecases (`<Aggregate>.ns/0`), MUST лежать у
  механизма, а не в агрегате. Два контекста SHOULD NOT ссылаться друг на друга напрямую: взаимные
  ссылки — признак одной модели; путь через подсистему циклом не считается. Признаки держатся ревью,
  линтер их не проверяет (`docs/adr/0025-model-types-in-common.md`). Направления не были
  нормированы, и `Common` уже звал срез своего контекста. Теперь `Common` MUST NOT ссылаться на
  срезы своего контекста (правило `common-slice`), контекст MUST NOT ссылаться на срезы чужого —
  только на его `Common` (правило `foreign-slice`), срез MUST NOT ссылаться на соседний срез своего
  контекста — общее переезжает в `Common`, операция двух инициаторов — свой usecase в каждом срезе
  (правило `sibling-slice`). Подсистема для контекста — такой же чужой: срез звал бы чужой срез
  через неё в обход `foreign-slice`, поэтому она MUST NOT ссылаться на срезы — только на `Common`
  (правило `subsystem-slice`); контекст ссылается на подсистему свободно. На любой срез ссылается
  только закрытый список сборки и точек входа: `MyAppWeb` и `Mix.Tasks.*` с вложенными;
  `MyApp.Application` и `MyApp.Projections` — сами модули; `MyApp.Codec`, `MyApp.PromEx`,
  `MyApp.Release` — с вложенными; прочий модуль вне `Domain`, включая строки таблицы namespaces и
  модуль с другим корнем в `lib/`, проверяется как подсистема. Задача оператора, общая для mix-таски
  и `bin/` (стартовая инициализация, наполнение стенда), MUST лежать в `MyApp.Release.<Name>`.
  Ссылка разрешается через `alias` (включая `alias A.{B, C}` и `as:`), `__MODULE__` и полное имя;
  нарушение ставится на строку вызова.

  У контекста не было точки входа: из чего он состоит, было видно только по дереву каталогов.
  Теперь каталог `lib/my_app/domain/<bc>/` MUST иметь модуль-оглавление `MyApp.Domain.<BC>` в
  `lib/my_app/domain/<bc>.ex` (правило `bc-index`); его `@moduledoc` SHOULD давать карту контекста —
  назначение, агрегаты, срезы, read-модели, компоненты, ссылки на другие контексты; содержание
  линтер не проверяет. Оглавление лежит на уровне `domain/`, поэтому модулем в корне контекста не
  считается («Модуль-оглавление»).

  Как править код потребителя: модуль переносится в файл по своему имени, второй верхнеуровневый
  модуль — в свой файл. Модуль в корне контекста переезжает в `Common` (без привязки к инициатору)
  или в срез своего инициатора. Нужное `Common` из среза переезжает в `Common`; ссылка на чужой срез
  заменяется ссылкой на `Common` того контекста. DSL из корня контекста делится: тип, который хранит
  агрегат, — в `Common`, механизм — в подсистему, а ключ `ns/0` — из агрегатов в реестр механизма.
  Компонент подсистемы, который ссылается на срез (зовёт его usecases, ставит его воркер),
  переезжает в срез своего инициатора, а в подсистеме остаётся часть без доменной логики; задача
  оператора верхнего уровня (`MyApp.QuickStart`) — в `MyApp.Release.QuickStart`. Рядом с каталогом
  каждого контекста заводится файл оглавления:

  ```elixir
  # было
  defmodule MyApp.Domain.<BC>.Errors do
  alias MyApp.Domain.Billing.Admin.Usecases   # из MyApp.Domain.Orders.*
  defmodule MyApp.QuickStart do

  # стало
  defmodule MyApp.Domain.<BC>.Common.<Aggregate>.Errors do
  alias MyApp.Domain.Billing.Common
  defmodule MyApp.Release.QuickStart do

  # lib/my_app/domain/<bc>.ex
  defmodule MyApp.Domain.<BC> do
    @moduledoc "<назначение>; агрегаты, срезы, read-модели, компоненты, другие контексты."
  end
  ```

  Сознательное отступление — строка в `DEBT.md` и маркер в блоке комментариев прямо над `defmodule`;
  он гасит только названное правило (`module-path`, `common-slice`, `foreign-slice`,
  `sibling-slice`, `subsystem-slice`, `bc-index`, `bc-root`, `projection-layout`, `web-root`) и
  только в своём модуле (`bc-index` — в любом модуле каталога контекста: нарушение принадлежит
  каталогу), без ссылки на раздел `DEBT.md` не гасит ничего:

  ```elixir
  # было — lib/my_app/domain/<bc>/common/<aggregate>/repository.ex
  defmodule MyApp.Domain.<BC>.Common.<Aggregate>.Repo do

  # стало — lib/my_app/domain/<bc>/common/<aggregate>/repo.ex, либо отступление на месте
  # boundary-lint: allow module-path — DEBT.md, «Файл не по имени модуля»
  defmodule MyApp.Domain.<BC>.Common.<Aggregate>.Repo do
  ```

- **Read-модель — единица раскладки чтения: View, ReadRepo и проекция в одном каталоге, проекция на
  read-модель пишет свои таблицы сама** (`docs/rules/app/13-repos.md`, «Read-модель», «Проекции
  read-модели»). Чтение event-sourced агрегата было разнесено на три места — View и ReadRepo под
  агрегатом, `<Aggregate>.ReadRepo.Pg.Projector` под ReadRepo и одна проекция контекста в
  `common/projection.ex`, — read-модель через два агрегата лежала под одним из них, а подъём
  `version:` единственной проекции пересобирал все таблицы контекста. Своды расходились и в том, где
  лежат View и репозиторий: в `Common` или в срезе роли. Теперь read-модель лежит в каталоге
  `<bc>/<scope>/<read_model>/` (`<scope>` — `common` или срез) с `view.ex`, `read_repo*` и
  `projection.ex`; имя — по назначению, по умолчанию имя агрегата, и тогда каталог общий с ним;
  чтение state-stored агрегата из своей таблицы лежит в каталоге агрегата. Если строка read-модели —
  один агрегат, а поля других агрегатов в ней — копии, read-модель лежит у этого агрегата; своё имя
  и каталог — когда строка не равна агрегату. Join на таблицы чужой read-модели MAY только для
  read-моделей `Common`, своей вложенной read-only схемой `<ReadModel>.ReadRepo.Pg.Schema.<Other>`,
  а View, вложенная целиком, — ассоциацией на схему владельца и её `to_view`; граница, которой нужна
  свежая строка, ждёт и проекцию присоединённой таблицы; таблицу read-модели среза читает только сам
  срез. Read-модель среза, которая отличается только ACL-фильтром, — actor-ReadRepo в срезе поверх
  read-модели `Common`, без своей таблицы и проекции. Read-модель без таблицы (значение, собранное
  на чтении сворачиванием потоков) MAY читать write-репозитории; как любая read-модель, она только
  отдаёт данные, решение над ними принимает читающий. Проекция MUST быть одна на read-модель
  (`<ReadModel>.Projection`, `name:` SHOULD называть read-модель) и MUST писать свои таблицы сама;
  отдельный модуль записи MUST NOT. Обе нормы проверяет правило `projection-layout`
  `boundary_lint --consumer`: модуль с `use Core.Es.Projection` —
  `<BC>.<Part>.<ReadModel>.Projection` (или `ProjectionV<N>`), модуль `*.Projector` под `ReadRepo` —
  нарушение; проекция — ровно в каталоге read-модели. На время перехода на новую проекцию вторая
  лежит в том же каталоге (`AccountList.ProjectionV2` в примерах `docs/rules/22-projections.md`).
  Репозиторий записи и read-модель лежат в `Common`, в срез переезжают вместе со своим ACL-фильтром
  или своей формой. Кеш read-модели и его супервизор `<ReadRepo>.Supervisor` лежат в её каталоге
  (`docs/rules/app/16-caching.md`).

  Как править код потребителя: проекция контекста делится на проекции read-моделей, тела
  проекторов переезжают приватными функциями в свою проекцию, View и ReadRepo — к ней в каталог.
  Проекция под новым `name:` стартует с начала истории, поэтому переход идёт по «Новая проекция»,
  а строка чекпоинта прежней проекции удаляется по «Удаление» (`docs/rules/22-projections.md`).

  ```elixir
  # было — lib/my_app/domain/<bc>/common/projection.ex
  defmodule MyApp.Domain.<BC>.Common.Projection do
    use Core.Es.Projection,
      name: "<bc>",
      events: [Order.Event.Placed, Shipment.Event.Sent]

    @impl true
    def project(%Order.Event.Placed{} = event), do: Order.ReadRepo.Pg.Projector.placed(event)

    def project(%Shipment.Event.Sent{} = event), do: Order.ReadRepo.Pg.Projector.sent(event)
  end

  # стало — lib/my_app/domain/<bc>/common/order/projection.ex и common/backlog/projection.ex
  defmodule MyApp.Domain.<BC>.Common.Order.Projection do
    use Core.Es.Projection,
      name: "order",
      events: [Order.Event.Placed]

    @impl true
    def project(%Order.Event.Placed{} = event), do: insert_row(event)
  end

  defmodule MyApp.Domain.<BC>.Common.Backlog.Projection do
    use Core.Es.Projection,
      name: "backlog",
      events: [Order.Event.Placed, Shipment.Event.Sent]

    @impl true
    def project(%Order.Event.Placed{} = event), do: insert_row(event)

    def project(%Shipment.Event.Sent{} = event), do: mark_sent(event)
  end
  ```

- **Модуль usecases по usecase и нормы раскладки слоёв** (`docs/rules/app/10-architecture.md`,
  «Usecases», «Файлы `config/`»). На вопросы «куда класть X» свод не отвечал, а примеры README и
  свода библиотеки называли модули иначе, чем ярус потребителя. Теперь:
  - модуль usecases — `MyApp.Domain.<BC>.<Actor>.Usecases.<Usecase>`, по умолчанию имя агрегата;
    операция над несколькими агрегатами — запись в два агрегата и больше, ни один из которых не
    подчинён другому (подчинённость — по происхождению id; операция лежит в модуле агрегата, чей id
    пришёл командой), — SHOULD быть своим usecase со своим модулем и возвращать версию агрегата, чью
    проекцию ждёт граница, а не ложиться в модуль одного из них; хелпер чтения, общий для usecases
    среза, — `<Actor>.Usecases.<Aggregate>.Query`; usecase над агрегатами двух контекстов лежит в
    срезе контекста, который зависит от второго, и пишет второй через его `Common`;
  - таблица «файл `config/` → что в нём»: `config.exs` — `compile_env` и DI-подмены, `runtime.exs` —
    env и тумблеры, `test.exs` — тестовый overlay; секреты и env в `dev.exs` / `prod.exs` MUST NOT —
    оба файла исполняются на сборке и запекают значение в релиз;
  - Prim вложен в агрегат-владелец по имени, файл отдельный или тот же — MAY; значение без
    владельца MUST лежать в `<BC>.Common.<Value>` (`docs/rules/app/11-domain.md`, «Prim и Enum»);
  - web: поверхность `MyAppWeb.<Api>` с `<Version>.<Resource>`, спецификация — на версию
    (`<Api>.<Version>.ApiSpec`: `servers` и `info.version` одни на документ); общее для поверхностей
    (`FallbackController`, `ErrorMapper`, `Presenters`, `Plugs`, `Schemas`) — в корне `MyAppWeb`;
    вложенный ресурс — вложенный namespace (`docs/rules/app/15-web-api.md`, «Раскладка»). Корень
    `MyAppWeb` закрыт: поверхности (namespace хотя бы с одним `MyAppWeb.<Api>.V<N>.ApiSpec`) и
    модули таблицы, в которую добавлены `Endpoint`, `Router`, `Telemetry`, `ErrorJSON` (в
    `lib/my_app_web/error_json.ex`, не в `controllers/`), `Response` (конверт `Core.Web.Response`) и
    `Params` — разбор входа; `Params`, презентеры и плаги поднимаются по той же лестнице уровней,
    что `Schemas`, `FallbackController` и `ErrorMapper` MAY быть своими у поверхности.
    `MyAppWeb.Accepted` — ответ 202 после ожидания проекции, один на приложение (был
    `MyAppWeb.Helper.Projection`). `Helper` и другие имена без роли MUST NOT: модуль одной
    поверхности лежит в её namespace. Ресурс группы (`/security/roles`) —
    `<Api>.<Version>.<Group>.<Resource>`. Проверяется правилом `web-root` линтера — одно нарушение
    на namespace, с числом прочих модулей — `boundary_lint --consumer`;
  - тест модуля SHOULD лежать по пути модуля; архитектурный тест и ратчеты — в `test/my_app/`,
    `ConnCase` и `DataCase` — в `test/support/`, ратчет web-слоя — в `test/my_app_web/`
    (`docs/rules/app/19-testing.md`, «Раскладка `test/`»);
  - каталог ошибок, которые возвращает не агрегат, лежит у модуля-владельца (`<Owner>.Errors`), в
    подсистеме — `MyApp.<Subsystem>.Errors`, с несколькими владельцами — в `Common` ближайшего
    общего контекста (`<BC>.Common.Errors`) (`docs/rules/app/12-errors.md`, «Словарь `ns`»);
  - `IO.puts` разрешён задачам релиза `MyApp.Release.*`: Mix в релизе нет, исключение
    `Refactor.IoPuts` — на `lib/my_app/release.ex` и `lib/my_app/release/`; `Readability.Specs`
    снимается только с контроллеров, а не со всего web (`docs/rules/app/20-agreements.md`,
    «Настройки Credo»).

  Как править код потребителя: usecase над несколькими агрегатами переезжает в свой модуль usecases,
  общая схема web — в `Schemas` ближайшего общего уровня, разборщик входа из `MyAppWeb.Parse` — в
  `Params` своего ресурса или ближайшего общего уровня, `MyAppWeb.Helper.Projection` — в
  `MyAppWeb.Accepted`, прочий модуль из `MyAppWeb.Helper` — в namespace своей поверхности, `ApiSpec`
  — на уровень версии (`<Api>.V1.ApiSpec`), `ErrorJSON` — из `controllers/` в
  `lib/my_app_web/error_json.ex`, чтение env из `dev.exs` / `prod.exs` — в `runtime.exs`:

  ```elixir
  # было
  defmodule MyApp.Domain.<BC>.<Actor>.Usecases.Cart do
    def checkout(cart_id, context), do: ...
  end

  defmodule MyAppWeb.<Api>.V1.Schemas.Envelope do   # общая для поверхностей
  defmodule MyAppWeb.Parse.OrderFilter do
  defmodule MyAppWeb.Helper.Projection do

  # стало
  defmodule MyApp.Domain.<BC>.<Actor>.Usecases.Checkout do
    def run(cart_id, context), do: ...
  end

  defmodule MyAppWeb.Schemas.Envelope do
  defmodule MyAppWeb.<Api>.V1.Order.Params.Filter do
  defmodule MyAppWeb.Accepted do
  ```

- **Компонент и его корень `<Component>.Supervisor`: `Application` перечисляет корни плоско**
  (`docs/rules/app/17-otp-concurrency.md`, «Дерево процессов», «Компонент», «Наблюдение за
  процессами»). Процессы одного назначения протекали в `Application`: кеш и его инвалидатор стояли
  разными детьми, проверки старта компонента лежали в `start/2`, реестр наблюдаемых процессов
  повторно вычислял тумблер каждого компонента, а дерево подписчика с DLQ копировалось в каждый
  супервизор. Теперь компонент — процессы одного назначения: всё, что включается вместе, MUST жить
  под одним корнем `<Component>.Supervisor`, и корень сам владеет тумблером (`:ignore` и `info`),
  сборкой опций, проверками старта и `watch_list/0`, отфильтрованной тем же тумблером. В
  `Application` остаются `Core.Config.validate!()`, проверки разделяемой инфраструктуры,
  инициализация общего состояния без процессов (реестр в `:persistent_term` — не компонент, корень
  для неё был бы супервизором без детей; нужен процесс дерева — шаг-ребёнок с `:ignore` после него),
  сама инфраструктура, корни компонентов и готовые деревья Core с тумблером без своего корня
  (`Core.Es.Projection.Supervisor`, `<Aggregate>.Process`; список процессов и их опции собирает
  `MyApp.Processes`); `Oban` — разделяемая инфраструктура, модуль воркера `Oban.Worker` — не
  компонент и лежит в срезе того usecase, который ставит задачу. Компонент — процессы одного
  назначения, тумблер MAY; соединение с одним пользователем живёт в корне этого пользователя,
  тумблер разделяемой инфраструктуры — функция её владельца. Свой цикл `send_after` — только для
  локального состояния процесса, работа с данными — через планировщик. `strategy: :one_for_one`
  остаётся: порядок детей `Application` — только порядок старта, `rest_for_one` каскадом
  перезапускал бы всё после упавшего ребёнка. Часть компонента, без которой он работает в
  ослабленном режиме (инвалидатор кеша), MAY иметь подчинённый тумблер внутри корня. Процесс
  компонента отдельным ребёнком, проверка компонента в `start/2` и корень над корнями компонентов —
  MUST NOT. `watch_list/0` приложения — конкатенация списков компонентов и готовых деревьев плюс
  элементы разделяемой инфраструктуры (соединение с брокером, `Oban`), которые перечисляет сам
  провайдер `MyApp.PromEx.Workers`; вычислять тумблер компонента в реестре второй раз — MUST NOT.
  Компонент лежит в срезе своего инициатора (ссылается на срез), в подсистеме (на срезы не
  ссылается; туда же — техническое состояние без версии и событий: сессии, журнал прогонов) или в
  каталоге read-модели (кеш); в `Common` вне каталога read-модели — MUST NOT.
  `Core.Outbox.check_singleton!/1` и `Core.Outbox.validate_partition!/1` переехали из `start/2` в
  корень очереди `MyApp.Outbox.Supervisor`, ратчет приложения — на вызов оттуда. Решение и
  отвергнутые варианты — `docs/adr/0024-component-owns-its-subtree.md`.

  Как править код потребителя: процессы компонента и его проверки старта переезжают из
  `Application` в корень компонента, реестр наблюдаемых процессов склеивает `watch_list/0` корней,
  компонент из `Common` переезжает в срез своего инициатора или в подсистему:

  ```elixir
  # было
  def start(_type, _args) do
    Core.Config.validate!()
    Core.Outbox.check_singleton!(outbox_opts)

    children = [
      MyApp.DAO,
      {Cachex, name: <ReadRepo>.Cache},
      <ReadRepo>.Supervisor,
      MyApp.Outbox.Supervisor,
      MyApp.<Subsystem>.Supervisor
    ]
  end

  def watch_list do
    if Application.fetch_env!(:my_app, MyApp.<Subsystem>.Supervisor)[:enabled],
      do: [%{component: "<subsystem>", name: MyApp.<Subsystem>.Worker}],
      else: []
  end

  # стало — Cachex под <ReadRepo>.Supervisor, check_singleton! в start_link/1 корня очереди,
  # реестр без процессов — в start/2
  def start(_type, _args) do
    Core.Config.validate!()
    MyApp.<Subsystem>.Registry.load!()

    children = [MyApp.DAO, <ReadRepo>.Supervisor, MyApp.Outbox.Supervisor, MyApp.<Subsystem>.Supervisor]
  end

  def watch_list do
    [%{component: "mq_connection", name: MyApp.Mq.Connection}] ++
      <ReadRepo>.Supervisor.watch_list() ++
      MyApp.Outbox.Supervisor.watch_list() ++
      MyApp.<Subsystem>.Supervisor.watch_list()
  end
  ```

### Новое

- **Шаг с результатом в `bind`: `Result.and_then/2` принимает `:ok`** (`Core.Result`, `Core.Bind`).
  `bind` снимал лестницу только у bracket-шагов, а цепочку результатов свод отдавал `with`, и
  смешанная цепочка оставалась `with` внутри `Transact.run(DAO, fn -> … end)`. Теперь справа от
  `<-` стоит `Result.and_then(call)` — форма `result.try` из Gleam: `x <-` принимает `{:ok, x}`,
  `[] <-` — `:ok`, ошибка становится итогом блока. Для этого `and_then/2` на `:ok` вызывает
  нуль-арный колбэк (было `FunctionClauseError`), на `{:error, _}` пропускает колбэк любой из двух
  арностей; `:ok` с одноарным и `{:ok, v}` с нуль-арным колбэком — по-прежнему
  `FunctionClauseError`; `@spec` обеих клауз допускают колбэк с unit-результатом. `else` у `bind`
  нет: ошибка шага правится `Result.map_error/2` справа до `and_then`, ошибка блока —
  `bind do … end |> Result.map_error(…)` или `|> case do … end`. Запрет свода на цепочку
  результатов в `bind` снят, норма — `20-agreements.md`, «Вложенные колбэки: `bind`»; решение —
  `docs/adr/0026-bind-result-steps.md`.

  Как править код потребителя: править не нужно; смешанную цепочку MAY переписать —
  `Transact.run(DAO, fn -> with {:ok, s} <- get(…), {:ok, _} <- save(s, …) do :ok end end)` →
  `bind do [] <- Transact.run(DAO, _); s <- Result.and_then(get(…)); … end`.

- **Повтор метки в `watch:` и `readers:` больше не скрывает упавший процесс**
  (`Core.Workers.PromEx`, `Core.Mq.PromEx`). Метку процесса задаёт строка списка потребителя, и два
  элемента с одной меткой ничто не запрещало: `last_value` оставлял значение последнего, и живой
  процесс скрывал упавший. Теперь элементы с одной меткой (`component`, у reader'ов — пара
  `component` и `topic`) сводятся: `up` и `subscribed` — минимум, `message_queue_len` и `pending` —
  максимум, `memory`, `buffer_len` и `chunk_remaining` — сумма; повтор — `error` в лог один раз на
  набор повторов на ноде для каждого экземпляра плагина, независимо от порядка элементов в списке
  (`Core.PromEx.Labels`); процесс, умерший между `whereis` и `info`, даёт `up=0`. У reader'ов
  сводятся только живые: топик известен живому процессу. Метка MUST быть уникальна в склеенном
  списке (`app/17-otp-concurrency.md`, «Наблюдение за процессами»).

  Как править код потребителя: лог «PromEx: метка повторяется» называет метку и имена процессов —
  одну из меток переименовать; у дерева подписчиков — развести `component:`.

- **Дерево подписчиков брокера с DLQ — `Core.PubSub.MqSubscriberReliable.Supervisor`**
  (`docs/rules/14-events-outbox.md`, «Идемпотентность потребителей»). Порядок детей поддерева
  подписчиков — MUST свода (`app/17-otp-concurrency.md`, «Дерево процессов»), но держался он копией
  супервизора в каждом компоненте приложения, и копии расходились. Теперь дерево строит библиотека:
  `rest_for_one`, DLQ-writer (если задан), затем на каждый топик читатель и его подписчик с
  `subscribe: true`; handle читателя и DLQ-writer'а — их `name:`, дерево само передаёт их
  подписчику. `enabled: false` и `topics: []` — `:ignore` с `info`, как у
  `Core.Es.Projection.Supervisor`; `watch_list/1` принимает те же опции, что и старт. Метку
  `component` метрик строят обязательная строка `component:` дерева и топик подписчика
  (`mq_dlq_writer:<component>`, `mq_reader:<component>:<топик>`,
  `mq_subscriber:<component>:<топик>`), а не имя процесса: перенос модуля компонента между слоями не
  рвёт ряды метрик и заглушки по `component`; повтор топика в дереве, повтор имени процесса (оно —
  `id` ребёнка) и `:` в `component:` (разделитель метки) — `ArgumentError` до старта. `readers/1`
  отдаёт stream-читателей дерева для `readers:` плагина `Core.Mq.PromEx` с той же меткой, что у
  `mq_reader` в `watch_list/1`: список читателей больше не собирается вручную со своими метками.
  Config и env библиотека не читает.

  Как править код потребителя: собственный супервизор подписчиков заменяется деревом — теперь это
  MUST свода потребителя (`app/17-otp-concurrency.md`, «Дерево процессов»); опции собирает корень
  компонента, он же отдаёт их `watch_list/1` и `readers/1`, а `readers/0` приложения склеивает
  списки корней, как `watch_list/0` («Наблюдение за процессами»).

  ```elixir
  # было — порядок детей и связки опций в каждом компоненте свои
  children = [
    {Core.Mq.Stream.Writer, dlq_opts},
    {Core.Mq.Stream.Reader, reader_opts},
    {Core.PubSub.MqSubscriberReliable,
     subscriber_opts ++
       [reader_module: Core.Mq.Stream.Reader, reader: Reader, dlq_writer: Core.Mq.Stream.Writer,
        dlq_handle: Dlq, subscribe: true]}
  ]

  Supervisor.init(children, strategy: :rest_for_one)

  # стало
  {Core.PubSub.MqSubscriberReliable.Supervisor,
   enabled: true,
   component: "notify",
   dlq_writer: {Core.Mq.Stream.Writer, dlq_opts},
   topics: [[reader: {Core.Mq.Stream.Reader, reader_opts}, subscriber: subscriber_opts]]}

  # MyApp.PromEx.Mq
  def readers, do: MyApp.Notify.Supervisor.readers()
  ```

### Изменения контракта макросов

- **`use Core.Es.Projection`: событие вне семейства `<Aggregate>.Event` — `CompileError`.** Кодек
  события и агрегат `await/3` проекция находит по родителю модуля события. Событие из семейства с
  другим именем (`<Aggregate>.Events.<Name>` рядом с `<Aggregate>.Events.Codec`) собиралось, но
  clause `await/3` для его агрегата молча не создавалась, и ошибка всплывала `FunctionClauseError`
  в рантайме. Теперь сборка падает с текстом, называющим событие и форму
  `<Aggregate>.Event.<Name>` (`docs/rules/app/13-repos.md`, «Событие и команда»).

  Как править код потребителя: семейство событий переименовывается в `<Aggregate>.Event`, кодек —
  в `<Aggregate>.Event.Codec`, файлы — по раскладке:

  ```elixir
  # было
  use Core.Es.Projection,
    name: "accounts",
    events: [Account.Events.Opened]

  # стало
  use Core.Es.Projection,
    name: "accounts",
    events: [Account.Event.Opened]
  ```

## 0.5.0

### Ломающие изменения контракта

- **Событие и команда — каждое в своём файле** (`docs/rules/app/13-repos.md`, «Событие и
  команда»). Свод держал все события агрегата одним `event.ex` вложенными `defmodule`, а раскладку
  команд записывал неоднозначно (`{cmd,cmd/*.ex}`); на деле команды жили одним `cmd.ex` или прямо в
  модуле агрегата. Файл событий с нагрузками дорастал до сотен строк, а вложенность `Event` →
  `<Name>` → `Payload` прятала модуль: найти его по имени, не читая файл, было нельзя. Теперь
  событие (у агрегата любого вида) и команда MUST лежать в `event/<name>.ex` / `cmd/<name>.ex`,
  сколько бы их ни было; своя нагрузка события — вложенный `Payload` в том же файле. `event.ex` и
  `cmd.ex` — семейство: `@moduledoc`, `@type t` — объединение `t` членов — и помощники приложения
  над ним (`name/1`, `names/0`). Порога «одним файлом, пока маленький» нет — агрегат на границе
  переезжал бы туда и обратно. Имена модулей, wire-теги и кодек не меняются: правка — только
  перенос файлов, сборка кода на старой раскладке не ломается.

  Как править код потребителя: каждый вложенный `defmodule` из `event.ex` / `cmd.ex` (или `Cmd`
  из модуля агрегата) — в свой файл с полным именем модуля; алиасы, которые давала вложенность,
  прописать явно. У агрегата, где `Cmd` был вложен, добавить `alias <Aggregate>.Cmd`. Команде без
  `@type t` объявить его: `use Core.Es.Cmd` тип не даёт, а объединение в `cmd.ex` на него ссылается.

  ```elixir
  # было — <aggregate>/event.ex
  defmodule MyApp.Domain.<BC>.Common.<Aggregate>.Event do
    defmodule Opened do
      defmodule Payload do ... end

      use Es.Event,
        aggregate_id: <Aggregate>.ID,
        by: MyApp.Domain.Users.Common.User.ID,
        payload: Payload
    end

    defmodule Closed do ... end

    @type t :: Opened.t() | Closed.t()
  end

  # стало — <aggregate>/event/opened.ex
  defmodule MyApp.Domain.<BC>.Common.<Aggregate>.Event.Opened do
    alias MyApp.Domain.<BC>.Common.<Aggregate>

    defmodule Payload do ... end

    use Es.Event,
      aggregate_id: <Aggregate>.ID,
      by: MyApp.Domain.Users.Common.User.ID,
      payload: Payload
  end

  # стало — <aggregate>/event.ex
  defmodule MyApp.Domain.<BC>.Common.<Aggregate>.Event do
    @moduledoc "События агрегата."

    alias MyApp.Domain.<BC>.Common.<Aggregate>.Event.Closed
    alias MyApp.Domain.<BC>.Common.<Aggregate>.Event.Opened

    @type t :: Opened.t() | Closed.t()
  end
  ```

## 0.4.0

### Ломающие изменения контракта

- **`Result.map_error/2` и `Result.tap/2` принимают только три формы результата**
  (`Core.Result`). Обе функции заканчивались хвостовой клозой (`def map_error(ok, _fun), do: ok`,
  `def tap(other, _fun), do: other`), и любой терм проходил их насквозь: `map_error(:whatever, fun)`
  возвращал `:whatever`, `tap(%Foo{}, fun)` — `%Foo{}`. Спеки при этом описывали ровно
  `{:ok, a} | :ok | {:error, e}`, то есть рантайм расходился со спекой, а домен, который компилятор
  выводит из клоз, включал `term()`: неверный вызов проходил и сборку, и рантайм. Клозы развёрнуты
  в явные формы — правка приводит рантайм к уже написанной спеке (`20-agreements.md`, «Домен функции
  и инференс типов»: недопустимый ввод в заголовках не перечисляется). Вход вне трёх форм теперь
  даёт `FunctionClauseError`, а при известном компилятору типе аргумента — предупреждение инференса
  на call site, то есть падение сборки на `mix compile --warnings-as-errors`. Поведение на трёх
  формах, `@spec` и `@doc` не изменились; `tap(:ok, _)` по-прежнему эффекта не даёт.

  Как править код потребителя: `grep -rn "Result.map_error(\|Result.tap("` и привести вход к
  `{:ok, _}` / `:ok` / `{:error, _}`.

  ```elixir
  # было — голое значение проходило насквозь, ошибка не обогащалась и эффекта не было
  Result.map_error(user, &Error.wrap(outer, &1))
  Result.tap(user, &Logger.debug("user: id=#{&1.id}"))

  # стало — на вход подаётся результат
  Result.map_error(Result.ok(user), &Error.wrap(outer, &1))
  Result.tap(Result.ok(user), &Logger.debug("user: id=#{&1.id}"))
  ```

- **`Result.expect!/2` и `Option.expect!/2` удалены** (`Core.Result`, `Core.Option`). Обе поднимали
  голый текст вызывающего (`raise message`), то есть `%RuntimeError{}`: на причине `%Error{}`
  структура уничтожалась целиком — ни `ns`, ни `code`, ни `detail`, ни цепочки `parent` у того, кто
  ловит исключение, уже не было. `12-errors.md` требует на bang-границе `raise Exc, error`, и
  соседняя `Result.unwrap!/1` так и делает: `%Error{}` доезжает в поле `error` исключения `Exc`.
  Держать вторую bang-дверь, ведущую мимо `Exc`, незачем — полезный случай (свой текст поверх
  причины) собирается композицией `map_error/2` + `unwrap!/1`. Единственная bang-дверь
  `Core.Result` — теперь `unwrap!/1`; остальные функции обоих модулей поведения не меняют.

  Как править код потребителя: `grep -rn "Result.expect!(\|Option.expect!("`.

  ```elixir
  # было — текст вместо ошибки
  Result.expect!(res, "нет агрегата")
  Option.expect!(value, "нет значения")

  # стало — причина %Error{}: внешнее звено цепочки + Exc
  res |> Result.map_error(&Error.wrap(outer, &1)) |> Result.unwrap!()

  # стало — иная причина: свой текст на call site
  Result.unwrap_or_else(res, fn -> raise "нет агрегата" end)
  Option.unwrap_or_else(value, fn -> raise "нет значения" end)
  ```

- **Колбэк проверяется на арность на каждой клозе обоих модулей результата** (`Core.Result`,
  `Core.Option`). Guard стоял только там, где колбэк вызывается, и в разных функциях по-разному:
  `Result.or_else/2` и `Result.unwrap_or_else/2` проверяли арность на ветке `{:error, _}`,
  `Result.map/2`, `map_error/2`, `tap/2`, `map_or/3`, `map_or_else/3` и `and_then/2` — нигде, а у
  `Option.or_else/2` и `Option.unwrap_or_else/2` `is_function(fun, 0)` стоял только на клозе `nil`,
  и `nil` проваливался во вторую клозу (`def or_else(value, _fun), do: value`). Неверный колбэк
  проходил и сборку, и рантайм: `Option.or_else(nil, fn _ -> default end)` молча отдавал `nil`, не
  вызвав колбэк, `Result.or_else(:ok, fn _ -> … end)` — `:ok`, `Result.map({:error, :e}, fn -> … end)`
  — `{:error, :e}`, `Result.map_error(:ok, :not_a_function)` — `:ok`; отказ наступал, только если
  исполнение доходило до клозы с вызовом, и это был `BadArityError`, а не `FunctionClauseError`.
  Теперь guard арности стоит на каждой клозе каждой функции обоих модулей, принимающей колбэк:
  домен аргумента не зависит от формы результата на входе (`20-agreements.md`, «Домен функции и
  инференс типов»). Колбэк неверной арности и не-функция дают `FunctionClauseError`, а на call site
  с литеральным колбэком — предупреждение инференса, то есть падение сборки на
  `mix compile --warnings-as-errors`. Поведение на верном колбэке, `@spec` и `@doc` не изменились;
  норма — `11-domain.md`, «Result / Option».

  Как править код потребителя: `grep -rn "Result\.\(map\|map_error\|tap\|map_or\|map_or_else\)("`,
  `grep -rn "Result\.\(and_then\|or_else\|unwrap_or_else\)("`,
  `grep -rn "Option\.\(map\|or_else\|unwrap_or_else\)("` — арность колбэка должна совпадать со
  спекой: нуль-арный у `or_else/2` и `unwrap_or_else/2`, одноарный — у остальных.

  ```elixir
  # было — арность не та, вызов молча отдавал вход
  Option.or_else(value, fn _ -> default end)
  Result.or_else(res, fn _reason -> fallback end)
  Result.map(res, fn -> default end)

  # стало
  Option.or_else(value, fn -> default end)
  Result.or_else(res, fn -> fallback end)
  Result.map(res, fn value -> transform(value) end)
  ```

- **PromEx стартует раньше пула БД** (`docs/rules/app/17-otp-concurrency.md`, «Дерево процессов»).
  Свод ставил пул БД первым, а сбор метрик — вторым, вопреки требованию PromEx: `PromEx.Plugins.Ecto`
  слушает `[:ecto, :repo, :init]`, и Repo, поднятый раньше PromEx, эмитит событие в пустоту —
  метрики `repo.init.*` пусты, дашборд Ecto их не показывает. Самому PromEx БД на старте не нужна:
  опрос очереди `Core.Outbox.PromEx` идёт через `Core.PromEx.Safe` и до подъёма пула пропускает цикл
  с `warning`, а не роняет процесс.

  Как править код потребителя: в `MyApp.Application` поставить `MyApp.PromEx` первым ребёнком.

  ```elixir
  # было
  children = [MyApp.DAO, MyApp.PromEx, ...]

  # стало
  children = [MyApp.PromEx, MyApp.DAO, ...]
  ```

### Новое

- **Форма `If-Match` на чтении по версии выбирается проектом** (`app/15-web-api.md`,
  «Controller»). Свод требовал на чтении только `optional_version/2`: без заголовка — `:current`,
  то есть отсутствующий `If-Match` на GET неотличим от забытого. Теперь проект выбирает одну форму
  на все чтения по версии: SHOULD — `expected_version/2` (нет заголовка → 400 `:missing_param`,
  `*` → `:current`), MAY — `optional_version/2`. Рекомендована обязательная форма: `*` — видимое
  намерение читать текущее, как на команде, а клиент, всегда шлющий `If-Match`, при гонке получает
  412, а не чужую версию. Разные формы в разных экшенах одного API — MUST NOT. Выбор фиксируют код
  и `operation/2` (`required` и тип параметра). Код на `optional_version/2` остаётся в норме и не
  правится; переход на рекомендованную форму меняет контракт API для его клиентов.

  ```elixir
  # было — единственная допустимая форма чтения
  with {:ok, version} <- Params.optional_version(params), ...

  # стало — рекомендовано: заголовок обязателен, `*` → :current
  with {:ok, version} <- Params.expected_version(params), ...
  ```

- **Публичные типы результата — `Result.t/0,1,2`, `Result.unit/0,1`, `Option.t/0,1`**
  (`Core.Result`, `Core.Option`). Результат — сквозная форма библиотеки, но имени у неё не было:
  каждая спека расписывала тапл руками и по-своему, а модули, которым имя понадобилось, заводили
  его у себя (`Core.Validator.result`, `Core.Mutator.result`, функции-типы `Core.PubSub`).
  Базовая форма двухпараметрическая — `t(a, e) :: {:ok, a} | {:error, e}`; однопараметрическая
  `t(a) :: t(a, Error.t())` — сокращение на частый случай, `t()` — на случай, когда значение
  произвольно. Unit-результат CQS-команды — `unit(e) :: :ok | {:error, e}` и `unit()`.
  Опциональное значение — `Option.t(a) :: a | nil` и `Option.t()`. Однородно сузить причину до
  `%Error{}` нельзя: в библиотеке живут и `:none` (`Option.to_result/1`), и `{code, detail}`
  (`Core.Validator`), — поэтому reason остаётся параметром. Спеки обоих модулей переписаны на эти
  типы; поведение функций, деление интерфейса на unit и valued и форма возвратов не изменились,
  существующий код потребителя не правится. Норма записи — `11-domain.md`, «Result / Option».

  ```elixir
  # было — форма прописью в каждой спеке и в каждом локальном типе
  @spec get(Agg.ID.t(), Context.t()) :: {:ok, Agg.t()} | {:error, Error.t()}
  @type result :: :ok | {:error, {code(), detail()}}

  # стало — имя одно, параметр называет причину
  @spec get(Agg.ID.t(), Context.t()) :: Result.t(Agg.t())
  @type result :: Result.unit({code(), detail()})
  ```

## 0.3.4

### Новое

- **Множество ошибок — поле `errors` в `%Error{}` и конструктор `Error.many/1,2`**
  (`Core.Error`). `%Error{}` описывал один отказ и, через `parent`, линейную цепочку причин;
  «несколько независимых отказов сразу» (невалидные поля формы, провалившиеся элементы пачки)
  представления не имело, и каждое такое место обрывалось на первом. Добавлено поле
  `errors: [t()]` с дефолтом `[]` — независимое от `parent`: `parent` отвечает «почему»,
  `errors` — «что ещё не так». Контейнер собирают макросы `many/1` (module из `__CALLER__`)
  и `many/2`, симметрично `domain` / `app`, с compile-check литерального kwlist: обязательны
  `code:`, `ns:`, `message:`, `errors:`, опциональны `detail:`, `parent:`. `kind` опцией не
  принимается — выводится по слабейшему звену состава: хотя бы один элемент `:app` → контейнер
  `:app`. Инварианты состава — `ArgumentError`: пустой `errors:`, элемент не `%Error{}`, элемент
  с непустым `errors` (множество плоское). Контейнер не бывает причиной: `wrap/2` вторым
  аргументом и `parent:` любого конструктора его не принимают; обратное направление разрешено.
  Порядок входа сохраняется, дубли `{ns, code}` не схлопываются. `ns` и `code` — из словаря
  потребителя, общего кода библиотека не вводит. Решение о форме — ADR-0021. Существующие API
  формы `{:error, %Error{}}` не изменились, код потребителя не правится.

  Состав виден в печати и достаётся текстами: `Error.format_chain/1` печатает узел с непустым
  `errors` вместе с составом — `"outer (e1 | e2): root"`, рекурсивно по цепочке (у ошибки с
  пустым `errors` вывод прежний), а `Exc.message/1` на bang-границе берёт для контейнера
  `format_chain/1` вместо `to_string/1`. Новая `Error.messages/1` → `[String.t()]` отдаёт тексты
  для клиента: у контейнера — `to_string/1` каждого элемента в порядке состава, у обычной
  ошибки — `[to_string(error)]`. Обход причин множества не касается: `has?/2`, `find/2`,
  `chain/1`, `root/1`, `unwrap/1` и `Enumerable` читают только цепочку `parent` — `has?/2` по
  коду элемента даёт `false`, `Enum.count/1` считает цепочку.

  ```elixir
  # было — отказ на первом невалидном поле
  {:error, Error.domain(code: :invalid, ns: :form, message: "имя пусто")}

  # стало — все отказы сразу, контейнер ведёт себя как обычная ошибка
  {:error,
   Error.many(
     code: :invalid,
     ns: :form,
     message: "форма невалидна",
     errors: [blank_name, too_long_title]
   )}
  ```

- **Batch-проход, собирающий все провалы — `Result.traverse_all/2`** (`Core.Result`).
  `traverse/2` останавливает пачку на первом провале: какие ещё элементы плохи, вызывающий не
  узнаёт, и форма с пятью невалидными полями правится за пять запросов. `traverse_all/2` зовёт fun
  на каждом элементе и собирает все провалы — `{:ok, [b]} | {:error, [Error.t()]}`, порядок
  значений и порядок провалов — порядок входа. Голый список наружу не отдаётся: он заворачивается
  в `Error.many` в теле той же функции — `ns`, `code` и общий `message` знает только call site.
  `traverse/2` не изменилась, существующий код потребителя не правится.

  ```elixir
  def validate_rows(rows) do
    rows
    |> Result.traverse_all(&validate/1)
    |> Result.map_error(
      &Error.many(code: :invalid, ns: :form, message: "Форма невалидна", errors: &1)
    )
  end
  ```

- **Конверт ответа принимает список сообщений — `Core.Web.Response.error/2,3`.** Поле `messages`
  конверта — список, но собрать его можно было только одним элементом: второй аргумент требовал
  `String.t()`, и состав множества ошибок доезжал до клиента либо первой строкой, либо сборкой
  конверта руками мимо `error/2`. Теперь вторым аргументом MAY быть **непустой** список строк —
  он кладётся в `messages` как есть; строка по-прежнему заворачивается в один элемент. Пустой
  список — `FunctionClauseError`: ответ без сообщений собирать нечем. То же у билдера
  `use Core.Web.Response`. `Core.Web.ErrorMapper.map/2` не изменился: состав подставляет
  потребитель в fallback-контроллере через `Error.messages/1` и только там, где маппер вернул
  `:domain_error`; на 401 и 500 наружу идёт константа. Существующий код потребителя не правится.

  ```elixir
  # было — один текст, состав множества до клиента не доезжает
  json(conn, Response.error(code, message))

  # стало — состав как есть
  json(conn, Response.error(:domain_error, Error.messages(error)))
  ```

## 0.3.3

### Изменения контракта макросов

- **`outbox: :none` — агрегат, не публикующий события наружу** (`use Core.Repo.Pg.StateStored`,
  `use Core.Es.Aggregate.Repo.Pg`). Опция `outbox:` требовала модуль `<Aggregate>.Outbox`
  всегда, и агрегату, чьи события наружу не уезжают, приходилось заводить маппер с выдуманным
  топиком: записи копились в `outbox`, поллер их публиковал, читателя у топика не было. Теперь
  значением MAY быть `:none` — события пишутся в хранилище событий как раньше, записей outbox
  нет, семейство событий не сверяется. Опция осталась **обязательной**: пропуск ключа
  по-прежнему `CompileError`, иначе забытая опция выключала бы публикацию молча. Существующий
  код потребителя не правится.

  ```elixir
  # было — маппер ради обязательной опции
  defmodule Agg.Outbox do
    use Core.Es.Outbox, topic: "aggs", event: Agg.Event
  end

  use Core.Es.Aggregate.Repo.Pg,
    behaviour: Agg.Repo,
    aggregate: Agg,
    id: Agg.ID,
    errors: Agg.Errors,
    outbox: Agg.Outbox

  # стало — модуля нет
  use Core.Es.Aggregate.Repo.Pg,
    behaviour: Agg.Repo,
    aggregate: Agg,
    id: Agg.ID,
    errors: Agg.Errors,
    outbox: :none
  ```

## 0.3.2

### Новое

- **Конверт ответа API берёт сообщения при успехе и данные при ошибке** (`Core.Web.Response`).
  Формы конверта расходились: успех всегда уходил с `messages: []`, ошибка — без ключа `data`,
  и приложение, которому надо отдать предупреждение вместе с результатом или разбор отказа
  (поле, лимит, идентификатор) вместе с текстом, собирало map мимо конверта. Добавлены
  `success/2` (`data`, список сообщений) и `error/3` (`code`, текст, `data`) — в самом модуле и
  у билдера `use Core.Web.Response`. Сообщения принимаются **только списком**: строка даёт
  `FunctionClauseError`. Конверта «успех с сообщениями без `data`» нет — сообщения при успехе
  идут вместе с данными. Существующие `success/0`, `success/1`, `error/2` не изменились, код
  потребителя не правится.

  ```elixir
  # было — конверт собирался руками
  json(conn, Map.put(Response.success(data), :messages, ["часть записей пропущена"]))

  # стало
  json(conn, Response.success(data, ["часть записей пропущена"]))
  json(conn, Response.error(:domain_error, "нельзя", %{field: "name"}))
  ```

## 0.3.1

### Новое

- **Ссылка на компонент того же продукта разрешена** (`app/20-agreements.md`, «Ссылки на
  другие проекты»). Запрет был сплошным: приложение, разрезанное на компоненты
  (`my_app_back`, `my_app_front`, `my_app_proxy`, `my_app_docs`), не могло назвать соседа даже
  там, где контракт между ними и есть предмет документа. Теперь MUST NOT адресует только
  **чужие** проекты, а ссылка на компонент-сосед MAY — именем, namespace и путём внутри него,
  при условии, что компонент перечислен в `CONTEXT.md` в корне репозитория (имя, зона
  ответственности, репозиторий). Что правится у потребителя: завести в `CONTEXT.md` перечень
  компонентов — упоминание соседа, которого в перечне нет, остаётся дефектом текста, как
  раньше. Запрет обосновывать решение ссылкой на источник («так сделано в X») не ослаблен и
  для компонентов.

## 0.3.0

### Ломающие изменения контракта

- **Потребитель не ставит `await: :poll` сам — ветка неготовой read-модели проверяется
  `Core.Es.Projection.Test.with_rebuilding/2`.** Ветку ответа 202
  (`:projection_timeout` / `:projection_rebuilding`, `app/15-web-api.md`) приложение проверяло
  своим тестовым хелпером: переставляло отметку дерева на `:poll` своим `start_link`, правило
  env собственного таймаута ожидания и восстанавливало оба в `on_exit`. Плата — реальное время
  теста и таймаут приложения, настраиваемый только ради него. Теперь `19-testing.md`,
  «Проекции» запрещает потребителю ставить `:poll` любым способом, а `19-testing.md` яруса
  потребителя требует **одного** теста ветки на приложение через хелпер библиотеки; доводить
  тест до `:projection_timeout` — MUST NOT, ветка ответа та же. Живое дерево `:poll` остаётся
  только у тестов самого ожидания в библиотеке. Запрет — на ожидание, а не на значение опции:
  тест, который дерева не поднимает и `await/3` не зовёт, опции с `enabled: true` (и потому с
  `await: :poll`) собрать MAY — так проверяется ратчет состава `watch_list/0` под тумблерами.

  ```elixir
  # было — свой `:poll`, свой env, полный таймаут вызывающего
  Application.put_env(:my_app, MyAppWeb.Helper.Projection, await_timeout_ms: 50)
  opts = Keyword.put(MyApp.Projections.opts(), :await, :poll)
  :ignore = Core.Es.Projection.Supervisor.start_link(opts)
  on_exit(fn -> :ignore = Core.Es.Projection.Supervisor.start_link(MyApp.Projections.opts()) end)
  conn = patch(authed(ctx), "#{@path}/#{id}", body)

  # стало — исход мгновенный, отметку и строку чекпоинта возвращает хелпер
  conn =
    Core.Es.Projection.Test.with_rebuilding(MyApp.Domain.<BC>.Common.Projection, fn ->
      patch(authed(ctx), "#{@path}/#{id}", body)
    end)
  ```

- **`:version_mismatch` несёт источник отказа: `source: :expected | :storage` в detail.** Раньше
  detail сверки ожидаемой версии и detail отказа записи событий были одной формы
  (`%{aggregate_id, expected, actual}`, у state-stored сверки строки —
  `%{id, expected, actual: :stale}`), и снаружи исходы не различались. Теперь ключ есть у всех
  точек: `Core.Es.Store.append/5` ставит `:storage` (оба write-пути), сверка версии в
  `Core.Es.Aggregate.Repo.Pg` и в `Core.Repo.Pg` (`version_error/4`, `Ecto.StaleEntryError`,
  промах `DELETE`, список пар `get_many` / `exists_all?`) — `:expected`. Тип
  `t:Core.Es.Store.mismatch_detail/0` расширен, добавлен `t:Core.Es.Store.mismatch_source/0`.
  Правится код, который сравнивает detail целиком; компилятор этого не ловит — detail
  типизирован `term()`. Почему ключ в detail, а не новый код ошибки, —
  `docs/adr/0019-retry-by-write-refusal-source.md`.

  ```elixir
  # было
  assert error.detail == %{aggregate_id: dump(id), expected: 2, actual: 1}
  # стало
  assert error.detail == %{aggregate_id: dump(id), expected: 2, actual: 1, source: :expected}
  ```

- **`<Aggregate>.Process.execute` повторяет команду по источнику отказа, а не по ожидаемой
  версии.** Было: повтор только при `version: :current` и только на отказе `append`. Стало:
  повторяется отказ хранилища (`source: :storage`) при **любой** ожидаемой версии, включая явную
  `%Version{}` из `If-Match`, и в том числе пришедший из колбэка `fun.(events)` — например от
  записи в соседний поток; сверка ожидаемой версии (`source: :expected`) не повторяется никогда.
  Следствия для потребителя: корректный `If-Match` больше не получает 412 от конкурента по
  соседнему потоку, а колбэк обязан быть идемпотентным — при повторе он зовётся заново. Тексты
  логов повтора сменились на контекст «транзакция команды» (`type=` в них больше нет). Обоснование
  и цена — `docs/adr/0019-retry-by-write-refusal-source.md`.

- **Write-путь возвращает входной агрегат, а не строку из БД.** `Repo.Pg.insert/4` и `update/4`
  больше не декодируют записанную строку через `to_entity`: возвращается тот же агрегат, что
  пришёл на вход, и он же уходит эталоном в `Repo.Sc` регистрацией после commit — эталон стал
  делом того, кто пишет, а не call site. Смысл возврата теперь один на оба пути: состояние, от
  которого мутируют дальше. Удалены `Repo.Pg.write_insert/4` и `Repo.Pg.write_update/4` — без
  decode они дублировали `insert/4` и `update/4`; `Repo.Pg.StateStored` зовёт обычные методы, а
  агрегат с очищенными `events` собирает **до** записи строки. Мотивация и отвергнутые варианты —
  `docs/adr/0001-write-path-returns-input-aggregate.md`.

- **Интерфейс фасада Codec сведён к `dump/1`, `load/2` и `load!/2`.** Удалены `prim/0`,
  `dump_raw/2`, `dump_raw_as/2`, `load/1`, `load!/1`, `dump_tagged/1`, `load_tagged/2`,
  `load_tagged!/2`: в фасад проникли частности View (raw-путь) и событий (самотегированный
  wire), и он перестал быть тем, чем задумывался. Осталась одна ось диспетчеризации — модуль.
  Prim-профиль (`use Core.Codec`) симметрично лишился `dump_raw/2` и `dump_raw_as/2`.
- **Полиморфный wire грузится через модуль-семейство.** У плагина появилась опция `union:`;
  фасад заводит на этот модуль клоузу `load/2`, а какой тип лежит в данных — решает сам плагин:
  `InCodec.load(<Aggregate>.Event, data)` вместо `InCodec.load(data)`. Реестра тегов у фасада
  больше нет, и требование глобальной уникальности тега снято — тег уникален внутри своего
  кодека. Квалифицированные имена (`order.created`) остаются конвенцией: тег виден в
  брокере и в event store рядом с чужими.
- **`use Core.Codec.Facade` сужает результат плагина и фолбэк `dump/1`.** Клоуза плагина отдавала
  его результат как есть, и `load/2` / `load!/2` фасада выводились как `dynamic()`: опечатка в поле
  события из `InCodec.load(Agg.Event, data)` или в поле его нагрузки падала `KeyError` при
  исполнении, clause `:ok ->` по результату молча не срабатывала, а команда в `InCodec.dump/1` падала
  `ArgumentError` «нет codec-плагина». Теперь клоуза плагина сужает результат паттерном по его
  типам: `load(Mod, data)` — `{:ok, %Mod{}} | {:error, _}`, `load(<Aggregate>.Event, data)` —
  объединение событий кодека, событие — ещё и по нагрузке (`%Event.X{payload: %Payload{}}` либо
  `payload: nil`); `load!/2` получил те же клоузы и делает `raise Core.Exc` сам. Фолбэк `dump/1`
  принимает только struct с полем `value` (`Core.Guard.is_prim/1`): struct без плагина и без
  `value` — предупреждение при сборке, при исполнении — `FunctionClauseError` вместо
  `ArgumentError`; struct с `value`, который не Prim, — по-прежнему `ArgumentError`. Исходы
  корректных вызовов прежние, фолбэк `load/2` по атому не сужен. Плагин, чей `load/3` нарушает
  контракт — отдаёт не struct запрошенного типа или, у `load!/2`, ошибку не `%Core.Error{}`, —
  падает `CaseClauseError`. Правится вызов, а не предупреждение.

  ```elixir
  # было — собиралось и падало KeyError при исполнении;
  # стало — warning: unknown key .aggregat_id in expression
  {:ok, event} = InCodec.load(Account.Event, data)
  event.aggregat_id

  # было — собиралось и падало ArgumentError «нет codec-плагина»;
  # стало — warning: incompatible types given to MyApp.Codec.Internal.dump/1
  InCodec.dump(%Account.Cmd.Open{name: name, by: by, at: at})
  ```
- **`Core.Codec.Plugin`: `types:` вместо `tags:`, `union:` вместо `tagged:`.** Механизм
  `tagged: true` / `dump_tagged` / `load_tagged` удалён целиком. `types:` стала обязательной;
  `union:` требует `loadable: true`. Генерация `type/1`, `types/0`, `mod_by_tag/1`,
  `__codec_tags__/0`, `__codec_tagged__/0`, `fetch_type/1` из плагина ушла — `type/1`, `types/0`
  и `mod_by_tag/1` теперь генерирует `Core.Es.Event.Codec` (контракт
  `<Aggregate>.Event.name/1` и `names/0` не изменился).
- **`Core.Es.Event.Codec`: колбэки вместо приватных клоуз, опции `event:` + `type:` + `tags:`.**
  `dump_payload/2` и `load_payload/3` стали callback'ами behaviour (`@impl true`, `def`, не
  `defp`), и `load_payload` возвращает `%Payload{}`, а не собранное событие: конверт разбирает
  и событие собирает билдер. Аргумент `envelope` и хелперы `event/2` / `event/3` пропали вместе
  с модулем `Core.Es.Event.Codec.Helper`. События без нагрузки клоуз не требуют вовсе. Опции
  `aggregate_id:` и `by:` сняты — билдер выводит их из самих событий; разные Prim у событий
  одного кодека — `CompileError`. Неизвестный тег теперь `:unknown_event_type` (`ns: :es`,
  модуль — кодек агрегата) вместо `:unknown_tagged_type` фасада. Clause `:unknown_event_type` в
  каталогах `<Aggregate>.Errors` больше не вызывается — ошибку строит кодек.

  Колбэки нагрузки проверяет сборка кодека: `use Core.Es.Event.Codec` генерирует на каждое событие
  с нагрузкой функции-проверки (`Core.Es.Check`) — литеральный вызов
  `dump_payload(%Event.Mod{payload: %Payload{}} = event, codec)` и сопоставление результата
  `load_payload(Event.Mod, wire, codec)` с `{:ok, %Payload{}}` (у модуля нагрузки, общего у
  нескольких событий, — clause функции на каждое событие). Нет clause `dump_payload/2` или
  `load_payload/3` для события с нагрузкой, `load_payload/3` отдаёт нагрузку другого события —
  литералом или через `Payload.new` — предупреждение на строке `use`, и имя функции в нём
  называет нарушенное утверждение. Прежде пропущенная clause падала `FunctionClauseError` при
  записи или чтении события, а нагрузка другого события — в `Event.Mod.new/6` при чтении. Clause
  `{:error, _}` сгенерирована с `generated: true`: у `load_payload/3`, который никогда не
  ошибается, ложного предупреждения нет. Кодек без событий с нагрузкой проверок нагрузки не
  получает. Код потребителя не меняется: сборка с `--warnings-as-errors` падает там, где колбэки
  нагрузки были неверны всегда, — правится кодек.

  ```text
  # было — при записи события
  ** (FunctionClauseError) no function clause matching in MyApp.Domain.<BC>.Common.Account.Event.Codec.dump_payload/2

  # стало — предупреждение при сборке
  warning: incompatible types given to dump_payload/2:
  └─ lib/my_app/domain/<bc>/common/account/event/codec.ex:9: MyApp.Domain.<BC>.Common.Account.Event.Codec."dump_payload/2 принимает MyApp.Domain.<BC>.Common.Account.Event.Renamed"/2

  warning: the following clause will never match:
      {:ok, %MyApp.Domain.<BC>.Common.Account.Event.Renamed.Payload{}} ->
  └─ lib/my_app/domain/<bc>/common/account/event/codec.ex:9: MyApp.Domain.<BC>.Common.Account.Event.Codec."load_payload/3 отдаёт нагрузку MyApp.Domain.<BC>.Common.Account.Event.Renamed.Payload"/3
  ```
- **`Core.Es.Outbox.Envelope` удалён** (был добавлен в этом же невыпущенном цикле): обе стороны
  формата конверта живут в `Core.Es.Event.Codec`. Наружу отдаётся только пара `to_fields/1` /
  `from_fields/1` — для транспорта, который хранит поля события врозь. Оттуда же `Es.Outbox`
  берёт ключ, имя и заголовки записи, поэтому у его опции `event:` снято требование `name/1`.
- **`Core.Outbox.Name`** принимает тот же набор символов, что `Topic` (`[a-zA-Z0-9._-]`): имя
  сообщения — это wire-тег события, а он квалифицирован. Расширение множества значений,
  старые имена проходят.
- **`Core.Config.validate!/0`** проверяет у фасада `dump/1`, `load/2` и `load!/2` (было
  `dump/1`, `load/2`, `prim/0`).

  Форма конверта события и колонки outbox не изменились — данные этих правок мигрировать не нужно
  (перенос таблиц событий — пункт «State-stored агрегат пишет события в общую таблицу»). Миграция
  кода потребителя:

  ```elixir
  # кодек событий: было
  use Es.Event.Codec,
    tags: @tag_by_mod, event: User.Event, aggregate_id: User.ID, by: User.ID, errors: User.Errors

  defp dump_payload(%Event.Blocked{}, _codec), do: nil
  defp load_payload(Event.Blocked, nil, envelope, _), do: {:ok, event(Event.Blocked, envelope)}

  defp load_payload(Event.Created, payload, envelope, codec) do
    with {:ok, login} <- load_optional(field(payload, :login), User.Login, codec) do
      {:ok, event(Event.Created, Event.Created.Payload.new(login), envelope)}
    end
  end

  # стало — события без нагрузки не упоминаются вовсе
  use Es.Event.Codec,
    event: User.Event,
    type: "user",
    tags: @tag_by_mod

  @impl true
  def load_payload(Event.Created, payload, codec) do
    with {:ok, login} <- load_optional(field(payload, :login), User.Login, codec) do
      {:ok, Event.Created.Payload.new(login)}
    end
  end

  # чтение события: было → стало
  InCodec.load(data)                    → InCodec.load(User.Event, data)
  InCodec.load!(data)                   → InCodec.load!(User.Event, data)

  # read-модели, написанные руками: было → стало
  codec.dump_raw(:uuid, view.node_id)   → dump_raw(Object.NodeID, view.node_id, codec)
  dump_raw_optional(v, :datetime, codec) → dump_raw(Agg.ClosedAt, v, codec)
  ```

  Golden-фикстура грузится целиком через семейство — `InCodec.load(<Aggregate>.Event, fixture)`;
  свой `EventCompatCase` потребителя заменяет `Core.Es.EventCompatCase` (раздел «Новое»).
- **State-stored агрегат пишет события в общую таблицу `es_events`; триплет
  `Core.Es.Event.Repo{,.Pg,.Pg.Schema}` удалён.** Своя таблица событий на агрегат оставляла
  state-stored агрегат без глобальной позиции и отдельно от хранилища event-sourced; общая таблица
  (`docs/adr/0008-shared-event-table-xid8-position.md`) снимает и то и другое, а модули событий на
  агрегат (`<Agg>.Event.Repo{,.Pg,.Pg.Schema}`) становятся не нужны. События пишет
  `Core.Es.Store.append` в прежнем порядке записи (builder — `Core.Repo.Pg.StateStored`, раздел
  «Изменения контракта макросов»). Что правится у потребителя:
  - **Выпуск с остановкой записи state-stored агрегатов.** Ноды старого кода останавливаются до
    миграций: перенос без простоя (триггер на старых таблицах) не годится — транзакция старой ноды
    получает `xid` меньше копии. Миграции 1 и 2 накатываются одним `mix ecto.migrate` до старта
    нового кода, миграция 3 — после проверки перенесённого.
  - **Миграция 1** — таблица `es_events`: делегирование `Core.Es.Migration` (пример — пункт
    «Хранилище событий» в разделе «Новое»).
  - **Миграция 2** — копия истории по каждой старой таблице без преобразования тегов и нагрузки:
    старые формы читает апкаст кодека (`upcasts:`). `ORDER BY aggregate_id, aggregate_version`
    выдаёт номера позиции по возрастанию версий потока. Колонка тега старой таблицы — `type`, а тип
    агрегата — литерал `type:` кодека событий в колонке `aggregate_type`:

    ```elixir
    defmodule MyApp.Repo.Migrations.CopyStateStoredEvents do
      use Ecto.Migration

      def up do
        # 'role' — `type:` у `Role.Event.Codec`; `type` старой таблицы — wire-тег события
        execute("""
        INSERT INTO es_events
          (aggregate_type, aggregate_id, aggregate_version, event_id, tag, payload, by_id, at)
        SELECT 'role', aggregate_id, aggregate_version, id, type, payload, by_id, at
        FROM role_events
        ORDER BY aggregate_id, aggregate_version
        """)

        # … так же для каждой таблицы событий state-stored агрегата
      end

      def down do
        execute("DELETE FROM es_events WHERE aggregate_type IN ('role')")
      end
    end
    ```

  - **Миграция 3** — `drop table(:role_events)` по каждой старой таблице, после сверки числа
    событий: `SELECT count(*) FROM role_events` против
    `SELECT count(*) FROM es_events WHERE aggregate_type = 'role'`.
  - **Удалены** `Core.Es.Event.Repo`, `Core.Es.Event.Repo.Pg`, `Core.Es.Event.Repo.Pg.Schema`, а с
    ними у потребителя — `<Agg>.Event.Repo{,.Pg,.Pg.Schema}` и их тесты. Ключ подмены
    `config :my_app, <Agg>.Event.Repo, <Impl>` из app-env удалить: хранилище событий — модуль
    библиотеки, подменять можно только `<Agg>.Repo`.
  - **Чтение потока.** `@event_repo.page_by_aggregate(id, limit, offset, context)` →
    `@repo.page_stream(id, limit, offset, context)` write-репозитория агрегата (генерирует
    `use Core.Repo.Pg.StateStored`), `count_by_aggregate` → `count` той же страницы.
    `page_stream` доступ не проверяет и `:not_found` не отдаёт, поэтому usecase обязан проверить
    права и существование агрегата до чтения — `ReadRepo.get(id, :current, context)`
    (`13-repos.md`, «Страница потока»). В тестах
    `{:ok, events} = @event_repo.list_by_aggregate(id, context)` →
    `events = Core.Es.Store.Test.events!(Agg.Event.Codec, id)`.
  - **`:version_mismatch` записи событий.** Код — тот же, из `errors:`; модуль ошибки —
    `behaviour:` write-репозитория вместо `<Agg>.Event.Repo`; detail `%{aggregate_id, versions}` →
    `%{aggregate_id, expected, actual}` (`expected` — первая версия потока в пачке, `actual` —
    наибольшая версия потока). Новый источник — страж `xid`: отказ бывает и без занятой версии,
    если транзакция получила `xid` раньше commit конкурента по тому же потоку. Реакция та же —
    повтор usecase; хелпера повтора нет.
  - **Запись событий.** Опции запроса (`:prefix`, `:timeout`) к записи событий больше не
    применяются: `Core.Es.Store.append` пишет в транзакции `DAO` вызывающего. Событие, которое
    фасад знает, но которого нет в `tags:` кодека (событие чужого агрегата), — `FunctionClauseError`
    на записи, а не строка в чужой таблице событий.
  - **Больше не нужны** Ecto-тип jsonb для `payload_type:` и Ecto-схема пользователей для
    `by_schema:`; FK `by_id` на таблицу пользователей в `es_events` нет.
- **Тип версии переехал в `Core.Version`.** `Core.Repo.version()` удалён — вместо него
  `Core.Version.expected()` (`%Version{} | :current`). Тип версии принадлежит `Version`,
  а не модулю репозитория; в `@spec` потребителя замена механическая.
- **`Core.Context.fetch/2` и `Context.Accessor.fetch/1` удалены.** Словарь чтения контекста —
  `exists?` / `find` / `get` / `get!` (`20-agreements.md`). Сохранённый `nil` по-прежнему
  отличим от отсутствующего ключа: `exists?/2` плюс `get/2` (тот отдаёт `{:ok, nil}`).
- **`Core.Repo.Sc.fetch/3` → `Core.Repo.Sc.find/3`.** Контракт `struct() | nil` — это `find`;
  под именем `fetch` в библиотеке оставалось два разных контракта.
- **`insert` / `update` / `save` больше не возвращают `{:error, Ecto.Changeset.t()}`.**
  Незамапленный DB-constraint и любой другой провал `changeset/2` — дыра в декларации
  `constraint_errors:` или в `to_model`, то есть ошибка программиста: теперь наружу уходит
  `%Error{kind: :app, ns: :repo, code: :write_failed}` с `detail: %{schema:, errors:}`
  (`Core.Repo.Pg.changeset_errors/1`). Контракт `errors:` потребителя не меняется — ошибку
  строит сам `Repo.Pg`. В `FallbackController` потребителя clause `{:error, %Ecto.Changeset{}}`
  надо удалить: ситуация приходит веткой `%Error{kind: :app}` (500 + лог), а не 400.
- **`Core.Error`: контракт конструирования и `has?/2` ужесточён.** Нарушение контракта перестало
  маскироваться под нормальный результат:
  - `%Error{}` требует `message` при прямом конструировании структурой (`@enforce_keys`); для
    `:app` допустим `nil`, но ключ обязан быть указан. Фабрики `Error.domain/1|2` и
    `Error.app/1|2` не затронуты.
  - `parent:` не `%Error{}` и не `nil` → `FunctionClauseError` вместо `ArgumentError` — как у
    `wrap/2`; `rescue ArgumentError` вокруг конструирования надо снять.
  - `Error.has?(err, [])` → `FunctionClauseError` вместо `true`: пустой критерий совпадал с
    любой ошибкой. Элемент критерия не keyword-парой → `ArgumentError`.
  - Дублирующийся ключ в литеральных attrs → `CompileError`; лишний ключ в динамическом attrs
    (переменная) → `ArgumentError` вместо молчаливого игнора.
  - `message: ""` больше не печатается пустотой: `String.Chars` и `format_chain/1` отдают
    fallback `"ns/code"`, как при `message: nil`.
- **`Core.Web.ErrorMapper` берёт текст через `String.Chars`, а не `error.message`.** Ошибка без
  текста (у `:app` `message` опционален) отдавала клиенту `null` в поле сообщения при 412 и 403,
  нарушая собственный `@type result` (`String.t()`); теперь в ответ уходит fallback `"ns/code"`.
  Затронуты клозы `:version_mismatch`, `:access_denied` и `kind: :domain`. `Core.Prim.wrap_parent`
  перестал дублировать то же правило своим `parent.message || "ns/code"`.
- **`Core.Context`: ключ — атом.** `@type key` сужен с `term()` до `atom()`, guard стоит на каждой
  функции: словарь ключей закрыт кодом (`Context.Accessor`, `Repo.Sc`), а не приходит извне.
  `Context.new/1` принимает только plain map — struct контекстом больше не притворится.
- **`inspect(%Context{})` печатает только ключи** — `#Context<keys: [...]>`. Контекст лежит в state
  OTP-процессов (`Outbox.Poller`, `Outbox.Cleaner`) и целиком уходит в crash-репорты, а его
  значения — текущий пользователь и прочие чувствительные данные (`12-errors.md`).
- **Функции `Context.Accessor` требуют `%Context{}`.** Сгенерированные `exists?/1`, `find/1`,
  `get/1`, `get!/1`, `put/2`, `delete/1` матчат struct в заголовке: чужой аргумент даёт
  `FunctionClauseError` на месте вызова, а не ошибку ключа внутри `Context`.
- **`Core.Repo.Sc.clear/1` и `delete/1` возвращают `%Context{}`, а не `:ok`.** Обе снимают ключ
  таблицы с контекста, и дальше работать нужно с возвращённым: жизненный цикл
  `init/1` → `clear/1` → `delete/1` стал однородным. Обращение по уже удалённой таблице (старая
  копия контекста) — no-op: `put/2` и `find/3` молчат, `clear/1` отдаёт контекст без мёртвого
  ключа, вместо `ArgumentError` из ETS.
- **`Core.Guard.is_error/1` удалён** — обёртка над `is_struct(value, Core.Error)`, а тривиальные
  Kernel-guards свод оборачивать запрещает (`20-agreements.md`). Замена — `is(err, Error)` из того
  же `Core.Guard` либо прямой `is_struct/2`.
- **`Core.Guard.in_enum/3`: дубль в subset — `CompileError`** (принимался молча). Compile-time
  хелперы `expand_mod!/2`, `enum_values!/2`, `literal_atom_list!/2` и `validate_subset!/4` стали
  приватными: это внутренности макросов, а не API.
- **`Core.Prim.String` обязан иметь верхнюю границу.** Без `max_len:` и без `sec_max_len:` —
  `CompileError`: примитив без границы принимает ввод любого размера, а по `min_len:` / `re:`
  вывести её не из чего. Сама отсечка переехала из `mutate` в `cast` (до `String.valid?/1`),
  поэтому её код ошибки теперь `:invalid_string`, а не `:invalid_value`.
- **`Prim.Integer` и `Prim.Decimal` ограничивают строковый ввод по байтам.** `Integer.parse/1` и
  `Decimal.new/1` обходят ввод целиком (у `Prim.Integer` ~2 млн цифр дают `SystemLimitError` мимо
  контракта `new/1`), а `min:` / `max:` проверяются уже после разбора и от его цены не защищают.
  Граница — новая опция `sec_max_len:`; default выводится из `max:` (плюс `scale:` у Decimal),
  без `max:` — 40 байт у Integer и 64 у Decimal. Ввод длиннее — доменная ошибка
  `:invalid_integer` / `:invalid_decimal`. Явная `sec_max_len:`, в которую не влезает собственный
  `max:`, — `CompileError`. Уже разобранный ввод (`integer()`, `%Decimal{}`) границей не ограничен.
- **`__domain_type_opts__/0` строкового Prim больше не содержит `trim:` и `sec_max_len:`.** Опции
  обработки переехали в новый `pipeline_opts:` (их получают cast/mutate-шаги), а `type_opts:`
  остался контрактом типа — `min_len:` / `max_len:` / `re:`; его читает `Codec.coerce/2`
  на read-пути.
- **`Prim.Compose`: `sensitive: false` поверх чувствительной базы — `CompileError`.** Наследование
  осталось, запрещено только понижение: без флага композит отдал бы raw базы в свой `Error.detail`
  целым — база успевает защитить лишь собственный `detail` внутри `parent`.
- **Read-путь дампит plain-kind Prim профилем кодека, а не «как есть».** `Core.Codec.coerce/2`
  оборачивает значение `:string` / `:integer`-Prim в его struct (приводить там нечего) и отдаёт
  в обычный `codec.dump/1`, поэтому переопределение `dump/1` / `dump_kind/2` в профиле действует
  и на read-пути: `Core.View` с полем `prim:`, `Codec.Redump` и `Codec.Helper.dump_raw/3` раньше
  проносили такое значение мимо профиля, и wire-формы путей расходились. Цена — требование к
  профилю: переопределение plain-kind MUST быть идемпотентным, потому что на read-пути оно ложится
  на значение, уже прошедшее dump профиля записи, а нормализовать его нечем (у форматируемых kind
  эту роль играет `cast` в `coerce/2`).
- **`Core.Codec.Redump.validate!/1` отвергает спеку, которую нечем исполнить.** `{:prim, Mod}` с
  kind вне `Core.Codec.coercible_kinds/0` (кастомный) и с `sensitive: true`-Prim — `ArgumentError`
  на месте объявления: неприводимое поле переводить нечем, а чувствительному значению не место
  на read-пути.
- **`Core.Codec.Helper.load_optional/3` принимает Prim-модуль первым аргументом** —
  `load_optional(Mod, value, codec)` вместо `load_optional(value, Mod, codec)`. Порядок стал общим
  у `load_optional/3`, `load_many/3`, `dump_raw/3` и `codec.load/2`. Арность не изменилась, поэтому
  перестановку компилятор не поймает: `nil`-значение уйдёт в `codec.load(nil, Mod)`, остальное —
  `FunctionClauseError`. Правка в плагинах кодеков механическая.
- **Плагину кодека требуется `dump/2`.** Отсутствие — `CompileError` на самом плагине: фасад уже
  завёл клозу на каждый его тип, и раньше она падала `UndefinedFunctionError` на первом дампе.
- **`Core.Codec.Facade.build_type_map!/1` → `validate_mods!/1`** (`:ok` вместо реестра). Фасад
  диспетчеризуется клозами на модуль, реестр никто не читал — от функции оставалась одна проверка
  уникальности модуля между плагинами. Заодно модуль-не-плагин отличается от несобранного
  (`Code.ensure_compiled!`), а `prim:` проверяется на экспорт `dump/1`, `load/2` и `load!/2`.
- **`Mq.Stream.Credentials` больше не зависает в `inspect/1`.** `defimpl Inspect` подставлял
  `"***"` в ту же структуру и снова звал `Inspect.Algebra.to_doc/2` — рекурсия без выхода: любой
  `inspect` (crash-дамп супервизора с аргументами ребёнка, `Logger` со state, `IO.inspect`) вешал
  процесс намертво. Стало `@derive {Inspect, except: [:password]}`:
  `#Core.Mq.Stream.Credentials<host: "…", port: 5552, vhost: "/", username: "…", ...>`. Код
  потребителя не правится.
- **`Mq.Stream.Reader` дропает запись, чей `topic` в конверте не совпадает с подпиской.** Топик
  в конверте пишет продюсер, а позицию записи в потоке задаёт подписка: чужая запись уходила в
  handler как своя. Стало — `warning` и `decode_drop`, как у нечитаемой записи: адаптер не отдаёт
  наверх то, чью принадлежность не может подтвердить. `warning` пишется один раз на подписку:
  чужой топик — состояние мисконфигурации, и запись о каждой записи залила бы лог со скоростью
  чтения.
- **`decode_drop` чанка с sub-entry batching считается в entries, а не в records**, и такой чанк
  теперь эмитит `deliver`. Числитель и знаменатель drop-rate (`mq.decode_drop.total` /
  `mq.deliver.entries.total`) были в разных единицах, а дропнутый чанк вообще не попадал в
  знаменатель. Число потерянных записей осталось в тексте `error`-лога; дашборд с делением этих
  метрик становится верным сам.
- **`Mq.Stream.Codec` не кладёт разбираемую запись в `Error.detail`.** Было тело чужого сообщения
  целиком — объём не ограничен, содержимое библиотеке неизвестно, а `detail` уходит в лог
  потребителя. Стало: `{:redacted, byte_size}` для binary, `:redacted` для остального,
  `%{position, token}` для `Jason.DecodeError`. Коды ошибок не изменились; код потребителя,
  разбиравший `detail` этих ошибок, читать в нём больше нечего.
- **`Mq.Stream.Writer`: `:confirm_timeout_ms` — дедлайн на пачку, а не на топик; producer
  неподтверждённого топика снимается.** Таймаут отсчитывался заново для каждого топика, поэтому
  пачка из N топиков ждала до N × timeout и переживала `:shutdown` и writer'а, и вызывающего
  поллера — супервизор добивал обоих посреди подтверждения. Кеш producer'а после неподтверждения
  оставался с локальным `sequence` впереди брокерского, и сверка не сходилась, пока в топик не
  пойдёт новый трафик; теперь producer снимается и в кеше, и в брокере, а следующая пачка
  объявляет его заново и перечитывает sequence. Снимается он **только** по таймауту: оборванное
  соединение чистит кеш веткой `:DOWN`, и снимать producer ещё и там значило бы пересоздавать
  его на каждой пачке, пока брокер недоступен. Сам кеш ограничен опцией `max_producers`
  (default 256) — при переполнении вытесняется топик, в который дольше всех не публиковали.
  Вытеснение идёт на границе пачки: внутри неё кеш только растёт, иначе при тесном лимите
  оно сняло бы producer топика, публикацию в который эта же пачка ещё подтверждает.
- **`Mq.Kafka.Writer.put_many/2` предупреждает о вызове внутри транзакции** — как
  `Mq.Stream.Writer`. Publish внутри `Transact.run` запрещён (`20-agreements.md`), но на
  Kafka-пути нарушение было молчаливым.

- **`Core.Mq.PromEx`: опция `readers:` — MFA-провайдер, а не список.** Было
  `readers: MyApp.PromEx.Mq.readers()`, стало `readers: {MyApp.PromEx.Mq, :readers, []}` — как
  `watch:` у `Core.Workers.PromEx` и `sizes:` у `Core.Cache.PromEx` (`10-architecture.md`).
  Список процессов принадлежит рантайму потребителя, а не моменту сборки метрик: reader, поднятый
  позже, в статический список не попадал. Без опции polling-группа reader'ов не строится вовсе
  (раньше строилась пустой).
- **`Mq.Stream.Reader` и `Mq.Stream.Writer` проверяют свои опции в `init/1`.** Мусор в них теперь
  `ArgumentError` с именем опции и ожидаемым значением. Раньше `initial_offset: :stored_offset`
  ронял reader `FunctionClauseError` уже в `handle_continue/2` — супервизор уходил в цикл
  рестартов и валил поддерево, а `credit: "2"` давал вечную переподписку с backoff, в которой
  опечатка неотличима от недоступного брокера.
- **Отброшенная запись двигает offset** (`Mq.Stream.Reader`, reliable-режим). Повтор дал бы тот же
  дроп, а без сохранения курсор оставался позади, и хвост из одних нечитаемых записей
  перечитывался и отбрасывался после каждого рестарта. Пишется offset не на каждую запись, а
  одним `store_offset` на серию — когда за дропами не осталось читаемых записей; `commit/1`
  подписчика серию перекрывает. Иначе чанк из полусотни нечитаемых entries давал бы полсотни
  cast'ов в соединение, а на оборванном — столько же `warning`. Накопленное сохраняется и в
  `terminate/2`, рядом со снятием подписки: иначе штатная остановка отдавала бы хвост назад
  брокеру, и он перебирался бы заново на следующем старте.
- **Чанк, пришедший без подписки, игнорируется целиком** (`Mq.Stream.Reader`). Раньше он попадал в
  буфер и в метрику `deliver`, хотя `get` при потерянной подписке отдаёт `:empty`, а переподписка
  буфер сбрасывает: доставленным считалось то, что никто не прочитает.
- **`exit` адаптера описан в контракте и больше не роняет подписчика.** `{:error, _}` в
  `Mq.Writer` / `Mq.ReaderReliable` покрывает отказ брокера, а `GenServer.call` к мёртвому или
  зависшему адаптеру приходит `exit` — теперь это сказано в обоих behaviour вместе с тем, кто его
  ловит: единица работы целиком (`Outbox.Poller` — цикл, `MqSubscriberReliable` — чтение и commit).
  `PubSub.MqSubscriberReliable` раньше падал на `get`/`commit` недоступного reader'а, теперь отдаёт
  цикл `:error` с `:reader_unavailable` и уходит в backoff. Ниже по стеку `exit` в `{:error, _}`
  не превращается: выдав недоступность процесса за отказ брокера, `Delivery.Mq` засчитывал бы
  записи попытку публикации — вплоть до `:failed` из-за инфраструктурного сбоя.
- **`Mq.Kafka.Writer` ловит любое исключение клиента**, а не только `RuntimeError`: klife падает
  исключением там, где контракт ждёт `{:error, _}`, и непойманное уносило `Outbox.Poller`.
  `detail` ошибки `:kafka_publish_failed` сведён к трём формам — атом распознанной причины
  (`:unknown_metadata_for_topic`), `{:error_code, code}` брокера либо текст; было четыре, включая
  сырой кортеж клиента и голое число кода (`detail: 1` → `detail: {:error_code, 1}`).

- **`Mq.Stream.Reader.info/1` отдаёт `dropped_offset`**, а `Core.Mq.PromEx` — gauge
  `mq.reader.chunk_remaining`. Первое объясняет состояние «курсор отстал, а очередь пуста»
  (накопленный, но ещё не сохранённый дроп), второе показывает недопотреблённый чанк: поле
  `chunk_remaining` в `info/1` было, а метрики по нему не было.

- **`Agg.Process.execute` отдаёт версию после commit.** Результат — `{:ok, Version.t() | nil} |
  {:error, Error.t()}` вместо `:ok | {:error, Error.t()}`, одинаково при `enabled: false`, через
  процесс на id и после повторов на `:version_mismatch`; `nil` — команда без событий на пустом
  потоке. Процесс (вышел в v0.2.0) отбрасывал состояние после записи, а версия нужна usecase для
  ответа 202 с `{id, version}` (`app/15-web-api.md`, «Ожидание проекции») и клиенту — для
  следующего `If-Match`: команда, чей ответ несёт версию, шла мимо процесса через `Transact.run`.
  Наружу уходит только версия, не состояние (CQS). Сгенерированный `execute` сужает результат
  паттерном: clause `:ok` или `{:ok, %Agg{}}` по нему — предупреждение при сборке. Telemetry и span
  команды — прежние. Исключение «версии после записи у этого пути нет» убрано из
  `app/10-architecture.md`, «Usecases»; норма — `13-repos.md`, «Процесс агрегата».

  ```elixir
  # было
  with :ok <- Account.Process.execute(id, version, command, context), do: :ok
  # стало
  with {:ok, written} <- Account.Process.execute(id, version, command, context), do: {:ok, written}
  ```

- **`Outbox.Poller`, `Outbox.Cleaner` и `PubSub.MqSubscriberReliable` проверяют опции при старте.**
  Разбор идёт через `Core.Helper.StartOpts`: ошибка конфигурации роняет старт `ArgumentError` с
  меткой процесса и именем опции, а не всплывает в цикле и не подменяется молча
  (`17-otp-concurrency.md`, «`init/1`»). Типы опций и арифметика значений прежние: `retry_max_ms`
  подписчика не меньше `poll_interval_ms`, `retry_min_ms` cleaner'а не больше `interval_ms`.
  Теперь роняют старт:
  - неизвестная опция — было: игнорировалась, и опечатка в необязательной молча давала значение
    по умолчанию. `shutdown:` у `Outbox.Cleaner` тоже неизвестна — его `child_spec/1` её не читал;
  - отсутствие обязательной — было `KeyError` без имени процесса;
  - значение не той формы — было: падало позже и без имени опции. Prim голым значением
    (`batch_size: 10`, `published_ttl: 60`) и не-модуль в `repo:` давали ошибку каждого цикла и
    backoff; `from_message:` / `on_message:` не той арности — `:handler_crashed` на каждом
    сообщении и повторы до DLQ; `context_factory:` не той арности — `BadArityError` в `init/1` у
    поллера и cleaner'а, у подписчика — падение на первом сообщении и цикл рестартов. Ноль в
    интервалах и `max_attempts` — было: цикл без паузы (`poll_interval_ms: 0`, `idle_min_ms: 0`,
    `interval_ms: 0`, `retry_min_ms: 0`) либо DLQ на первой неудаче (`max_attempts: 0`); ноль и
    отрицательный `retry_max_ms` подписчика молча поднимались до `poll_interval_ms`;
  - `topic:` / `dlq_topic:` подписчика не непустой строкой — было: подстановка `"unknown"` /
    `"<topic>.dlq"`, в том числе для `topic: Mq.Topic.new!(...)` вместо строки. Отсутствующие
    опции получают эти значения по-прежнему;
  - `dlq_writer:` без `dlq_handle:` — было: `put(nil, _)` проваливался на каждой попытке DLQ;
    `dlq_handle:` без `dlq_writer:` — было: DLQ молча выключен. Опции задаются только парой;
    `nil` в них по-прежнему означает отсутствие;
  - `name:` (у всех трёх) и `shutdown:` (у поллера и подписчика) не той формы — `ArgumentError`
    из `child_spec/1`; было — отказ супервизора или `GenServer.start_link` без имени процесса.
    `name: nil` — по-прежнему процесс без имени.

  Правка потребителя — значение, а не удаление проверки:

  ```elixir
  # было — старт проходил, метки метрик и DLQ-топик — "unknown" / "unknown.dlq"
  {Core.PubSub.MqSubscriberReliable, topic: Mq.Topic.new!("orders"), ...}
  # стало — ArgumentError «опция :topic — ожидается непустую строку»
  {Core.PubSub.MqSubscriberReliable, topic: "orders", ...}
  ```

- **`Core.Web.Params.version/2` заменён тремя формами разбора `If-Match`.** `version/2` не
  говорил, какую форму брать команде и чтению, и приложения держали свои хелперы с недостающими
  формами. У всех трёх `key \\ :"If-Match"` — имя параметра схемы запроса; `""` и мусор — ошибка
  разбора `Version` (400):
  - `explicit_version/2` — только явная версия: `*` —
    `%Error{kind: :domain, ns: :web, code: :current_not_allowed}` (400), нет параметра —
    `:missing_param`;
  - `expected_version/2` — семантика прежней `version/2`: `*` → `:current`, нет параметра —
    `:missing_param`;
  - `optional_version/2` — нет параметра и `*` → `:current`.

  Результат сужен паттерном: `{:ok, %Version{}}` у `explicit_version/2`,
  `{:ok, %Version{} | :current}` у двух других; у `version/2` вывод типов давал потребителю
  `dynamic()`.
  Норма `app/15-web-api.md`, «Controller»: команда — `explicit_version/2`; `*` на команде —
  `expected_version/2`, только если исход команды не зависит от состояния, которое видел клиент
  (выдача роли, увеличение счётчика); чтение по версии — `optional_version/2`; параметр `If-Match`
  в `operation/2` описывается той же формой. Команда без `If-Match` запрещена: было — нет
  заголовка → `:current`, и забытый заголовок молча затирал конкурентные изменения; стало —
  `explicit_version/2` либо явный `*` через `expected_version/2`.

  ```elixir
  # было
  with {:ok, version} <- Params.version(params), do: Agg.take(id, version, context)
  # стало — команда
  with {:ok, version} <- Params.explicit_version(params), do: Agg.take(id, version, context)
  # стало — команда, чей исход не зависит от увиденного состояния
  with {:ok, version} <- Params.expected_version(params), do: Agg.grant(id, version, context)

  # было — чтение и команда без заголовка шли по :current
  version = if header, do: Version.parse!(header), else: :current
  # стало — чтение
  with {:ok, version} <- Params.optional_version(params), do: ReadRepo.get(id, version, context)
  # стало — команда: explicit_version/2 либо явный `*` через expected_version/2
  ```

### Новое

- **`Core.Es.Projection.Test.with_rebuilding/2` — подставленная пересборка на время блока.**
  При тестовом дереве `await: :inline` ветка неготовой read-модели была недостижима вовсе:
  `await/3` прогоняет проекцию в процессе теста, а иной исход — `RuntimeError`. Хелпер на время
  блока переводит отметку дерева на `await: :poll` и снимает строку чекпоинта, поэтому `await/3`
  внутри отдаёт `:projection_rebuilding` сразу, не читая таймаут вызывающего; в `after`
  возвращает и отметку, и строку — со своей позицией, так что следующий `run_until_idle/2`
  досчитывает события, а не зовёт `clear/0`. Контракт `await/3` не менялся: третьего режима нет,
  опции дерева хелпер берёт из отметки. Принимает модуль или список: отметка общая для ноды, и
  проекция, которую блок ждёт, но не назвал, ушла бы в опрос до своего таймаута. Дерево не
  стартовало — `RuntimeError`, проекция не из `projections:` или дерево запущено
  (`enabled: true`) — `ArgumentError`. Норма — `19-testing.md`, «Ветка неготовой read-модели».

  ```elixir
  conn =
    Core.Es.Projection.Test.with_rebuilding(MyApp.Domain.<BC>.Common.Projection, fn ->
      patch(authed(ctx), "#{@path}/#{id}", body)
    end)

  assert %{"data" => %{"version" => 2}} = json_response(conn, 202)
  ```

- **Ратчет wire-тегов событий: `use Core.Es.Event.TagsCase, otp_app: …`.** Норму
  «тег квалифицирован типом агрегата и уникален на всё приложение» (`app/14-events-outbox.md`)
  каждое приложение держало своим тестом или не держало вовсе: сборка кодека видит один кодек и
  столкновение тегов двух агрегатов ей не видно. Теперь библиотека отдаёт тест-модуль на все кодеки
  приложения (модули с `__es_type__/0`): формат `type:` (`^[a-z][a-z0-9_]*$`), тег — `type:` плюс
  один и более сегментов `.<snake_case>`, уникальность тега и уникальность `type:` между кодеками.
  Теги кодека — значения `tags:` плюс ключи `upcasts:`. `otp_app:` принимает и список приложений:
  `es_events` одна на базу. Записанный тег без префикса снимается адресно — `except_tags:`
  и `except_types:`; уникальность исключениями не снимается. Контракт `use Core.Es.Event.Codec`
  не изменился. Почему тест, а не `CompileError`, — `docs/adr/0020-event-tag-ratchet.md`.

  ```elixir
  # было — своя копия сверки в каждом приложении
  test "теги событий уникальны" do
    for mod <- codec_modules(), do: assert_prefixed(mod)
  end

  # стало — test/my_app/es/event_tags_test.exs
  defmodule MyApp.Es.EventTagsTest do
    use Core.Es.Event.TagsCase,
      otp_app: :my_app,
      async: true
  end
  ```

- **Резерв ключа: неограниченный повтор заменён разбором отказа и кодом
  `:reservation_unresolved`.** `Core.Es.KeyReservation` после отказа вставки читал владельца по
  одному ключу и при пустом ответе уходил в `reserve` заново — без счётчика попыток, внутри уже
  открытой транзакции команды. Теперь отказ разбирается строками области: строка нашего ключа
  называет владельца, строка пары `(scope, aggregate_id)` с другим ключом означает чужую запись
  после нашего `DELETE`, пустой ответ — снятый между вставкой и чтением ключ. Обе причины снимает
  одна следующая попытка, поэтому повтор ровно один; второй отказ подряд —
  `%Error{kind: :app, ns: :es, code: :reservation_unresolved}` с `scope`, `aggregate_id` и
  причиной в detail (реестр кодов — `12-errors.md`). Для корректного вызова исход не изменился:
  занятый ключ по-прежнему `errors.domain(behaviour, code, %{scope: scope})`, clause в каталоге
  `<Aggregate>.Errors` добавлять не нужно. Потребителю, который разбирает `%Error{}` на границе:
  новый код доменным не притворяется и уходит в 500 с логом, а не в 400 «ключ занят». Разбор и
  почему `conflict_target` не сужается — moduledoc `Core.Es.KeyReservation`, «Разбор отказа
  вставки». Норма яруса потребителя (`app/12-errors.md`): clause `:reservation_unresolved` в
  каталоге `<Aggregate>.Errors` MUST NOT — как и `:unknown_event_type`, эту ошибку строит
  библиотека.

- **`Core.Es.Transact` — транзакция команды с повтором по источнику отказа записи.**
  `run/2` отдаёт результат колбэка, `run_counted/2` — `{результат, число повторов}` для telemetry
  вызывающего. Сам открывает `Core.Helper.Transact.run/3` на `Core.Config.dao/0` и повторяет всё
  тело новой транзакцией, пока отказ несёт `source: :storage`; `retries:` по умолчанию 3, паузы
  между попытками нет, вызов внутри открытой транзакции — `ArgumentError`, повтор — `debug`,
  исчерпание — `warning`. Не повторяются сверка ожидаемой версии, список detail (`get_many`),
  detail без `source:` и `{:error, reason}` с не-`%Core.Error{}`. Обёртка повтора в приложении
  (`MyApp.Transact.run(version, fun)`) заменяется на него: о потоке, который отказал, она не
  знает. `Core.Es.Aggregate.Process` исполняет команду через `run_counted/2`.

  Норма яруса потребителя: раздел `app/13-repos.md` «Повтор при `:current`» переименован в
  «Повтор после отказа записи» — команда event-sourced агрегата в теле usecase MUST идти через
  `Core.Es.Transact.run/2` (либо через процесс агрегата), своя обёртка над `Transact.run` —
  MUST NOT; команда state-stored агрегата MAY идти тем же путём.

  ```elixir
  # было — повтор по ожидаемой версии, своя обёртка на приложение
  MyApp.Transact.run(version, fn -> ... end)
  # стало
  Es.Transact.run(fn -> ... end)
  ```

- **Свод приложения-потребителя (`docs/rules/app/*.md`).** Второй ярус свода: нормы, общие для
  любого приложения на `Core.*` — раскладка слоёв и boundary, конвенция usecase и таблица
  «что можно внутри `Transact.run`», профили Codec и реестр плагинов, словарь `ns` и каталоги
  ошибок, раскладка репозиториев и View, теги событий и идемпотентность потребителей, граница
  HTTP, кеш поверх read-пути, дерево процессов и тумблеры, миграции, тесты и ратчеты, состав
  пайплайна `make`, наблюдаемость. Приезжает к потребителю вместе с зависимостью
  (`deps/core/docs/rules/app/`). Приложение переводит свой свод в дельту: у себя остаются
  инвентарь, локальные решения и `DEBT.md`, а нормы, совпадающие с этим ярусом, удаляются —
  копия расходится с оригиналом на первом же `mix deps.update core`. В карте `AGENTS.md`
  приложения и в его `SKILL.md` рядом с локальным файлом и одноимённым сводом библиотеки
  добавляется третья ссылка — `deps/core/docs/rules/app/NN-*.md`. Стандарт яруса, критерий
  «сюда или в локальный свод» и порядок доставки — `deps/core/docs/rules/app/00-index.md`.
  `make rules-check` проверяет оба яруса и падает на пути модуля с корнем конкретного
  потребителя в `app/**` (у `--consumer` этой проверки нет).

  Тема, у которой в приложении нет локального файла (`22-projections.md` есть только в своде
  библиотеки, либо локальный файл опустел после переноса норм), доставляется так же: строкой
  карты `AGENTS.md` с путём `deps/core/…` и скиллом на её файлы в ярусах. Локальный
  `docs/rules/00-index.md` обязателен и несёт карту, словарь имён приложения и ссылки на оба
  стандарта; пересказ стандартов в нём MUST NOT.

  Ссылка между ярусами пишется путём от корня приложения-потребителя
  (`deps/core/docs/rules/13-repos.md`, `deps/core/docs/rules/app/16-caching.md`), внутри своего
  яруса — именем файла. Путь `docs/rules/NN-*.md` в ярусах запрещён: у потребителя он адресует
  его локальный свод, то есть файл соседнего яруса с тем же именем, и отличить это от опечатки
  нельзя. Словесная пометка «(свод приложения)», которой раньше помечались ссылки из свода
  библиотеки, отменена — вместо неё путь. Таблица адресации —
  `deps/core/docs/rules/app/00-index.md`, «Адресация ссылок».

  У `20-agreements.md` скилла нет ни на одном ярусе, поэтому доставляется он импортом: в
  `AGENTS.md` приложения MUST быть три строки — `@deps/core/docs/rules/20-agreements.md`,
  `@deps/core/docs/rules/app/20-agreements.md` и `@docs/rules/20-agreements.md` (последняя —
  если свой файл этой темы есть). Без первых двух ярусы в контекст не попадают вовсе.

  Проверку ведёт один скрипт: `deps/core/scripts/rules_lint.exs --consumer` — так же, как
  `boundary_lint.exs` и `layout_lint.exs`, потребитель зовёт его из `deps/core/scripts/` и своей
  копии не держит (копия расходится и начинает проверять прошлую редакцию стандарта). Режим
  потребителя проверяет форму локального свода, его карты в `00-index.md` и `AGENTS.md`,
  разрешимость ссылок `deps/core/…`, скиллы с тремя файлами темы (и у тем без локального файла),
  импорты `20-agreements.md` и симлинк `CLAUDE.md` → `AGENTS.md`; нет локального индекса —
  нарушение, а не падение скрипта. Цель `rules-check` в `Makefile` приложения меняется на этот
  вызов. Приложению, у которого нет скилла `projections`, после обновления нужны
  `.claude/skills/projections/SKILL.md` со ссылкой на `deps/core/docs/rules/22-projections.md` и
  строка этого пути в карте `AGENTS.md`.

  Приложению, которое уже перевело свод на ярус по его первой редакции, сверить:

  - у read-репозитория свои `Specs` (`read_repo/pg/specs.ex`), общие с write-путём фрагменты MAY
    выноситься; прежняя норма «Specs у агрегата одни, в write-каталоге» снята;
  - доменная ошибка обработки в MQ и фоновой задаче — `{:skip, reason}` с логом, а не повтор до
    DLQ; `{:error, _}` — только сбои, которые чинит повтор;
  - конверсия Prim в `evolve/2` — bang, строка `DEBT.md` под неё больше не нужна;
  - старт: `ensure_available!/0` — только у используемых адаптеров брокера,
    `Core.Outbox.check_singleton!/1` из `start/2` вместо своей копии и ратчет на этот вызов,
    `Core.Outbox.validate_partition!/1` — при нескольких поллерах;
  - `watch_list` — без элементов выключенного поддерева (`required:` плагин не читает); префикс
    имён метрик — `otp_app` из `use PromEx`, а не `telemetry_prefix`;
  - поддерево подписчиков брокера: DLQ-writer → reader и подписчик; подписка при старте —
    опция `Core.PubSub.MqSubscriberReliable` `subscribe: true` (данные — `subscribe_data:`,
    по умолчанию `nil`, только вместе с `subscribe: true`, иначе `ArgumentError` на старте),
    а не процесс-bootstrap с `subscribe/3` последним ребёнком: копии такого процесса расходились
    по семантике отказа, и сбой в лог с нормальным выходом терял подписку молча. Было —
    свой процесс, зовущий `subscribe(subscriber, nil, context)`; стало — ребёнок удаляется,
    подписчику добавляется `subscribe: true`. По умолчанию опция `false`: подписчик, которому
    `subscribe/3` зовут снаружи, работает как раньше, а с опцией внешний вызов получил бы
    `:already_subscribed`;
  - `MyApp.DataCase` поднимает sandbox `start_owner!(DAO, shared: not tags[:async])`; причины
    `async: false` — три группы из `deps/core/docs/rules/19-testing.md`, «Case-модули» (общему
    sandbox `on_exit` не нужен);
  - раскладка репозиториев — в `common/<aggregate>/`, actor-репозиторий — под ACL-фильтр среза;
    раскладка проекции задаётся только ярусом (`app/13-repos.md`), запись о ней в `DEBT.md` не
    нужна;
  - нормы, продублированные ярусом и сводом библиотеки (контракты репозиториев, дерево
    проекций, алерты проекций, runbook и конфигурация outbox, граница HTTP), оставлены в одном
    месте — ссылки локального свода на разделы ярусов проверить по заголовкам.

  Ярус нормирует **текущий** контракт, включая event sourcing: единое хранилище `es_events`
  вместо таблицы и `Event.Repo` на агрегат, `use Core.Es.Aggregate` с `decide` / `evolve` и
  команды `use Core.Es.Cmd`, репозиторий агрегата в common без role-обёрток, повтор при
  `:current`, снапшоты, процесс агрегата, id потока от естественного ключа вместо уникального
  индекса состояния, проекции и их раскладка в приложении, `page_stream` вместо
  `page_by_aggregate`, апкаст вместо «тег неизменяем навсегда», дерево проекций и его опции,
  `Core.Es.Migration` и удаление чекпоинта, тесты через `Core.Es.Aggregate.Test`,
  `Core.Es.EventCompatCase`, `Core.Es.ProjectionCase` и `Core.Es.Projection.Test`, алерты
  `Core.Es.PromEx`. Приложению, собранному на прежней версии,
  `deps/core/docs/rules/app/00-index.md`,
  «Версия библиотеки» даёт таблицу «устаревшая форма → текущая»: по ней видно, что в коде
  читается как норма, но ею уже не является.

- **Свод библиотеки сведён с ярусом потребителя.** Нормы раскладки и эксплуатации приложения
  ушли из `docs/rules/*.md` в `docs/rules/app/*.md`, свод библиотеки оставил контракт `Core.*`:
  раскладка репозиториев, View и проекций, env дерева проекций и `MyApp.Projections`,
  конфигурация `OUTBOX_*`, единственность поллера, runbook `:failed`, Oban-ключи
  идемпотентности, `ContextFactory`, алиасы профилей Codec и репозитория агрегата, ратчеты
  описаний enum и `constraint_errors`. Новое в своде библиотеки:
  - `20-agreements.md`: конверсия Prim в `evolve/2` — bang; `@spec` не нужен экшенам
    контроллера с `operation/2`; версия после записи и id созданного агрегата — результат
    собственного выполнения команды, а не отступление от CQS; `IO.puts` вместо `Logger` —
    MUST NOT (`Credo.Check.Refactor.IoPuts`);
  - `10-architecture.md`, «Граница HTTP» — таблица кодов `Core.Web.ErrorMapper`
    (`:version_mismatch` → 412, `:access_denied` → 403, `auth_codes:` → 401);
  - `12-errors.md` — коды, которые сборка проверяет в каталоге `errors:` у каждого макроса
    репозитория, и таблица `ns`, которые ставит библиотека;
  - `21-observability.md`, «Рекомендованные алерты» — PromQL для outbox, MQ, подписчиков,
    workers и кеша на метриках `my_app_prom_ex_<плагин>_…`;
  - `19-testing.md` — гонки транзакций мимо sandbox (`unboxed_run/2`), `Core.Es.Store.Test`,
    тестовое дерево проекций `await: :inline` стало MUST.

  Линтеры, которые потребитель зовёт из `deps/core/scripts/`, стали строже: `boundary_lint.exs
  --consumer` ловит `Application.compile_env` на ключ `…ReadRepo` так же, как на `…Repo`;
  `layout_lint.exs` — `# ---` перед блоком `# ===== общее =====` и маркер внутри `quote`;
  `rules_lint.exs` — незакрытый fenced-блок и fence в конце строки с кодом. В режиме потребителя
  сообщения всех трёх указывают путь `deps/core/docs/rules/…`. Как править: `compile_env` на
  ReadRepo → `Core.Config.repo!/1`; лишний `# ---` перед `общее` и маркер в `quote` — удалить.

- **`Core.Bind`** — макрос `bind/1`, аналог `use` из Gleam: строки `pattern <- call` разворачиваются
  в цепочку колбэков вместо лестницы отступов у bracket-функций (`File.open`, `Transact.run`,
  `:timer.tc`). Слева `x` / `{:ok, x}` — одноарный колбэк, `[]` — нуль-арный, `[a, b]` — двухарный;
  колбэк дописывается последним аргументом либо встаёт на место маркера `_`
  (`Transact.run(DAO, _, opts)`). Подключается `import Core.Bind`. Цепочки
  `{:ok, _} | {:error, _}` он не заменяет — там `with` с `else`.
- **`Core.Helper.StartOpts`** — проверка опций OTP-процесса в `init/1` (`module!/3`, `atom!/3`,
  `prim!/4`, `binary!/3`, `pos_integer!/4`, `boolean!/4`, `one_of!/5`, `raise_invalid!/4`): `ArgumentError` называет опцию,
  ожидаемое значение и полученное. `Core.Helper.Opts` остаётся про опции `use`-макросов и
  compile-time. Формы для процессов outbox и подписчика: `keys!/3` — неизвестные опции, зовётся
  первым; обязательные `pos_integer!/3`, `fun!/4` (функция заданной арности) и `term!/3` (любое
  значение, кроме `nil`); необязательные `module!/4` (модуль или `nil`), `binary!/4`, `fun!/5`,
  `topics_filter!/4` (`Core.Outbox.topics_filter()`), `name!/3` (`GenServer.name()` или `nil`) и
  `shutdown!/4` (неотрицательное целое, `:infinity` или `:brutal_kill`).
- **`Core.Mq.Stream.Buffer`** — буфер записей подписки и учёт кредитов, вынесенные из
  `Mq.Stream.Reader`: `new/0`, `put_chunk/2`, `take/1`, `len/1`, `remaining/1`. Кредит — число
  in-flight чанков, и его счёт держится на трёх счётчиках сразу; отдельной структурой он
  проверяется без соединения, подписки и GenServer, а reader только выдаёт брокеру то, что
  структура насчитала.
- **`Core.Mq.Client.ensure_available!/1`** — общая проверка «optional-клиент есть и адаптер собран
  с ним»; `Core.Mq.Stream.ensure_available!/0` и `Core.Mq.Kafka.ensure_available!/0` делегируют ей,
  а новый адаптер получает её строкой опций вместо копии `cond`.
- **`Core.Outbox.check_singleton!/1`** — отказ старта включённого outbox в кластере: при
  `enabled?: true` и заданном `cluster_query:` — `ArgumentError` с инструкцией, с
  `allow_cluster?: true` — старт и `warning`; `cluster_query` `nil`, `:ignore` и `""` —
  кластеризации нет. Свод требовал этой проверки, а функции не было: каждое приложение держало
  свою копию в супервизоре очереди, и копии расходились (где-то `""` считался кластером) и не
  везде были покрыты тестом. Значения передаются опциями — ключ кластеризации принадлежит
  приложению. Приложение удаляет свою копию (`Outbox.Supervisor.check_singleton!/0` с
  `clustered?` / `allow_cluster?`), её вызов из `start_link/1` супервизора очереди и её тесты
  (`describe "check_singleton!/0"`) и зовёт проверку из `start/2` до подъёма дерева:

  ```elixir
  outbox = Application.get_env(:core, Core.Outbox, [])

  Core.Outbox.check_singleton!(
    enabled?: Keyword.get(outbox, :enabled, false),
    cluster_query: Application.get_env(:my_app, :dns_cluster_query),
    allow_cluster?: Keyword.get(outbox, :allow_cluster, false)
  )
  ```

  Ратчет приложения — «`start/2` зовёт `check_singleton!/1`»
  (`deps/core/docs/rules/app/19-testing.md`, «Ратчеты»).
- **Трассировка OpenTelemetry на транспорте библиотеки** (`Core.Otel`,
  `Core.Otel.Messaging`, `Core.Otel.LogFilter`). Зависимость — только
  `opentelemetry_api`: без SDK у потребителя все вызовы no-op. Готовые интеграции
  (Phoenix / Ecto / Oban) рвутся на outbox — событие пишется в одном процессе,
  публикуется поллером в другом, читается подписчиком в третьем, — поэтому контекст
  переносится заголовками: `<Aggregate>.Outbox.from_event/1` кладёт `traceparent`
  команды в `Record.headers`, `Delivery.Mq` открывает `"create <topic>"` на каждое
  сообщение и `"send <topic>"` на пачку со ссылками на них, `MqSubscriberReliable` —
  `"process <topic>"` с родителем из заголовков. Имена и структура — по semantic
  conventions messaging; `Core.Otel` при этом предметно нейтрален, словарь semconv
  живёт в `Core.Otel.Messaging`. `Core.Otel.LogFilter.filter/2` — primary-фильтр
  `:logger`, кладущий `trace_id` / `span_id` в metadata (OTLP-экспорт логов для BEAM
  не выпущен). Метрики остаются в PromEx. Подключение — раздел «Трассировка» в README,
  правила — `docs/rules/21-observability.md`.
- **`Delivery.Mq` добавляет к сообщению `traceparent`** — единственный заголовок, который
  доставка ставит от себя. Прикладные заголовки по-прежнему целиком задаёт продюсер записи,
  а `to_message/1` остаётся чистым преобразованием и заголовков не трогает.
- **Конверт доменного события** (`Core.Es.Event.Codec`): `dump_envelope/4` собирает его при
  постановке события в очередь и при записи в event store, разбор идёт через фасад
  (`codec.load(<Aggregate>.Event, data)` → `load/3` плагина). Разбор **safe**: неизвестный тег
  даёт `:unknown_event_type`, отсутствующее обязательное поле — `:invalid_envelope`
  (обе — `ns: :es`), а не падение подписчика. `to_fields/1` / `from_fields/1` — мост к
  транспортам, хранящим поля события врозь.
- **`Core.Prim.UUID` перестал разбирать строку дважды.** `cast/1` больше не зовёт `UUID.info/1`
  перед конверсией: разбор делает сам `string_to_binary!/1`, а невалидное значение по-прежнему
  становится `{:error, {:invalid_uuid, _}}`. `format/2` переводит **каноническую** форму срезкой
  (`:full` — тождественно), к библиотеке обращаясь только для hex, urn и верхнего регистра.
  Поведение не изменилось: любая форма ввода по-прежнему нормализуется, — изменилась цена.
  На поле `uuid` уходит 142 слова вместо 1383 и 0.3 мкс вместо 3.5 мкс; дамп страницы из
  1000 строк с четырьмя форматируемыми полями оставляет 5 МБ мусора вместо 14.5 МБ и вызывает
  1 minor GC вместо 130.
- **`Core.Codec.coerce/2`** — значение без Prim-обёртки → Prim (`cast` + `mutate` leaf-примитива,
  цепочка `Prim.Compose` целиком), и **`Core.Codec.Helper.dump_raw/3`** поверх него: read-путь
  дампит значение обычным `codec.dump/1`, поэтому разойтись с агрегатным путём ему больше нечем.
- **`union:` у `Core.Codec.Plugin`** — модуль-семейство типов для `codec.load/2`; `Core.Es.Event`
  генерирует интроспекцию `__es_payload__/0`, `__es_aggregate_id__/0`, `__es_by__/0`.
- **`Core.Helper.Opts.module_or_config!/4`** — опция-модуль с дефолтом из `Core.Config`,
  подставляемым как **вызов** в рантайме.
- **`Core.Repo.Pg.dao/1`** — Ecto-репозиторий из конфига `@pg`: явный `repo:` либо
  `Core.Config.dao()`.
- **`Core.Web.*` — общая часть границы HTTP** (без новых зависимостей: `plug` и `prom_ex`
  уже были в `deps`, Phoenix и OpenApiSpex не добавляются):
  `Core.Web.Params` (`find` / `get` / `get!` по atom-или-string ключу, `page/2`,
  `explicit_version/2` / `expected_version/2` / `optional_version/2` для `If-Match`),
  `Core.Web.Response` + `Core.Web.Response.Code` (конверт `%{code, messages[, data]}`),
  `Core.Web.ErrorMapper` (`%Error{}` → `{статус, код, текст, уровень лога}`, включая правило
  константного текста на 401), `Core.Web.MetricsPlug`.
  Потребитель расширяется тремя независимыми шагами: свои клозы `map/1` перед
  делегированием в `ErrorMapper.map/2`; свой словарь кодов (`Core.Enum` поверх
  `Core.Web.Response.Code.codes()`); `use Core.Web.Response, codes: MyCode` — конверт
  на этом словаре. Билдер проверяет на компиляции, что словарь целочисленный и покрывает
  базовые значения, которые возвращает `ErrorMapper`.
- **`Core.Helper.Keys`** — camelCase ↔ snake_case ключей map: зеркальная пара
  `camelize/1` / `snakify/1` (рекурсивно по map и спискам, atom- и string-ключи,
  struct проходит значением) и `camelize_key/1` / `snakify_key/1` для одного ключа.
- **`Core.Helper.Map.stringify_keys/1`** — atom-ключи в строки без смены регистра
  (смена регистра — задача `Core.Helper.Keys`).
- **`Core.Repo.Pg.changeset_errors/1`** — ошибки changeset как `%{поле => [текст]}`.
- **`Core.Mutator`** — behaviour (`mutate/2`) и диспетчер мутаторов, зеркало `Core.Validator`.
  Формы шага у `mutate:` / `custom_mutate:` и `validate:` / `custom_validate:` стали одни и те же:
  `{Module, opts}`, `fun/1`, `fun/2` или список любой из них (mutate добрал модульную форму,
  `Core.Validator` — `fun/1`).
- **`pipeline_opts:` у `use Core.Prim`** — опции для шагов `cast` / `mutate` (default — `type_opts`):
  обработке (`trim`, `sec_max_len`) в контракте типа места нет, а шагам она нужна.
- **`Core.Prim.Opts` и `Core.Prim.Wrapper`** — один пролог `use` на все обёртки (набор ключей →
  `kind:` → значения опций) и compile-time проверка **значений**: границы и их порядок, `%Regex{}`,
  `%Date{}` / `%DateTime{}`, IANA-зона `tz:`, версия UUID, boolean-опции. Ошибка в опции обязана
  падать `CompileError` на `use`: в рантайме она приходит доменной ошибкой первого `new/1`, где
  неотличима от невалидного ввода пользователя.
- **`Core.Codec.coercible_kinds/0` и `Core.Codec.coercible?/1`** — kinds, значение которых read-путь
  приводит к Prim (форматируемые профилем плюс `:string` / `:integer`). Единственный источник
  списка: по нему `Core.View` типизирует поля `prim:`, а `Codec.Redump` проверяет спеку формы.
- **`type:` у `Core.Context.Accessor`** — модуль значения: спеки сужаются с `term()` до `<Mod>.t()`,
  а `put/2` принимает только `%<Mod>{}` — чужое значение отсекается на компиляции, а не всплывает
  в репозитории. Сгенерированные функции стали `defoverridable`.
- **`except:` у `Core.Helper.Keys.camelize/2` и `snakify/2`** — список ключей (atom или строка),
  которые не преобразуются: регистр ключа сохраняется, значение под ним не обходится вовсе.
  Нужно для free-form нагрузки на границе HTTP (`metadata`, `payload`), где ключи задаёт не
  контракт API и camelCase их ломает. Арность прежних вызовов не изменилась (`opts \\ []`).
- **`Core.Helper.Opts.atom!/3`** — чтение опции-атома (не `nil`) с `CompileError` вместо тихого
  прохода значения другого типа.
- **Апкаст событий в кодеке агрегата: `upcasts:` + `upcast/2` у `Core.Es.Event.Codec`.** Версия
  схемы события — его тег: несовместимое изменение нагрузки или переименование тега — новый тег,
  а записанные события старого приводятся к текущей схеме при загрузке по семейству
  (`InCodec.load(<Aggregate>.Event, data)`) до выбора модуля. Строки хранилища не переписываются.
  Колбэк `upcast(old_tag, envelope)` отдаёт нагрузку следующего тега; цепочка идёт по шагам
  (v1 → v2 → v3), заголовок конверта не меняется, одно записанное событие — одно прочитанное.
  `CompileError`: источник в `tags:`, цель ни в `tags:`, ни источником, цикл, непустая карта без
  `upcast/2`. Интроспекция — `__es_mods__/0` и `__es_upcasts__/0`; `types/0` и `mod_by_tag/1`
  источников не видят. Правило свода «upcast по `aggregate_version`» снято: версия агрегата не
  разделяет потоки, начатые до и после выкладки (`docs/adr/0010-event-evolution-tag-upcast.md`).

  ```elixir
  @tag_by_mod %{Event.Created => "user.created.v2"}
  @upcasts %{"user.created" => "user.created.v2"}

  use Es.Event.Codec,
    event: User.Event,
    type: "user",
    tags: @tag_by_mod,
    upcasts: @upcasts

  @impl true
  def upcast("user.created", envelope), do: %{"login" => field(field(envelope, :payload), :name)}
  ```
- **Хранилище событий: `es_events`, `Core.Es.Store.append/5` и страница потока
  `page_stream/4`.** Одна таблица событий на приложение, общая для event-sourced и state-stored
  агрегатов; DDL — `Core.Es.Migration` (`up/0` / `down/0`), миграция потребителя делегирует ему, как
  `Core.Outbox.Migration`; она же создаёт `es_snapshots` — снапшоты event-sourced агрегатов — и
  `es_checkpoints` — чекпоинты проекций (база, где миграция из этого цикла уже накатана,
  откатывает и накатывает её заново). Поток —
  тип агрегата (`type:` кодека событий) и `aggregate_id`;
  глобальная позиция — пара `(xid, number)`, при которой запись не ждёт commit чужих транзакций
  (`docs/adr/0008-shared-event-table-xid8-position.md`). `append` пишет пачку потоков одного
  типа в транзакции `DAO` вызывающего и отвергает занятую версию, событие в потоке с более
  поздним `xid` и, с `continuous?: true`, первую версию потока не вслед за головой. Отказ —
  ошибка, которую строит колбэк вызывающего из `%{aggregate_id, expected, actual}`; транзакция
  в aborted не переходит. Записанное тест читает `Core.Es.Store.Test.events!/2`.
  `@repo.page_stream(id, limit, offset, context)` отдаёт страницу потока —
  `Pagination.Result` из `Es.Event` по возрастанию версии с `count` всего потока: апкаст
  действует, нечитаемое событие — `{:error, _}` на всю страницу. Доступ она не проверяет, а
  пустой поток — страница с `count: 0`, поэтому права и существование агрегата usecase
  проверяет до чтения — `ReadRepo.get(id, :current, context)`. Функцию генерирует
  write-репозиторий агрегата любого вида: `use Core.Es.Aggregate.Repo.Pg` (колбэк
  `use Core.Es.Aggregate.Repo`) и `use Core.Repo.Pg.StateStored` (по `event_codec:`, колбэка в
  `use Core.Repo` нет); голова — закрытый struct ID агрегата, результат сужен до
  `{:ok, %Pagination.Result{}} | {:error, _}`. ID другого агрегата, опечатка в поле страницы и
  невозможная clause по результату — предупреждение при сборке вызывающего. Прежняя форма
  `Core.Es.Store.page_stream(Agg.Event.Codec, id, limit, offset, context)` принимала кодек и ID
  параметрами, и сборка молчала: ID заказа при кодеке `Account` давал пустую страницу потока
  `account` с чужим uuid. Реализация переименована в `Core.Es.Store.read_stream/5`
  (`@doc false`): с прежним именем старый вызов собирался бы молча, теперь он даёт
  предупреждение `Core.Es.Store.page_stream/5 is undefined or private`. Тестовый дублёр behaviour
  `use Core.Es.Aggregate.Repo` получает колбэк `page_stream/4`.

  ```elixir
  # было — собиралось, отдавало пустую страницу потока `account` с uuid заказа;
  # теперь — warning: Core.Es.Store.page_stream/5 is undefined or private
  Core.Es.Store.page_stream(Account.Event.Codec, order_id, limit, offset, context)

  # стало — warning: incompatible types given to MyApp.Domain.<BC>.Common.Account.Repo.Pg.page_stream/4
  @repo.page_stream(order_id, limit, offset, context)
  ```

  У потребителя — миграция:

  ```elixir
  defmodule MyApp.Repo.Migrations.CreateEsEvents do
    use Ecto.Migration

    defdelegate up, to: Core.Es.Migration
    defdelegate down, to: Core.Es.Migration
  end
  ```
- **`Core.Es.EventCompatCase` — golden-фикстуры событий проверяет библиотека.** Тест-модуль
  `use Core.Es.EventCompatCase, event_codec: Agg.Event.Codec, async: true` генерирует четыре
  теста: у каждого тега `types/0` есть фикстура; каждая фикстура, кроме источников `upcasts:`,
  несёт в `type` тег из имени файла и грузится фасадом `Core.Config.codec/0` через семейство; у
  каждого источника `upcasts:` есть фикстура; она несёт его тег и грузится апкастом.
  Event-sourced агрегат передаётся `aggregate:` — кодек берётся из его `__es_event_codec__/0`.
  Полноту `evolve` case не проверяет: пятый тест — `evolve(%Agg{id: aggregate_id}, событие)` на
  фикстуре каждого тега — удалён, её проверяет сборка репозитория агрегата (пункт «Event-sourced
  агрегат»); опция `aggregate:` осталась. Семейство
  событий, тип агрегата и карта апкастов берутся из кодека, фикстуры —
  `test/support/fixtures/events/<тип агрегата>/<тег>.json`, другой каталог — `fixtures:`.
  `async:` уходит в `ExUnit.Case` (по умолчанию `true`) и пишется явно ради
  `Credo.Check.Refactor.PassAsyncInTestCases`. Инварианты — контракт кодека библиотеки, поэтому
  case живёт в ней, а не копируется в каждое приложение, где копии молча расходятся. Свой case
  потребителя заменяется:

  ```elixir
  # было
  use MyApp.EventCompatCase,
    codec: MyApp.Codec.Internal,
    event: User.Event,
    aggregate_id: User.ID,
    fixtures: "test/support/fixtures/events/user"

  # стало — каталог по умолчанию берётся из type: кодека, иной задаётся fixtures:
  use Core.Es.EventCompatCase,
    event_codec: User.Event.Codec,
    async: true
  ```
- **`Core.Repo.ConstraintErrorsCase` — сверку `constraint_errors` проверяет библиотека.**
  Тест-модуль `use Core.Repo.ConstraintErrorsCase, otp_app: :my_app, async: true` генерирует пять
  тестов по репозиториям приложения — модулям `otp_app:` с `__constraint_errors__/0`: каждый ключ
  `constraint_errors:` write-репозитория объявлен в `changeset/2` (по `error_type`); каждое
  ограничение `changeset/2` покрыто маппингом; имена ограничений `changeset/2` и ключи
  `constraint_errors:` в `children:` есть у своей таблицы в БД; каждый FK дочерней таблицы, кроме
  FK по колонке `fk:`, покрыт маппингом; read-репозиторий `constraint_errors:` не объявляет.
  Write-репозиторий — модуль с любым из `Core.Repo.write_methods/0` (`insert/3` / `update/3` /
  `save/3`): репозиторий `only: ~w(get save)a` идёт тем же путём, что и с `insert` / `update`.
  `__constraint_errors__/0` и `__children_constraint_errors__/0` генерируются ради этой сверки, а
  сам тест приложения копировали почти байт в байт — копии расходятся молча, поэтому case живёт в
  библиотеке. Списка исключений у case нет. Ратчет приложения заменяется:

  ```elixir
  # было — test/my_app/repo/constraint_errors_test.exs: свои тесты и запросы к pg_constraint
  defmodule MyApp.Repo.ConstraintErrorsTest do
    use MyApp.DataCase, async: true

    test "каждый маппинг constraint_errors объявлен в changeset/2" do
      for repo <- write_repos(), do: assert_declared(repo)
    end
  end

  # стало
  defmodule MyApp.Repo.ConstraintErrorsTest do
    use Core.Repo.ConstraintErrorsCase,
      otp_app: :my_app,
      async: true
  end
  ```
- **`Core.Enum.DocsCase` — описания значений `Core.Enum` проверяет библиотека.** Тест-модуль
  `use Core.Enum.DocsCase, otp_app: :my_app, async: true` генерирует три теста по enum приложения —
  модулям `otp_app:`, которые отбирает `Core.Enum.enum?/1`: у enum есть таблица значений в
  `@moduledoc` (заголовок `| Значение |`); каждое значение `values/0` описано её строкой; первая
  ячейка каждой строки — существующее значение. Приложение без единого enum валит тест-модуль:
  неверный `otp_app:` иначе прошёл бы вхолостую. Норма `11-domain.md` держалась только ратчетом
  приложения, который копировали из приложения в приложение, и копии уже разошлись: отбор модулей
  эвристикой по экспортам вместо `Core.Enum.enum?/1`, у одних — `String.to_atom/1` и нестрогая
  форма ячейки, у других — строгая. Ратчет приложения заменяется:

  ```elixir
  # было — test/my_app/enum_docs_test.exs: свой отбор модулей и разбор таблицы
  defmodule MyApp.EnumDocsTest do
    use ExUnit.Case, async: true

    test "у каждого enum описаны все значения и только они" do
      for mod <- enum_modules(), do: assert_documented(mod)
    end
  end

  # стало
  defmodule MyApp.EnumDocsTest do
    use Core.Enum.DocsCase,
      otp_app: :my_app,
      async: true
  end
  ```

  Форма ячейки теперь записана в норму (`11-domain.md`, «Описание значений в `@moduledoc`»):
  значение в форме `inspect/1` в обратных кавычках. Ячейка `| new |` после перехода валит тесты
  «не описано» и «несуществующее значение» — правится в `` `:new` ``; таблица значений под другим
  заголовком — тест «нет таблицы», заголовок правится в `| Значение |`.
- **Event-sourced агрегат: `Core.Es.Aggregate`, `Core.Es.Cmd`, `Core.Es.Aggregate.Test`.**
  Агрегат, чей источник истины — события, рядом со state-stored. Автор пишет под
  `use Core.Es.Aggregate, event_codec:` два колбэка: `decide(команда, состояние)` →
  `{:ok, [черновик события]} | {:error, Error.t()}` и `evolve(состояние, событие)` →
  состояние. Библиотека генерирует `fold/2` (свёртка истории от любого состояния; разрыв версий
  или чужой `aggregate_id` — `ArgumentError`), `fold/3` (результат `decide` одной команды —
  несколько событий автор сворачивает через `with`), чистый шаг `execute/2` →
  `{:ok, {[Es.Event], состояние}} | {:error, _}` и `__es_event_codec__/0`. `id` события,
  `aggregate_id`, версии по порядку от `state.version`, `by` и `at` из команды ставит библиотека,
  она же ведёт `id` / `version` состояния — в отличие от state-stored агрегата, домен версию не
  трогает; модуль события не из кодека агрегата — `FunctionClauseError`, без `id` / `version` в
  `defstruct` — `CompileError`. Команда — `<Aggregate>.Cmd.<Name>` с `use Core.Es.Cmd`: `by` и
  `at` обязательны в `@enforce_keys`, иначе `CompileError` — автор и момент события приходят из
  данных команды, а не из `Context`. Решения тестируются без БД:
  `Core.Es.Aggregate.Test.given(state, results, by:, at:)` → состояние, then — короткая форма
  результата `decide/2`.

  Ошибки вызова видит компилятор (`docs/adr/0014-consumer-type-safety-by-inference.md`):
  `execute/2` зовёт `decide(command, state)` в модуле агрегата, а не библиотека через
  модуль-переменную, поэтому домен команды — clauses `decide/2`, и команда другого агрегата или
  без clause в `decide` — предупреждение при сборке, а не `FunctionClauseError` в транзакции.
  Головы `execute/2` и `fold/2,3` принимают только `%Agg{}`, результат сужен до
  `{:ok, {[Es.Event], %Agg{}}} | {:error, _}` и `%Agg{}`: опечатка в поле состояния и невозможная
  clause по результату ловятся при сборке. Сужение сгенерировано с `generated: true`, и у
  агрегата, чей `decide` никогда не ошибается или только ошибается, ложных предупреждений нет.

  Полноту `evolve/2` проверяет сборка репозитория агрегата: `use Core.Es.Aggregate.Repo`
  генерирует на каждое событие кодека функцию-проверку (`Core.Es.Check`) с литеральным вызовом
  `Agg.evolve(%Agg{} = state, %Event.Mod{payload: %Payload{}} = event)`. Событие без clause,
  опечатка в ключе `%{state | …}` и в поле нагрузки, не суженной паттерном `%Payload{}`, —
  предупреждение на строке `use`, и имя функции в нём называет нарушенное утверждение. Прежде
  пропущенную clause находил только тест `EventCompatCase` с `aggregate:` — при прогоне и у того,
  кто его подключил, — а опечатки падали `KeyError` при свёртке; тест удалён. Агрегат без
  репозитория полноту не проверяет. Кодек агрегата теперь грузится при сборке репозитория, а
  макрос занимает в модуле behaviour имена функций-проверок `"evolve/2 принимает <Event>"/2`.
  Код потребителя не меняется: сборка с `--warnings-as-errors` падает там, где `evolve` был
  неполон всегда, — правится `evolve`.

  ```text
  # было — тест при прогоне
  1) test у evolve/2 есть клауза события каждого тега (MyApp.Domain.<BC>.Common.Account.EventCompatTest)
     {:error, %{unhandled: [{"test/support/fixtures/events/account/account.closed.json", Event.Closed}]}}

  # стало — предупреждение при сборке
  warning: incompatible types given to MyApp.Domain.<BC>.Common.Account.evolve/2:
  └─ lib/my_app/domain/<bc>/common/account/repo.ex:2: MyApp.Domain.<BC>.Common.Account.Repo."evolve/2 принимает MyApp.Domain.<BC>.Common.Account.Event.Closed"/2
  ```

  Элемент результата `decide/2` — черновик события — строит само событие: `use Core.Es.Event`
  генерирует `draft(%Payload{} = payload)` у события с нагрузкой и `draft()` у события без неё.
  Кортеж, собранный вручную, ни с чем не сверялся: нагрузка другого события и событие с нагрузкой
  без неё падали `FunctionClauseError` / `UndefinedFunctionError` в транзакции. У `draft` модуль
  нагрузки стоит в голове, и те же ошибки — предупреждение при сборке: чужая нагрузка —
  `incompatible types`, неверная арность — неопределённая функция. Событие не из кодека агрегата
  сборка не ловит — оно по-прежнему падает `FunctionClauseError` при исполнении команды. Модуль
  нагрузки, общий у нескольких событий, законен: `draft` у каждого события свой. Черновик живёт в
  событии, а не в кодеке: к wire он отношения не имеет (ADR-0014). `draft` возвращает прежний
  кортеж, поэтому `given/3` и тесты с `{:ok, [Event.Closed]} = decide(…)` не меняются; кортеж
  вручную библиотека по-прежнему принимает, но свод требует `draft` (`11-domain.md`). Нагрузку
  сверяет только вызов у литерала события. Модуль события в переменной (`&event.draft(&1)`) сборка
  не проверяет вовсе — это вызов через модуль-переменную, и свод его запрещает; захват
  `&Event.X.draft/1` сверяет арность, а нагрузку элементов списка не видит ни одна форма. Событие
  другого агрегата сборка не ловит — `FunctionClauseError` при исполнении команды, поэтому у каждой
  ветки `decide` нужен тест через `given/3`. Кортеж от `draft` сборка не отличает и на прежнюю
  форму не предупреждает — однострочные формы находит поиск:
  `grep -rnE '\{Event\.[A-Z][A-Za-z]*, |\[Event\.[A-Z][A-Za-z]*\]|Enum\.map\((.*, )?&\{[a-z_]+, &1\}' lib`.

  ```elixir
  # было
  def decide(%Cmd.Rename{name: name}, %__MODULE__{status: :open}),
    do: {:ok, [{Event.Renamed, Event.Renamed.Payload.new(name)}]}

  def decide(%Cmd.Freeze{}, %__MODULE__{status: :open}), do: {:ok, [Event.Frozen]}

  # стало
  def decide(%Cmd.Rename{name: name}, %__MODULE__{status: :open}),
    do: {:ok, [Event.Renamed.draft(Event.Renamed.Payload.new(name))]}

  def decide(%Cmd.Freeze{}, %__MODULE__{status: :open}), do: {:ok, [Event.Frozen.draft()]}

  # список черновиков — было `Enum.map(role_ids, &{event, &1})`
  Enum.map(role_ids, &Event.RoleGranted.draft/1)
  ```

  ```elixir
  defmodule MyApp.Domain.<BC>.Common.Account do
    use Core.Es.Aggregate,
      event_codec: MyApp.Domain.<BC>.Common.Account.Event.Codec

    defstruct id: nil, version: nil, name: nil, status: nil

    @impl true
    def decide(%Cmd.Freeze{}, %__MODULE__{status: :open}), do: {:ok, [Event.Frozen.draft()]}

    @impl true
    def evolve(state, %Event.Frozen{}), do: %{state | status: :frozen}
  end

  # тест решения
  state = given(%Account{id: id}, [Event.Opened.draft(payload)], by: by, at: at)
  assert {:ok, [Event.Frozen]} = Account.decide(%Cmd.Freeze{by: by, at: at}, state)
  ```
- **Write-репозиторий event-sourced агрегата: `Core.Es.Aggregate.Repo` и
  `Core.Es.Aggregate.Repo.Pg`.** Изменяющий usecase читает состояние, решает и пишет события в
  теле одной функции — `get_decision` → `Agg.execute/2` → `append` под одним `Transact.run`.
  Строки состояния нет: `get(id, version, context)` сворачивает поток агрегата через `fold/2`;
  пустой поток при `:current` — `%Agg{id: id, version: nil}`, а не `:not_found` (существование
  решает `decide`), `%Version{}` мимо головы потока — `:version_mismatch` (у пустого `actual: nil`).
  `get_decision(id, version, context, fun)` — чтение с решением `fun.(state)` → `{:ok, _} |
  {:error, _}` (`docs/adr/0016-explicit-version-on-unborn-aggregate.md`): явная `%Version{}` на
  пустом потоке сверяется после решения — ошибка `fun` отдаётся как есть, принятое решение (в том
  числе без событий) — `:version_mismatch` с `actual: nil`; непустой поток мимо версии —
  `:version_mismatch` без вызова `fun`. Так существование агрегата решает домен и при `If-Match`:
  команда над незаведённым агрегатом получает свою доменную ошибку, а не отказ предусловия.
  `get` / `refresh` / `get_many` контракт не меняют. Команда с явной версией SHOULD идти через
  `get_decision` или процесс агрегата; свёртка `:version_mismatch` с `actual: nil` в незаведённый
  агрегат в коде потребителя — MUST NOT, запись в `fun` — MUST NOT (`13-repos.md`;
  `app/10-architecture.md` и `app/15-web-api.md` — `If-Match` над незаведённым агрегатом,
  `app/13-repos.md` — тело команды `get_decision` → `Agg.execute/2` → `append`).
  `get_many(pairs, context)` читает все потоки одним запросом и отдаёт одну `:version_mismatch`
  на все расхождения; `refresh(state, version, context)` дочитывает хвост после `state.version`;
  `page_stream(id, limit, offset, context)` — страница потока (пункт «Хранилище событий»).
  `append(events, context)` сам открывает транзакцию: `outbox.from_events` →
  `Core.Es.Store.append` с непрерывностью потока → `Outbox.Repo.append`; пачка потоков одного
  типа атомарна, `[]` — `:ok` без запросов. Behaviour — `use Core.Es.Aggregate.Repo, aggregate:,
  id:`, реализация — `use Core.Es.Aggregate.Repo.Pg, behaviour:, aggregate:, id:, errors:,
  outbox:` (+ `repo:`, `codec:`, `snapshot:`), резолв — по конвенции `<Behaviour>.Pg`; кодек
  событий берётся из агрегата. `CompileError`: нет `outbox:`, в `errors:` нет `:version_mismatch`, Prim агрегата
  кодека не равен `id:`, событие `outbox:` не из семейства кодека, `behaviour:` без колбэков
  `Core.Es.Aggregate.Repo`. Telemetry —
  `[:es, :aggregate, :load]` на вызов (у `get_decision` — `op: :get_decision`, `result` — сверка до
  решения) и `[:es, :aggregate, :fold]` на поток, span'а нет. Один репозиторий на агрегат в
  common-слое, без `default_filters`, `Repo.Sc` и `delete` (`13-repos.md`, «Write event-sourced
  агрегата»). Головы принимают только `%Agg.ID{}` / `%Agg{}`, результат сужен: `get` / `refresh` —
  `{:ok, %Agg{}}`, `get_decision` — `{:ok, _} | {:error, _}`, `get_many` — `{:ok, list}`,
  `append` — `:ok | {:error, _}`, `page_stream` — `{:ok, %Pagination.Result{}} | {:error, _}`;
  опечатка в поле прочитанного состояния и clause `{:ok, _}` по результату `append` —
  предупреждение при сборке.

  ```elixir
  # было — свёртка отказа предусловия хелпером приложения
  Transact.run(DAO, fn ->
    with {:ok, account} <- blank(@repo.get(id, version, context), id),
         {:ok, {events, _account}} <- Account.execute(account, command),
         do: @repo.append(events, context)
  end)

  # стало
  Transact.run(DAO, fn ->
    with {:ok, {events, _account}} <-
           @repo.get_decision(id, version, context, &Account.execute(&1, command)),
         do: @repo.append(events, context)
  end)
  ```

  Снапшоты — `snapshot: [every: N, version: V]`: длинный поток больше не сворачивается с начала
  на каждом чтении. `get` / `get_decision` / `get_many` / `refresh` читают снапшот из `es_snapshots` и хвост
  потока после него тем же одним запросом; свернули у потока не меньше `every` событий — один
  upsert на вызов после commit, вне транзакции — сразу; `append` снапшоты не пишет. Снапшот —
  кэш, а не источник истины: маркер (md5 модуля агрегата, кодека событий и модулей событий плюс
  `version:`) сбрасывает его при правке этого кода, битый снапшот даёт `warning` и полную
  свёртку, удаление строк корректность не меняет. `every:` обязателен; `version:` — по
  умолчанию 1 и поднимается с правкой кода вне этих модулей, от которого зависит `evolve`; без
  `snapshot:` снапшоты выключены. Telemetry снапшотов — `snapshot_hit` / `snapshot_miss` /
  `snapshot_rejected` в `[:es, :aggregate, :load]`, тег `snapshot` в `[:es, :aggregate, :fold]`
  и `[:es, :snapshot, :write]` (`13-repos.md`, «Снапшоты»).

  ```elixir
  use Core.Es.Aggregate.Repo.Pg,
    behaviour: MyApp.Domain.<BC>.Common.Account.Repo,
    aggregate: Account,
    id: Account.ID,
    errors: Account.Errors,
    outbox: Account.Outbox,
    snapshot: [every: 100]
  ```
- **Проекции: `Core.Es.Projection` и `Core.Es.Projection.Test`.** Read-модель строится из событий
  хранилища агрегатов обоих видов в порядке глобальной позиции, а чекпоинт (`es_checkpoints`)
  меняется в одной транзакции с ней: событие не обрабатывается дважды и не теряется
  (`docs/adr/0009-projections-read-event-store.md`). Объявление —
  `use Core.Es.Projection, name:, events:, version:` (+ `repo:`, `codec:` из `Core.Config`) с
  колбэками `project(event)` и `clear()` → `:ok | {:error, Error.t()}`. `events:` — модули
  событий; их кодек — `<Aggregate>.Event.Codec` по раскладке `docs/rules/app/13-repos.md`, тип
  агрегата — его `type:`. Тег, известный кодеку, но не объявленный, пачка пропускает без загрузки,
  неизвестный кодеку — ошибка без сдвига чекпоинта. `CompileError`: нет `project/1` или `clear/0`;
  `name:` не непустая строка; `version:` не целое ≥ 1; в `events:` семейство, не событие, событие
  без кодека `<Aggregate>.Event.Codec` с `type:` или вне его `tags:`.

  `Core.Es.Projection.run_once(projection, batch_size: 100)` — одна пачка в транзакции `DAO`:
  `pg_try_advisory_xact_lock` по имени (не взята — `:locked`); строки чекпоинта нет или её версия
  ниже `version:` — `clear/0` и чекпоинт в начале истории; версия строки выше — `:outdated`; иначе
  `project/1` на события после чекпоинта и CAS по прочитанной строке — `:processed`, событий нет —
  `:idle`. Ошибка или исключение колбэка откатывает пачку и
  отдаёт `{:error, Error.t()}`; исключение — прикладная `:projection_raised` с модулем исключения
  в detail, текст — в `warning`. Внутри `Transact.run` — `ArgumentError`. Тест прогоняет проекцию
  `Core.Es.Projection.Test.run_until_idle(projection | [projection])` на `Core.DataCase` с
  `async: false` после записи через репозиторий. Пачка с работой идёт в корневом span'е
  `"project <имя>"` — `Core.Otel.Es.project/3` поверх нового `Core.Otel.root_span/3`. Нормы — новый
  свод `docs/rules/22-projections.md` (skill `projections`); сводам приложений с таблицей «Файл
  библиотеки» в `00-index.md` — строка `22-projections.md`.

  Пересборка на месте — подъёмом `version:` (`docs/adr/0011-projection-rebuild-by-version.md`):
  строка чекпоинта хранит версию и цель пересборки. Пачка новой версии зовёт `clear/0`, ставит
  чекпоинт в начало с целью — последней позицией событий типов проекции, видимой пачке, — и пишет
  `info` `projection= from_version= to_version=`; пачка, дошедшая до цели, пишет `info` «цель
  пересборки достигнута» — у новой проекции это признак «догнала». Код с версией ниже строки
  получает `:outdated` и событий не читает, `run_until_idle` отдаёт `{:error, :outdated}`;
  понижения версии нет. Строку чекпоинта проекции, убранной из кода, удаляет миграция
  потребителя — `Core.Es.Migration.delete_checkpoint/1`; библиотека строк сама не удаляет. Когда
  поднимать `version:`, новая проекция в три выкладки и удаление — `22-projections.md`.

  ```elixir
  defmodule MyApp.Domain.<BC>.<Actor>.AccountList.Projection do
    alias MyApp.Domain.<BC>.Common.Account

    use Core.Es.Projection,
      name: "account_list",
      events: [Account.Event.Opened, Account.Event.Closed]

    @impl true
    def project(%Account.Event.Opened{} = event), do: insert_row(event)

    def project(%Account.Event.Closed{} = event), do: close_row(event)

    @impl true
    def clear do
      {_count, nil} = MyApp.DAO.delete_all(AccountList.Row)
      :ok
    end
  end

  # тест: запись через репозиторий → прогон → ReadRepo
  assert :ok = Core.Es.Projection.Test.run_until_idle(AccountList.Projection)

  # миграция, удаляющая таблицы проекции, убранной из кода
  def up do
    drop table(:account_list)
    Core.Es.Migration.delete_checkpoint("account_list")
  end
  ```

  Полноту `project/1` проверяет сборка проекции: `use Core.Es.Projection` генерирует на каждый
  модуль `events:` функцию-проверку (`Core.Es.Check`) с литеральным вызовом
  `project(%Event.Mod{payload: %Payload{}} = event)`. Модуль без clause и опечатка в поле
  нагрузки, не суженной паттерном `%Payload{}`, — предупреждение на строке `use`, и имя функции в
  нём называет нарушенное утверждение. Прежде пропущенную clause находил только тест
  `Core.Es.ProjectionCase` — при прогоне и у того, кто его подключил, — а в проде такое событие и
  опечатка откатывали пачку `:projection_raised`; тест удалён (пункт «`Core.Es.ProjectionCase`»).
  Макрос занимает в модуле проекции имена `@es_use_line` и функций-проверок
  `"project/1 принимает <Event>"/1`. Код потребителя не меняется: сборка с `--warnings-as-errors`
  падает там, где `project/1` был неполон всегда, — правится `project/1`.

  ```text
  # было — тест при прогоне
  1) test у project/1 есть клауза каждого модуля events: (MyApp.Domain.<BC>.<Actor>.AccountList.ProjectionCaseTest)
     {:error, %{unhandled: [{"test/support/fixtures/events/account/account.closed.json", Account.Event.Closed}]}}

  # стало — предупреждение при сборке
  warning: incompatible types given to project/1:
  └─ lib/my_app/domain/<bc>/<actor>/account_list/projection.ex:4: MyApp.Domain.<BC>.<Actor>.AccountList.Projection."project/1 принимает MyApp.Domain.<BC>.Common.Account.Event.Closed"/1
  ```
- **Дерево проекций: `Core.Es.Projection.Supervisor`.** Приложение ставит в своё дерево
  `{Core.Es.Projection.Supervisor, projections: [...], enabled: ...}` — и на каждой ноде читатели
  `Core.Es.Projection.Reader`, по одному на проекцию под именем её модуля, сами гоняют пачки
  проекций: их будит `Core.Es.Store.append/5` после commit через `Core.Es.Projection.Registry`
  (`keys: :duplicate`), а между событиями они опрашивают хранилище с backoff.
  Внутри — `rest_for_one`: Registry → `one_for_one` читателей → `one_for_one` слушателей канала
  сигнала чекпоинта `Core.Es.Projection.Listener`, по одному на каждый различный `repo:`
  проекций; падение слушателя читателей не трогает; второй супервизор на ноде не стартует. Опции
  общие на дерево: обязательны `projections:` и `enabled:`; `batch_size` 100, `idle_min_ms` 50,
  `poll_interval_ms` 1 000, `retry_min_ms` 1 000, `retry_max_ms` 30 000, `shutdown` 30 000,
  `await: :poll` — режим `Projection.await/3`, `await_min_ms` 10 и `await_max_ms` 100 —
  его шаг опроса, `notifications: true` — сигнал чекпоинта между нодами (пункт
  «Read-after-write»).
  Config и env библиотека не читает — README рекомендует env `ES_PROJECTIONS_*` в `runtime.exs`.
  Модуль без `use Core.Es.Projection`, дубль `name:` или недопустимая опция —
  `ArgumentError` при любом `enabled:`; `enabled: false` и `projections: []` — `:ignore` с `info`;
  любой старт ставит отметку в `:persistent_term` (список проекций и опции).

  Слушатель держит `Postgrex.Notifications` с `sync_connect: false` и `auto_reconnect: true`:
  подписка на канал — после `init/1`, недоступная база старт дерева не роняет, после разрыва
  соединение и подписка восстанавливаются сами. Соединение — `repo.config()`, поверх — keyword из
  `notifications:`: нода открывает по соединению на каждый различный `repo:` проекций, и их
  учитывают лимиты базы и пулера. `LISTEN` через pgbouncer в transaction mode уведомлений не
  получает — слушателю нужен прямой хост: `notifications: [hostname: "db-direct"]`. Приложению на
  одной ноде хватает сигнала внутри VM: `notifications: false` — ни слушателей, ни `NOTIFY` пачек
  ноды. `notifications:` — не `true`, `false` или keyword — `ArgumentError` при любом `enabled:`;
  нода с `enabled: false` соединений не открывает.

  Цикл читателя: `:processed` — следующая пачка сразу; `:idle` / `:locked` — от `idle_min_ms` с
  удвоением до `poll_interval_ms`, `wake` в ожидании — цикл сразу; отказ пачки, исключение, exit,
  throw или недоступная БД — повтор от `retry_min_ms` с удвоением до `retry_max_ms` без пропуска
  события и без рестарта процесса, `warning` на попытку с `projection= position= event_id=
  attempt=`; `:outdated` — через `poll_interval_ms`, `warning` один раз. На повторе и `:outdated`
  `wake` не ускоряет. Читатель под `trap_exit`: остановка ждёт конца пачки в пределах `shutdown`.
  Telemetry `[:es, :projection, :cycle]` на каждый цикл — `duration`, `events`, `attempt`; метки
  `projection`, `result`, при `:retry` — `error` (`ns/code`, модуль исключения, `exit`, `throw`).
  `watch_list/1` принимает опции дерева и отдаёт элементы `Core.Workers.PromEx` на читателей,
  `component: "es_projection:<name>"`; при `enabled: false` — пусто. У `Core.Helper.StartOpts`
  появились обязательные `list!/3` и `boolean!/3`. Нормы — `22-projections.md` («Дерево») и
  `17-otp-concurrency.md`: `watch_list` без элементов выключенного поддерева вместо `required:`,
  получатели `wake` в `Registry`, следующий тик — чистая функция.

  ```elixir
  defmodule MyApp.Projections do
    def opts do
      [projections: [AccountList.Projection]] ++ Application.fetch_env!(:my_app, __MODULE__)
    end
  end

  # MyApp.Application
  children = [MyApp.DAO, {Core.Es.Projection.Supervisor, MyApp.Projections.opts()}]

  # MyApp.PromEx.Workers
  def watch_list, do: Core.Es.Projection.Supervisor.watch_list(MyApp.Projections.opts())
  ```
- **Read-after-write: `Projection.await/3`.** После `:ok` usecase вызывающий ждёт, пока
  проекция обработает последнее событие потока агрегата, и читает read-модель уже с ним:
  `Projection.await(Agg, %Agg.ID{} = aggregate_id, timeout)` → `:ok | {:error, Error.t()}` у
  модуля проекции. `Agg` — модуль `<Aggregate>` любого вида с кодеком событий
  `<Aggregate>.Event.Codec` (по раскладке `docs/rules/app/13-repos.md` — сам агрегат): той же
  раскладкой проекция находит кодек модуля события. `await/3` генерирует `use Core.Es.Projection` — clause
  на каждый агрегат, чьи события есть в `events:`: голова — литерал агрегата и закрытый struct его
  ID, результат сужен до `:ok | {:error, %Core.Error{}}`. Агрегат не из `events:`, ID другого
  агрегата и невозможная clause по результату — предупреждение при сборке вызывающего; кодек,
  названный не `<Aggregate>.Event.Codec`, clause не получает. Прежняя форма
  `Core.Es.Projection.await(projection, aggregate, aggregate_id, timeout)` принимала модуль
  проекции и агрегат параметрами, хотя на месте вызова они всегда литералы, и сборка молчала: ID
  заказа при `Account` ждал поток `account` с чужим uuid, агрегат не из `events:` падал
  `FunctionClauseError` при исполнении. Она удалена: `await/3` сам зовёт реализацию ожидания
  `Core.Es.Projection.Await.run/5` (`@doc false`, звать её MUST NOT), и старый вызов даёт
  предупреждение `Core.Es.Projection.await/4 is undefined or private`. Макрос занимает в модуле
  проекции имя `await/3`. Цель — позиция последнего события потока на момент вызова: пустой поток
  или чекпоинт не ниже цели — `:ok`; строки чекпоинта нет, её версия ниже `version:` или чекпоинт
  ниже цели пересборки — сразу прикладная `:projection_rebuilding`, а не
  ожидание до таймаута; иначе ожидание до таймаута — прикладная `:projection_timeout`
  (`ns: :es`). Ответ приходит сразу после commit пачки на любой ноде: пачка с исходом
  `:processed`, включая старт пересборки, в своей транзакции шлёт `NOTIFY` в канал
  `core_es_checkpoint` с именем проекции, слушатель каждой ноды переводит уведомление в сигнал
  чекпоинта, а на своей ноде сигнал после commit шлёт и читатель; ожидающий, подписанный на сигнал
  до чтения цели, перечитывает чекпоинт тем же разбором исходов. Кластер Erlang не нужен, `append`
  в канал не шлёт. Имя канала и payload — протокол между нодами разных версий: их смена —
  ломающее изменение. При `notifications: false` пачки ноды `NOTIFY` не шлют — PostgreSQL берёт
  блокировку коммита и без слушателей, — и пачку такой ноды ожидающие других нод находят шагом.
  Уведомление, потерянное на разрыве соединения слушателя или в пулере, ожидание догоняет шагом:
  сломанный быстрый путь виден по `duration` `[:es, :projection, :await]` на уровне шагов, а не
  пачки (ADR-0013). Подписка — alias
  процесса: после ожидания при любом исходе она снимается, доставленные сигналы вычерпываются, и
  mailbox вызывающего — GenServer, LiveView — остаётся чистым. Страховка — опрос `es_checkpoints`
  шагами с удвоением от `await_min_ms` до `await_max_ms` дерева по расписанию от начала ожидания,
  сигналы шагов не сдвигают, а шаг позже таймаута не наступает; шаг — опция: короче шаг — быстрее
  ответ без сигнала, но чаще запросы к базе. Каждый шаг будит читателя проекции на своей ноде:
  пачка при `wake` после записи не видит событие, пока открыта более старая пишущая транзакция
  кластера, и без пробуждения читатель ждал бы до `poll_interval_ms`, а так подхватывает событие
  за шаг после её commit. Проекция в повторе чекпоинт не двигает, и ожидание идёт до таймаута.
  На время ожидания вызывающий связан с Registry дерева: остановка дерева посреди ожидания
  завершает вызывающего без `trap_exit`, а с `trap_exit` приносит `{:EXIT, _, _}`. `append`
  репозитория по-прежнему `:ok` и позицию не возвращает. Ошибки программиста: агрегат вне
  `events:` или ID другого агрегата — `FunctionClauseError`; вызов внутри транзакции —
  `ArgumentError`; дерево проекций не запущено — `RuntimeError`; проекция не из `projections:`
  дерева — `ArgumentError`.

  У `Core.Es.Projection.Supervisor` — опция `await: :poll | :inline`, по умолчанию `:poll`;
  `:inline` при `enabled: true` — `ArgumentError`. В тестовом дереве с `await: :inline` ожидание
  прогоняет проекцию до `:idle` в процессе теста с `batch_size` дерева и сверяет чекпоинт; любой
  другой исход — `RuntimeError` с исходом и именем проекции. Ожидание идёт в span'е
  `"await <имя>"` (`Core.Otel.Es.await/4`) внутри трейса вызывающего, `:projection_timeout` и
  `:projection_rebuilding` — `record_error/1`; telemetry `[:es, :projection, :await]` —
  `duration`; `projection`, `result: :ok | :timeout | :rebuilding`. Нормы — `22-projections.md`
  («Read-after-write»), `20-agreements.md` (`await` MUST NOT внутри `Transact.run`),
  `19-testing.md` (`await: :inline`), `21-observability.md` (span ожидания на call site); у
  потребителя — `app/15-web-api.md`: проекцию ждёт литеральный вызов в экшене или его `defp` с ID,
  суженным до `%Agg.ID{}` (ID из параметра без сужения сборка не сверяет), а хелпер, принимающий
  модуль проекции параметром, запрещён — через модуль-переменную сборка не проверяет ни агрегат,
  ни ID.

  ```elixir
  # config/test.exs
  config :my_app, MyApp.Projections, enabled: false, await: :inline

  # запись → ожидание проекции → чтение read-модели
  with :ok <- Accounts.Open.call(id, params, context),
       :ok <- AccountList.Projection.await(Account, id, 5_000) do
    AccountList.ReadRepo.get(id, :current, context)
  end

  # было — собиралось, ждало поток `account` с uuid заказа;
  # теперь — warning: Core.Es.Projection.await/4 is undefined or private
  Core.Es.Projection.await(AccountList.Projection, Account, order_id, 5_000)

  # стало — warning: incompatible types given to MyApp.Domain.<BC>.<Actor>.AccountList.Projection.await/3
  AccountList.Projection.await(Account, order_id, 5_000)
  ```
- **`Core.Es.ProjectionCase` — очистку `clear/0` проверяет библиотека.** Тест-модуль
  `use Core.Es.ProjectionCase, projection:, async: false` генерирует тест на golden-фикстурах
  событий — `<тип агрегата>/<текущий тег>.json` от корня `fixtures:` (по умолчанию
  `test/support/fixtures/events`), тип и тег берутся из кодека каждого модуля `events:`. Тест
  прогоняет `project/1` на всех фикстурах, находит записанные таблицы по статистике
  `pg_stat_xact_user_tables`, зовёт `clear/0` и требует пустоты каждой; ни одной таблицы — провал.
  Перечня таблиц нет ни у case, ни у `use Core.Es.Projection`: новая таблица проекции попадает под
  проверку сама. Нет фикстуры, в ней не текущий тег или она не грузится — провал теста с путями.
  Полноту `project/1` case не проверяет: первый тест — вызов на фикстуре каждого модуля с
  провалом только по `FunctionClauseError` самой `project/1` — удалён, её проверяет сборка
  проекции (пункт «Проекции»). Проверки идут в транзакции с откатом на своём sandbox checkout,
  case — `async: false`: `async: true` — `CompileError`, явный `async: false` требует
  `Credo.Check.Refactor.PassAsyncInTestCases`. Норма — `19-testing.md`, «Проекции».

  ```elixir
  # test/my_app/domain/<bc>/<actor>/account_list/projection_case_test.exs
  defmodule MyApp.Domain.<BC>.<Actor>.AccountList.ProjectionCaseTest do
    use Core.Es.ProjectionCase,
      projection: MyApp.Domain.<BC>.<Actor>.AccountList.Projection,
      async: false
  end
  ```
- **Процесс агрегата: `Core.Es.Aggregate.Process`.** Команда одного event-sourced агрегата — вызов
  `Agg.Process.execute(id, version, command, context, fun, opts)` → `:ok | {:error, Error.t()}`
  вместо тела usecase `get_decision` → `Agg.execute/2` → `append`: команды одного агрегата встают в очередь, а
  не конфликтуют, и поток не перечитывается целиком на каждую команду. Модуль
  `use Core.Es.Aggregate.Process, repo: Agg.Repo` генерирует `execute/6`, `child_spec/1` и
  `watch_list/1`; реализация `repo:` — `<Behaviour>.Pg`, как у `Core.Config.repo!/1`. Состояние →
  `Agg.execute/2` → `append` → `fun.(events)` идут одной транзакцией `Core.Config.dao/0`: колбэк —
  сопутствующие записи (Oban, `DAO`) под ограничениями `Transact.run`, его `{:error, _}` откатывает
  и события, а возврат вне `:ok | {:error, _}` — `CaseClauseError` до commit.
  `:version_mismatch` из `append` при `:current` — повтор новой транзакцией до `retries:` с `debug`
  на повтор, исчерпание — `warning` `type= aggregate_id= retries=` и ошибка вызывающему;
  `%Version{}` мимо головы непустого потока — `:version_mismatch` без повтора; на пустом потоке
  решение идёт через `get_decision` репозитория — ошибка `decide`, если он команду отклоняет, и
  `:version_mismatch` с `actual: nil`, если принимает, в том числе без событий, тоже без повтора.
  Опции старта: `enabled:` обязательна, `retries:` 3, `idle_timeout:` 60 000 мс.
  - `enabled: true` — `Supervisor` под именем модуля процесса из `Registry` и `DynamicSupervisor`
    (имена `<Agg.Process>.Registry` и `<Agg.Process>.Supervisor`), `info` и отметка в
    `:persistent_term`. Команды агрегата идут по одной в его процесс на id (`restart: :temporary`,
    единственность — на ноду): он стартует в первой команде без запросов, решает через
    `get_decision`, дальше дочитывает хвост `refresh` от закэшированного заведённого агрегата и
    уходит по `idle_timeout:` без записи снапшота. Корректность по-прежнему держат проверки `append`: второй процесс того же
    агрегата и запись в обход процесса штатны.
  - Колбэк исполняется в процессе на id; на время команды туда ставятся OTel-контекст и
    `Logger.metadata()` вызывающего, а `:shadow_copy` в `context` заменяется таблицей `Repo.Sc`
    процесса — приватная таблица вызывающего ему недоступна, поэтому `context`, пойманный колбэком
    из замыкания, с `Repo.Sc` не работает.
  - `timeout:` (5 000 мс) — дедлайн: команда, простоявшая в очереди до него, отбрасывается до
    транзакции, дедлайн, истёкший до commit, откатывает транзакцию, а попытка после дедлайна не
    идёт — повтор после отказа записи обрывается, не читая и не записывая. Истечение и падение
    процесса, в том числе `raise` в `decide` / `evolve` / колбэке, — exit вызывающему; `:noproc` —
    старт и один повтор вызова.
  - `enabled: false` — `:ignore`, `info` и отметка, команда исполняется в вызывающем процессе.

  Вызов внутри транзакции — `ArgumentError`, нет отметки старта — `RuntimeError`. Span
  `"execute <тип>"` (`Core.Otel.Es.execute/4`) — в трейсе вызывающего и охватывает ожидание в
  очереди, выход из неё — span event `dequeued` (новая `Core.Otel.add_event/2`); атрибуты
  `core.es.aggregate.type` / `.id`, `core.es.command`, `core.es.execute.mode`, `core.es.retries`,
  прикладная ошибка — `record_error/1`. Telemetry `[:es, :aggregate, :process, :execute]` —
  `duration`, `queue`, `retries`; `type`, `mode: :process | :inline`,
  `result: :ok | :version_mismatch | :error | :exit`; на процесс на id —
  `[:es, :aggregate, :process, :start]` и `:stop` с `reason: :idle | :error`. `watch_list(opts)` —
  верхний супервизор, `component: "es_aggregate_process:<тип>"`; при `enabled: false` — `[]`. Нормы
  — `13-repos.md` («Процесс агрегата»: MAY для команды одного агрегата, несколько агрегатов — MUST
  usecase → repo), `20-agreements.md` (`execute` MUST NOT внутри `Transact.run`, повтор на
  `debug`), `21-observability.md` (span команды у вызывающего), `19-testing.md` (`enabled: false`
  в тестах потребителя, shared mode sandbox у процессов, стартующих внутри вызова).

  Результат `execute/4..6` сужен до `:ok | {:error, _}`: clause `{:ok, state}` по нему —
  предупреждение при сборке. Команду другого агрегата сборка не ловит — процесс не видит
  `decide/2` агрегата.

  ```elixir
  defmodule MyApp.Domain.<BC>.Common.Account.Process do
    use Core.Es.Aggregate.Process,
      repo: MyApp.Domain.<BC>.Common.Account.Repo
  end

  # MyApp.Application; config/test.exs — enabled: false
  children = [MyApp.DAO, {Account.Process, Application.fetch_env!(:my_app, Account.Process)}]

  # MyApp.PromEx.Workers — те же опции, что у элемента дерева
  def watch_list, do: Account.Process.watch_list(Application.fetch_env!(:my_app, Account.Process))

  # было — usecase: Transact.run с get → Account.execute/2 → append
  # стало
  Account.Process.execute(id, :current, command, context, &Notifications.enqueue(&1, context))
  ```
- **Метрики event sourcing: `Core.Es.PromEx`.** Один PromEx-плагин на всю область: восстановление
  агрегата, снапшоты, проекции и процессы агрегата читают общие таблицы одного `Core.Config.dao/0`,
  и дежурный видит их на одном дашборде. Event-метрики строятся всегда — по telemetry
  `[:es, …]`: восстановление агрегата (`es_aggregate_load_total{type,op,result}`, длительность и
  распределение длины свёрнутого хвоста `es_aggregate_fold_events{type,snapshot}` — для выбора
  `every:`), запись снапшота (`es_snapshot_write_*`), цикл проекции
  (`es_projection_cycles_total{projection,result}`, `es_projection_duration_*`,
  `es_projection_events_total`, `es_projection_retry_total{projection,error}`), ожидание проекции
  (`es_projection_await_*`) и процесс агрегата (`es_aggregate_process_execute_*` с очередью и
  повторами, `start` / `stop`). Polling-группы — по MFA и под `Core.PromEx.Safe`:
  - `projections:` — провайдер опций дерева `Core.Es.Projection.Supervisor`, тот же, что у
    элемента дерева: отставание `es_projection_lag_seconds` — возраст первого необработанного
    события типов проекции (`LIMIT 1` на тип; строки чекпоинта нет или её версия ниже
    `version:` — от начала истории), `es_projection_rebuilding`, `es_projection_outdated` (версия
    строки выше `version:` на этой ноде) и `es_checkpoint_orphan{name}` (строка без проекции в
    списке ноды);
  - `processes:` — провайдер списка модулей `use Core.Es.Aggregate.Process`:
    `es_aggregate_processes{type}`.

  Рекомендованные алерты `EsProjectionRetrying`, `EsProjectionLagging`, `EsProjectionRebuildLong` и
  `EsProjectionOutdated` с PromQL — `22-projections.md`, «Эксплуатация»; пороги выбирает приложение.

  ```elixir
  # MyApp.PromEx
  def plugins do
    [
      {Core.Es.PromEx,
       poll_rate: 5_000,
       projections: {MyApp.Projections, :opts, []},
       processes: {MyApp.PromEx.Es, :processes, []}}
    ]
  end

  # MyApp.PromEx.Es
  def processes, do: [MyApp.Domain.<BC>.Common.Account.Process]
  ```
- **Резерв изменяемого уникального ключа event-sourced агрегата: `Core.Es.KeyReservation` и
  таблица `es_key_reservations`.** Неизменяемый ключ задаёт id потока (`Core.Prim.UUID, version:
  5`), а изменяемый (логин, название роли) библиотека не покрывала: уникального индекса по
  состоянию у event-sourced агрегата нет, и приложение держало свою таблицу, behaviour и вызов
  синхронизации в каждом usecase до `append` — забытый на новом пути записи вызов молча пропускал
  дубль, а процесс агрегата такой агрегат не писал вовсе. Теперь модуль ключа `use
  Core.Es.KeyReservation, scope:, event:, id:, code:` отображает события агрегата на резерв —
  `reservation/1` → `{:reserve, value} | :release | :keep` — и задаёт каноническую форму ключа
  `to_key/1` → строка или список частей (строка равна списку из одной части); генерируется
  `find(value, context)` → `%Agg.ID{} | nil`. Резервы ставит, переносит и снимает `append`
  репозитория с `key_reservations:` («Изменения контракта макросов») — на любом пути записи, в
  том числе `Agg.Process.execute`. У агрегата в области один ключ; ключ другого агрегата — отказ
  `errors.domain(behaviour, code, %{scope: scope})` без значения ключа в `detail`. DDL — отдельный
  модуль `Core.Es.KeyReservation.Migration`: потребитель заводит делегирующую миграцию, как для
  `Core.Es.Migration`. Мотивация, отвергнутые варианты и цена —
  `docs/adr/0018-mutable-key-reservation.md`; нормы — `13-repos.md`, «Резервы ключей», и
  `app/13-repos.md`, «Уникальность без индекса состояния»; в ярусе потребителя также код отказа в
  каталоге агрегата (`app/12-errors.md`) и таблица в «Таблицах библиотеки» (`app/18-migrations.md`).
  Владелец резерва — `aggregate_id` без типа агрегата: агрегаты разных видов с общим
  идентификатором из ключа в одной области делят один резерв. Каждый модуль ключа MUST иметь свой
  тест (`19-testing.md`, «Резерв ключа»): сборка видит наличие clause `reservation/1`, но не её
  исход, а каноническую форму `to_key/1` не видит вовсе, и usecase-тест её не ловит — обе стороны
  сравнения идут через тот же `to_key/1`. Требование уникального значения ключа в `async: true`
  распространено на общую обвязку (`MyAppWeb.ConnCase`, фикстуры): литерал в ней делит одну строку
  резерва на все async-модули и сериализует их.

  ```elixir
  # было — своя таблица unique_keys и синхронизация в каждом usecase между get и append
  with {:ok, user} <- @repo.get(id, version, context),
       {:ok, {events, changed}} <- User.execute(user, command),
       :ok <- User.LoginKey.sync(events, changed, context),
       do: @repo.append(events, context)

  # стало — модуль ключа и опция репозитория, usecase резерв не зовёт
  defmodule MyApp.Domain.<BC>.Common.User.LoginKey do
    use Core.Es.KeyReservation,
      scope: "user.login",
      event: User.Event,
      id: User.ID,
      code: :login_taken

    @impl true
    def reservation(%Event.Created{payload: payload}), do: {:reserve, payload.login}
    def reservation(%Event.LoginChanged{payload: payload}), do: {:reserve, payload.login}
    def reservation(%Event.Blocked{}), do: :keep
    def reservation(%Event.Deleted{}), do: :release

    @impl true
    def to_key(%User.Login{} = login), do: User.Login.value(login)
  end

  use Core.Es.Aggregate.Repo.Pg,
    # ...
    outbox: User.Outbox,
    key_reservations: [User.LoginKey]

  # миграция приложения: таблица библиотеки и перенос прежних резервов до первой записи нового кода;
  # у агрегата в области один ключ — лишние строки unique_keys агрегата убираются до переноса
  def up do
    Core.Es.KeyReservation.Migration.up()

    execute """
    INSERT INTO es_key_reservations (scope, key, aggregate_id)
    SELECT scope, ARRAY[key], aggregate_id FROM unique_keys
    """

    drop table(:unique_keys)
  end
  ```

### Изменения контракта макросов

- **`use Core.Es.Event` занимает в модуле события имя `draft/1` (с нагрузкой) или `draft/0` (без
  неё), `use Core.Es.Event.Codec` в кодеке агрегата — имена функций-проверок нагрузки.** `draft` —
  конструктор черновика события (пункт «Event-sourced агрегат» в разделе «Новое»). Своя функция с
  этим именем и арностью в модуле события сталкивается с генерируемой: её нужно переименовать.
  В кодеке занятыми стали `@es_use_line` и имена
  `"dump_payload/2 принимает <Event>"/2` и `"load_payload/3 отдаёт нагрузку <Payload>"/3` (пункт
  «`Core.Es.Event.Codec`: колбэки вместо приватных клоуз» в разделе «Ломающие изменения контракта»).
- **Bang-конструкторы Prim и `Core.Version.new/0` возвращают известный компилятору struct.**
  `new!/1` у `use Core.Prim.*`, `new/0` у `Prim.UUID`, `now!/0` у `Prim.DateTime` и
  `Core.Version.new/0` выводились как `dynamic()`: `Core.Result.unwrap!/1` прятал тип, и ID из
  `Role.ID.new()` молча проходил в функцию с `%User.ID{}` в голове, а опечатка в поле результата
  падала `KeyError` при исполнении. Теперь они делают `raise Core.Exc` сами — исход при исполнении
  прежний, а сборка с `--warnings-as-errors` падает там, где ошибка была всегда. Правится вызов, а
  не предупреждение.

  ```elixir
  def get(%User.ID{} = id, %Context{} = context), do: @repo.get(id, context)

  # было — собиралось и падало FunctionClauseError при исполнении;
  # стало — warning: incompatible types given to get/2
  get(Role.ID.new(), context)
  ```
- **Реализация репозитория выводится из имени behaviour.** `Core.Config.repo!/1` резолвит
  `<Behaviour>` → `<Behaviour>.Pg`, если в app-env потребителя не задано другое; тот же
  дефолт у `Core.Config.outbox_repo/0`. Из `config/config.exs` уходит по строке на каждый
  репозиторий, включая обязательную прежде
  `config :core, Core.Outbox.Repo, Core.Outbox.Repo.Pg` — старые ключи продолжают работать
  и нужны только при подмене реализации. Call site переводится на
  `@repo Config.repo!(Behaviour)`: прямой `Application.compile_env!/2` на доменный
  behaviour стал нарушением свода (`13-repos.md`, «DI»). Модуль-реализация проверяется на
  компиляции — отсутствие даёт `CompileError`, а не `UndefinedFunctionError` на первом
  вызове, ценой ребра call site → реализация в графе компиляции. `otp_app` теперь читает
  любой call site, поэтому он обязан лежать в `config.exs`, а не в `runtime.exs`.
  Мотивация, отвергнутые варианты и цена — `docs/adr/0006-repo-impl-resolved-by-convention.md`.
- **`Repo.Pg.StateStored` больше не читает конфигурацию на компиляции.** Реализация outbox
  резолвится вызовом `Core.Config.outbox_repo/0` в момент flush; атрибут `@es_outbox_repo` снят.
  Доступ к app-env потребителя целиком
  сжат в `Core.Config`, и главный инвариант из `10-architecture.md` проверяется линтером
  `make boundary-check` (`scripts/boundary_lint.exs`), а не грепом на ревью. Тот же скрипт
  проверяет и сторону потребителя — `boundary_lint.exs --consumer lib test` ловит прямой
  `compile_env` на модуль-behaviour; потребитель зовёт его из `deps/core/scripts/`.
- **`codec:` и `repo:` без явной опции резолвятся в рантайме.** `Es.Outbox`, `Repo.Pg` и
  `Repo.Pg.StateStored` больше не читают
  `Core.Config` в момент разворачивания макроса — как это уже делал `Repo.Pg.Schema`.
  Потребитель, задающий `dao:` / `codec:` в `runtime.exs`, компилируется без обходных
  путей; поведение при явно заданной опции не изменилось.
- **Снятые атрибуты макросов.** `Es.Outbox` больше не занимает `@es_codec`: вместо него
  генерируется приватная `es_codec/0`. Правка нужна только тому, кто ссылался на этот атрибут
  из собственного кода модуля.
- **`Core.Guard.is_enum/2` / `in_enum/3` регистрируют исходник enum-модуля как
  `@external_resource` каллера.** Значения инлайнятся в guard литералом, а компилятор этой связи
  не видит: `Code.ensure_compiled/1` даёт максимум export-ребро, и правка `values:` не пересобрала
  бы модуль с guard — тот остался бы на старом множестве. Следствие для потребителя: enum,
  используемый в guard, MUST компилироваться на той же машине, что и каллер (сборка
  с `+deterministic` теряет `:source`, и инкрементальная пересборка каллера не гарантирована).
- **`Core.Es.Event.Codec`: обязательная опция `type:` — тип агрегата.** Wire-имя агрегата и первая
  часть адреса потока событий — подготовка к общей таблице событий, где тип станет колонкой.
  Формат — как у тега (непустая строка); кодек без `type:` — `CompileError`. Конверт события не
  меняется, с префиксом тегов `type:` не сверяется — записанные теги неизменяемы.
  `use Core.Codec.Facade` отказывает в компиляции, если у двух кодеков событий среди `plugins:`
  один `type:`, и называет оба кодека.

  ```elixir
  # было
  use Es.Event.Codec,
    event: User.Event,
    tags: @tag_by_mod

  # стало
  use Es.Event.Codec,
    event: User.Event,
    type: "user",
    tags: @tag_by_mod
  ```
- **`Core.Repo.Pg.Es` → `Core.Repo.Pg.StateStored`; `event_repo:` → обязательная `event_codec:`.**
  Имя `Repo.Pg.Es` читалось как репозиторий event-sourced агрегата, а builder пишет строку
  state-stored агрегата и его события в общую таблицу (пункт про `es_events` в «Ломающих
  изменениях контракта»). `event_codec:` — кодек событий агрегата: его `type:` задаёт поток; DI
  репозитория событий через `Core.Config.repo!/1` ушёл вместе с `event_repo:`. `id:` стала
  обязательной. Сверки на компиляции — `CompileError`: `event_codec:` не кодек событий с `type:`;
  Prim агрегата кодека (новая интроспекция `__es_aggregate_id__/0`) не равен `id:`; событие
  `outbox:` (новая интроспекция `Core.Es.Outbox.__es_event__/0`) не равно семейству кодека; в
  `errors:` нет clause `:version_mismatch`. Макрос занимает `@es_event_codec` вместо
  `@es_event_repo` и имя `page_stream/4` — страница потока агрегата (пункт про `es_events`).

  ```elixir
  # было
  use Repo.Pg.Es,
    # ...
    id: Role.ID,
    event_repo: Role.Event.Repo,
    outbox: Role.Outbox

  # стало
  use Repo.Pg.StateStored,
    # ...
    id: Role.ID,
    event_codec: Role.Event.Codec,
    outbox: Role.Outbox
  ```
- **`Core.Prim.UUID`: `version: 5` — идентификатор из ключа, опции `namespace:` и `scope:`.**
  Id потока из неизменяемого ключа (`app/13-repos.md`, «Уникальность без индекса состояния»)
  приложению приходилось считать самому: свой модуль с транзитивной `:uuid` и Prim с `version: 7,
  check_version: false` — проверка версии на разборе снята, а `new/0` генерировал v7, которой у
  настоящих id не бывает. Теперь `version: 5` требует `namespace:` (UUID-строка) и `scope:` (область
  ключа, непустая строка); при других версиях обе опции — `CompileError`. Id — вложенный UUIDv5:
  `uuid5(namespace, scope)`, затем `uuid5(acc, part)` на каждую часть ключа; строка — ключ из одной
  части. Приложение, считавшее id по этой схеме, при переводе id потоков не меняет. `new/0` у такого
  Prim не генерируется: вместо него приватный `from_key/1` (строка или непустой список строк),
  который зовёт публичный `from_<key>` модуля. Prim без `from_<key>` не собирается с
  `--warnings-as-errors` (`from_key/1` не используется), своя функция `from_key/1` в модуле
  сталкивается с генерируемой. `check_version: false` при `version: 5` допустим — агрегат,
  переходящий на идентификатор из ключа, разбирает прежние случайные id. Мотивация, отвергнутые
  варианты и цена — `docs/adr/0017-stream-id-from-key.md`.

  ```elixir
  # было — свой модуль схемы, проверка версии снята, пробы в тестах через new/0
  defmodule MyApp.StreamID do
    @namespace "1b0f8f5e-8a54-4a7c-9a2b-3f6d2c8e5a11"

    def uuid(scope, parts), do: Enum.reduce(parts, UUID.uuid5(@namespace, scope), &UUID.uuid5(&2, &1))
  end

  use Core.Prim.UUID,
    name: first_line(@moduledoc),
    version: 7,
    check_version: false

  def from_number(number), do: new!(MyApp.StreamID.uuid("delivery", [number]))

  id = Delivery.ID.new()

  # стало — namespace из функции приложения, пробы — from_<key> от уникального ключа
  defmodule MyApp.StreamID do
    def namespace, do: "1b0f8f5e-8a54-4a7c-9a2b-3f6d2c8e5a11"
  end

  use Core.Prim.UUID,
    name: first_line(@moduledoc),
    version: 5,
    namespace: MyApp.StreamID.namespace(),
    scope: "delivery"

  def from_number(number), do: from_key(number)

  id = Delivery.ID.from_number("DLV-#{System.unique_integer([:positive])}")
  ```
- **`use Core.Es.Aggregate.Repo.Pg`: опция `key_reservations:` — модули ключа агрегата.**
  Резерв изменяемого ключа (пункт «Резерв изменяемого уникального ключа» в разделе «Новое»)
  встроен в `append`, а не в usecase: запись идёт события → резервы → outbox одной транзакцией, и
  конкурентная команда того же потока получает `:version_mismatch`, до резервов не доходя. Сборка
  сверяет модули ключа с репозиторием — `CompileError`: не список модулей ключа, событие модуля
  ключа не равно семейству кодека, его `id:` не равен `id:` репозитория, в `errors:` нет clause его
  `code:`, область повторяется. Полноту `reservation/1` проверяет вывод типов: на каждое событие
  кодека макрос генерирует функцию-проверку `"reservation/1 принимает <Event>"/1` — нет clause
  или опечатка в поле несуженной нагрузки дают предупреждение на строке `use`. `code:
  :version_mismatch` у модуля ключа — `CompileError`: процесс агрегата повторял бы отказ как
  конфликт записи. Без опции
  репозиторий прежний; с ней репозиторий зависит от таблицы `es_key_reservations` — без миграции
  `Core.Es.KeyReservation.Migration` запись падает. Каталог `errors:` получает clause `code:`
  каждого модуля ключа:

  ```elixir
  # было
  use Core.Es.Aggregate.Repo.Pg,
    # ...
    outbox: User.Outbox

  # стало
  use Core.Es.Aggregate.Repo.Pg,
    # ...
    outbox: User.Outbox,
    key_reservations: [User.LoginKey]

  # User.Errors
  def domain(module, :login_taken = code, detail, message),
    do: Error.domain(module, code: code, ns: ns(), message: message || "Логин занят", detail: detail)
  ```

## 0.1.0

Первый выпуск: библиотека выделена из приложения, внутри которого жила как
namespace `<App>.Core.*`.

### Изменения контракта относительно встроенной версии

- **Namespace.** `<App>.Core.*` → `Core.*`.
- **Конфигурация переехала под `:core`.** Было `config :my_app, MyApp.Core, dao:, codec:, tz:`
  — стало `config :core, dao:, codec:, tz:`. То же для `Core.Outbox`, `Core.Outbox.Repo`,
  `Core.Security.Secret`.
- **`otp_app` больше не выводится из `Mix.Project`,** а задаётся явно:
  `config :core, otp_app: :my_app`. Он нужен только для резолва DI-ключей доменных
  репозиториев в `use Core.Repo.Pg.Es` — это единственное обращение библиотеки
  к конфигурации не под `:core`.
- **Префикс telemetry-событий вынесен в `telemetry_prefix`** (дефолт `[otp_app()]`)
  и резолвится в рантайме, а не на этапе компиляции. Чтобы сохранить имена метрик
  при переезде, задайте его явно.
- **`codec:` у `Core.Repo.Pg.Schema` резолвится лениво.** Без явной опции фасад берётся
  из `Core.Config.codec()` в рантайме: библиотека компилируется раньше конфигурации
  приложения, поэтому требовать конфиг на этапе компиляции нельзя.
- **`Core.Config.validate!/0`** — новая проверка конфигурации для вызова из `start/2`.
- **Клиенты брокеров стали опциональными зависимостями.** `rabbitmq_stream` и `klife`
  объявлены `optional: true`; `Core.Mq.Stream.{Connection,Reader}` и `Core.Mq.Kafka.Writer`
  компилируются только у тех потребителей, кто объявил соответствующий клиент. Приложению
  с одним брокером больше не нужно тянуть второй (в случае `klife` — вместе с NIF-пакетами
  `crc32cer` / `snappyer`). `Core.Mq.Stream.ensure_available!/0` и
  `Core.Mq.Kafka.ensure_available!/0` — проверки на старте для тех, кто адаптер использует:
  отличают «клиента нет в deps» от «клиент есть, но `core` собран без него»
  (`mix deps.compile core --force`).
- **Boundary-декларация удалена.** Инвариант «Core не знает про домен, приложение
  и web» теперь обеспечен границей OTP-приложений, а не аннотацией.

Инструкция по переводу приложения — в `README.md`.
