# Архитектуры крупного Elixir-приложения: сравнение по первоисточникам

Дата исследования: 2026-10-02.

## Вопрос

Какие архитектуры существуют для крупного Elixir-приложения и как они сравниваются по фиксированным критериям.
Профиль приложения: один бэкенд-сервис, ~800 модулей, Postgres, event sourcing с проекциями и outbox, брокеры
Kafka/RabbitMQ, HTTP JSON API, фоновые воркеры. Приложение стоит на внутренней библиотеке, которая уже даёт
ES-агрегаты (decide/evolve), хранилище событий, проекции, outbox, репозитории и кодеки. Поэтому Commanded и Ash
рассматриваются как источники архитектурных форм, а не как замена.

Цель — материал для выбора или сборки архитектуры. Рекомендаций для конкретного приложения здесь нет: только
сравнение и совместимость элементов.

## Методика

- Только первоисточники: официальная документация, исходный код, тексты и доклады авторов подхода.
- Документацию читали из исходников (Markdown, moduledoc на GitHub), чтобы цитировать дословно. Ссылки ведут на
  hexdocs (новый домен `<пакет>.hexdocs.pm`) или на GitHub.
- Зафиксированные коммиты:
  - Phoenix `main` @ `32e9c83b`, Elixir `main` @ `41da5601`;
  - hexpm @ `503f9d6`, plausible/analytics @ `d21298d`, supabase/realtime @ `3bb2567`, livebook @ `81db338`.
- Ссылки на `main`/`master` ведут на текущую версию. Цитаты Phoenix, Elixir и живых приложений сверены на
  коммитах выше; Commanded, Ash, Boundary — на ветке по умолчанию на дату исследования.
- Книги полностью не читались. Использованы страницы издателей (аннотации, оглавления) и бесплатные фрагменты
  глав. О содержании глав за пределами фрагментов утверждений нет: указывается только название главы.
- Видео докладов не транскрибировались. Для «Clarity» (Jurić) взяты слайды, для Halvorsen — аннотация и
  фрагменты книги.
- Что было недоступно:
  - Страницы medium.com отдают автоматическому клиенту 403. Серия Jurić прочитана из RSS-ленты того же
    издания (https://medium.com/feed/very-big-things). Примеры кода там — картинки, прочитаны частично.
  - Статья Dashbit «Speeding up re-compilation of Elixir projects» на дату исследования отдаёт 404. Использован
    снимок web.archive.org.
  - Глава FAQ книги «Building Conduit» («How do I structure my CQRS/ES application?») в онлайн-ридере отдаёт 404.
  - Сообщение José Valim в Google Groups (2017) прочитано через загрузчик страниц. Дословно сохранён только
    перечень трёх свойств umbrella.
- Пометка «вывод» означает вывод автора исследования, а не утверждение источника. «Источник молчит» значит,
  что первоисточник вопрос не рассматривает.

Критерии:

| Код | Критерий |
|---|---|
| К1 | единица модульности и как её найти по дереву каталогов |
| К2 | направление зависимостей; что у единицы публично, что внутреннее |
| К3 | взаимодействие единиц (прямой вызов, события, behaviour/порт, сообщения) |
| К4 | где живут процессы и дерево супервизии |
| К5 | место web-слоя и входящих адаптеров (HTTP, подписчики брокера, воркеры) |
| К6 | место write-модели, read-модели/проекций, побочных эффектов (outbox, публикация) |
| К7 | механическое принуждение границ и его цена |
| К8 | влияние на compile-time зависимости и перекомпиляцию |
| К9 | тестируемость и раскладка тестов |
| К10 | стоимость и известные провалы на ~800 модулях (по словам авторов и сообщества) |

---

## 1. Phoenix contexts

Первоисточники:

- [PX1] https://phoenix.hexdocs.pm/contexts.html
- [PX2] https://phoenix.hexdocs.pm/your_first_context.html
- [PX3] https://phoenix.hexdocs.pm/in_context_relationships.html
- [PX4] https://phoenix.hexdocs.pm/cross_context_boundaries.html
- [PX5] https://phoenix.hexdocs.pm/more_examples.html
- [PX6] https://phoenix.hexdocs.pm/faq.html (FAQ раздела Data modelling)
- [PX7] https://phoenix.hexdocs.pm/directory_structure.html
- [PX8] https://phoenix.hexdocs.pm/testing_contexts.html
- [PX9] гайд Phoenix 1.7: https://github.com/phoenixframework/phoenix/blob/v1.7.14/guides/contexts.md
- [PX10] шаблон генератора:
  https://github.com/phoenixframework/phoenix/blob/main/priv/templates/phx.gen.context/schema_access_scope.ex.eex

Суть:

- Контекст — обычный модуль: «we encapsulate data access and data validation. We call these modules
  **contexts**», «at the end of the day, contexts are just modules» [PX1].
- «The context is your public API, the other modules are private» [PX6]. Внутренности контекста не
  регламентируются: «it is completely fine for them to be different» [PX6].
- В `lib/hello` лежит «all of your business logic and business domain» («the "Model" in Model-View-Controller»).
  `lib/hello_web` отвечает за «exposing your business domain to the world» [PX7].
- Контексты зовут друг друга напрямую: «showing how contexts can naturally invoke other contexts if required»
  [PX4]. Данные связываются через `belongs_to` на схему чужого контекста: «we intentionally coupled the data
  boundaries» [PX4].
- Правило выбора границ: «if you are unsure, you should prefer separate modules (contexts)» [PX3].
- Формулировки ослабли. В 1.7: «think of them as boundaries to decouple and isolate parts of your application»
  [PX9]. Сейчас: «contexts are just modules» [PX1].

По критериям:

- **К1.** Единица — модуль `lib/<app>/<context>.ex` плюс одноимённый каталог со схемами (`lib/hello/catalog.ex`,
  `lib/hello/catalog/product.ex`) [PX2]. По дереву она видна как пара «файл и одноимённый каталог» под
  `lib/<app>/`.
- **К2.** Зависимости: web → контекст → Repo и схемы. Вызовы между контекстами направлением не ограничены.
  Публичность держится на соглашении: `changeset/2` помечен `@doc false`, «while this function is publicly
  callable, it's not part of the public context API» [PX2].
- **К3.** Связь — прямой вызов или join в БД [PX4]. Транзакция через два контекста живёт внутри функции одного
  из них: `Orders.complete_order` в `Repo.transact/2` вызывает `ShoppingCart.prune_cart_items/2` [PX5].
  Сгенерированный scoped-контекст публикует `{:created | :updated | :deleted, struct}` через `Phoenix.PubSub` и
  даёт `subscribe_<plural>/1` [PX10]. Назначение broadcast — «so that any connected LiveViews can instantly
  show the changes» [PX4], то есть уведомление UI, а не интеграция контекстов.
- **К4.** Одно дерево в `lib/hello/application.ex`, которое «defines which services are part of our application»
  [PX7]. Где держать процессы конкретного контекста, гайды не говорят.
- **К5.** Контроллер — «the web interface into our greater application». Контекст переиспользуется «from any
  other interface in our application, be it a channel, mix task, or long-running process importing CSV data»
  [PX2]. Подписчики брокера и воркеры гайды не разбирают.
- **К6.** Write и read — функции одного модуля поверх Ecto (`list_*`, `get_*`, `create_*`, `update_*`) [PX2].
  `%Ecto.Changeset{}` назван годным контрактом «to model the data changes between your contexts and your web
  layer» [PX6]. Broadcast идёт после `Repo.transact` в теле функции контекста [PX5]. Read-модели, проекции,
  outbox и ES не рассматриваются.
- **К7.** Механизма нет. При генерации в существующий контекст генератор печатает его размер: «The
  Hello.Catalog context currently has 7 functions and 1 file in its directory» [PX3]. Это сигнал, не проверка.
- **К8.** Источник молчит. Вызовы контекста из web — runtime-зависимости (типы зависимостей — §10). Вывод:
  compile-time связи копятся в web-слое. `use HelloWeb, :controller` — макрос, а «the use of any macro in Elixir
  adds a compile-time dependency to the module that defines the macro» [AP-M]. Пример — 97 входящих
  compile-connected у `lib/livebook_web.ex` в документации xref (§10).
- **К9.** `test/hello/<context>_test.exs` с `Hello.DataCase`: SQL Sandbox, транзакция на тест с откатом.
  Фикстуры строятся через API контекста (`Hello.BlogFixtures`), web — через `HelloWeb.ConnCase` [PX8].
- **К10.** Гайд сам называет два провала:
  - «you can easily end up with large contexts of loosely related entities»;
  - «you would quickly end up with one large context, as the majority of resources in an application are
    connected to each other» [PX3].
  Генератор — «only a starting point» [PX4]. Защиты от «всё зовёт всё» нет. Changeset-контракт тянет Ecto в web.

## 2. «Phoenix is not your application» (Lance Halvorsen)

Первоисточники:

- [LH1] доклад «Phoenix Is Not Your Application», ElixirConf EU 2016: https://vimeo.com/168312419 (видео; не
  транскрибировалось).
- [LH2] «Functional Web Development with Elixir, OTP, and Phoenix», Pragmatic Bookshelf, январь 2018 —
  аннотация и оглавление: https://pragprog.com/titles/lhelph/functional-web-development-with-elixir-otp-and-phoenix/
- [LH3] фрагмент главы «Add a Web Interface with Phoenix» (разделы «Frameworks», «Coupling», «Phoenix Is Not
  Your Application»): https://media.pragprog.com/titles/lhelph/phoenix.pdf
- [LH4] фрагмент главы «Mapping Our Route»: https://media.pragprog.com/titles/lhelph/route.pdf

Суть:

- Бизнес-логика — отдельное OTP-приложение без Phoenix. Phoenix получает его зависимостью: «In Part 1, start by
  building the business logic as a separate application, without Phoenix», «Bring in the application from Part 2
  as a dependency to a new Phoenix project» [LH2].
- Проблема фреймворков: «frameworks make it all too easy to tangle the framework components and the application
  together», и потом «We can't easily reuse the business logic with another interface. We can't test our
  business logic in isolation» [LH3].
- «Whenever we need to send an HTTP request to test a business rule, an alarm should go off at our workstation»
  [LH3].
- Источник сцепления — ORM: «ORMs lead us directly into this coupling of business logic and framework
  components» [LH3].
- Порядок книги: функциональное ядро → state machine → GenServer → супервизия → Phoenix → Channels [LH2].
- Название доклада [LH1] стало заголовком раздела книги «Phoenix Is Not Your Application» [LH3].

По критериям:

- **К1.** Единица — Mix-проект ядра. Phoenix — второй проект, который зависит от ядра [LH2].
- **К2.** Phoenix зависит от ядра, ядро о Phoenix не знает [LH2, LH3]. Публичное — API ядра; во фрагментах
  его форма не показана.
- **К3.** Web вызывает функции ядра (раздел «Call the Logic from the Interface» в оглавлении) [LH2].
- **К4.** Процессы и супервизия — в ядре: «add in the GenServer Behaviour», «Create a supervision tree» [LH2].
- **К5.** Web — один из интерфейсов: «We'll be able to reuse it with any interface we want» [LH4].
- **К6.** Состояние в памяти: «Model domain entities without an ORM or a database» [LH2]. Персистентность,
  read-модели и outbox не рассматриваются.
- **К7.** Принуждение даёт граница Mix-зависимости (вывод). Механизм — `deps` и проверка application
  boundaries компилятором, см. §8.
- **К8.** Источник молчит. Перекомпиляция между проектами идёт по правилам path-зависимостей (§8).
- **К9.** Бизнес-правила тестируются без HTTP [LH3].
- **К10.** Пример книги — учебная игра без БД. Масштаб в сотни модулей и персистентность не рассмотрены.
  Цена отдельных проектов (конфигурация, сборка) — §8.

## 3. Boundary и «Towards Maintainable Elixir» (Saša Jurić)

Первоисточники:

- [BND] README: https://github.com/sasa1977/boundary/blob/master/README.md
- [BND-DOC] moduledoc `Boundary` (v0.11.0): https://boundary.hexdocs.pm/Boundary.html
- [BND-CMP] https://boundary.hexdocs.pm/Mix.Tasks.Compile.Boundary.html
- [BND-CL] https://github.com/sasa1977/boundary/blob/master/CHANGELOG.md
- [BND-70] https://github.com/sasa1977/boundary/issues/70; [BND-72] https://github.com/sasa1977/boundary/issues/72
- Серия «Towards Maintainable Elixir», Medium / Very Big Things, 2021:
  - [TME1] The Development Process (2021-01-21):
    https://medium.com/very-big-things/towards-maintainable-elixir-the-development-process-205ee257c109
  - [TME2] The Core and the Interface (2021-02-10):
    https://medium.com/very-big-things/towards-maintainable-elixir-the-core-and-the-interface-c267f0da43
  - [TME3] Boundaries (2021-03-03):
    https://medium.com/very-big-things/towards-maintainable-elixir-boundaries-ba013c731c0a
  - [TME4] The Anatomy of a Core Module (2021-03-22):
    https://medium.com/very-big-things/towards-maintainable-elixir-the-anatomy-of-a-core-module-b7372009ca6d
  - [TME5] Testing (2021-04-08): https://medium.com/very-big-things/towards-maintainable-elixir-testing-b32ac0604b99
- [SJ-SPAWN] «To spawn, or not to spawn?», 2017-04-04: https://www.theerlangelist.com/article/spawn_or_not
- Посты sasajuric на ElixirForum:
  - [SJ-F1] https://elixirforum.com/t/what-s-wrong-with-umbrella-apps/49585/18 (2022-08-16)
  - [SJ-F2] https://elixirforum.com/t/on-why-elixir/34038/33 (2020-09-01)
  - [SJ-F3] https://elixirforum.com/t/boundary-enforcing-boundaries-in-elixir-projects/24623 (2019-08-12)
  - [SJ-F4] https://elixirforum.com/t/any-downsides-to-using-the-same-table-for-multiple-contexts/29145/6
    (2020-02-19)
  - [SJ-F5] https://elixirforum.com/t/project-structure-and-layering/34612/15 (2020-09-28) и …/34612/23
    (2020-09-29)
  - [SJ-F6] https://elixirforum.com/t/repo-transact/61733/2 (2024-02-18)
- [SJ-CL] «Clarity», ElixirConf EU 2021, слайды:
  https://drive.google.com/file/d/1n8Jd-ljDirYGRujs7ma47Yg96BUg5a3A/view

Суть:

- Core и interface: «we treat contexts as the core of the system, and web as the interface». Interface — «the
  logic specific to the way the clients access the system, such as REST, GraphQL, or WebSocket» [TME2].
  Критерий: «If some problem is protocol-specific, then it is an interface concern» [TME2].
- Core шире домена: «the core is more than just a business domain. This layer also deals with concerns such as
  persistence, and communications with supporting 3rd party services» [TME2]. На слайдах «Clarity» — «Interface
  / Core (biz + infra)» [SJ-CL]. Значит, «core» у Jurić — не functional core в смысле §4.
- Boundary: «A boundary is a named group of one or more modules. Each boundary exports some (but not all!) of
  its modules, and can depend on other boundaries. During compilation, the boundary compiler will find and
  report all cross-module function calls which are not permitted» [BND].
- Граф проекта из серии [TME3]:
  - `Xyz` зависит от `XyzSchemas`, `XyzConfig`;
  - `XyzWeb` — от `Xyz`, `XyzSchemas`, `XyzConfig`;
  - `XyzApp` — от `Xyz`, `XyzWeb`, `XyzConfig`;
  - `XyzMix` — от `Xyz`, `XyzApp`.
  Внутри core есть подграница `Xyz.Infra` — «sink boundary» с репозиториями.
- Тесты: «By default we'll start writing all our tests at the interface level, moving deeper only when it's
  really needed» [TME5].
- Umbrella не нужен: «if the subapps are not deployed separately, the umbrella app doesn't bring anything useful
  to the table, compared to single project + boundary» [SJ-F1].

По критериям:

- **К1.** Единица — граница: корневой модуль с `use Boundary` плюс все модули с его префиксом [BND-DOC].
  Верхний уровень называется суффиксом: «XyzConfig instead of Xyz.Config» [TME3]. Внутри core — подграницы
  (`Xyz.Account`, `Xyz.Tenant`, `Xyz.Infra`) [TME3]. По дереву: модули с `use Boundary`, обычно корень каталога.
- **К2.** Зависимости задаются явно:
  - Вызов в чужую границу разрешён, если она «a direct dependency of the caller boundary» и «exports the used
    module» [BND-DOC]. Корень экспортируется всегда, остальное внутреннее [BND-DOC].
  - Длинный экспорт — «a possible indication of an overly fragmented interface». Исключение — Ecto-схемы,
    «typically a part of the public context interface» [BND-DOC].
  - Подграница «may only depend on its direct siblings, its parent, and any dependency of its ancestors».
    Родитель может звать экспорт детей [BND-DOC].
  - `Xyz.Infra` устроена так, что «prevents anyone outside of the core from directly using repos, AWS client»
    [TME3].
  - Interface может брать из Ecto только `Ecto.Changeset`: «This is enforced with the boundary tool» [TME2].
- **К3.** Прямые вызовы экспортов. Вызов контекста из контекста допустим: «people advising against calling one
  context from another, which is for me too dogmatic» [SJ-F5]. Зависимость core от interface инвертируется
  через behaviour: core объявляет `MySystem.UrlProvider` (`@callback`), а реализацию `MySystemWeb.UrlProvider`
  получает параметром-модулем [TME2]. Событий и PubSub между контекстами в серии нет.
- **К4.** «Use functions and modules to separate thought concerns. Use processes to separate runtime concerns»
  [SJ-SPAWN]. Граница `XyzApp` держит Application и «introduced to break the dependency cycle between the
  interface and the core» [TME3].
- **К5.** Interface — REST, GraphQL, WebSocket. Вход нормализуется schemaless changeset'ом в interface [TME2].
  Фоновую задачу (Oban) ставит core внутри `Repo.transact` [TME2]. Брокеры и CLI в серии не упомянуты.
- **К6.** Write и read — функции core-модулей. Changeset строится внутри функции контекста: «We avoid creating
  public changeset builder functions, because this leads to weakly typed abstractions» [TME4].
  - `Repo.transact` предпочтён `Ecto.Multi` [TME4, SJ-F6].
  - Эффекты лежат в core: письмо уходит из `register`, Oban-задача ставится в транзакции [TME2].
  - Read-моделей и ES в серии нет.
- **К7.** Принуждение:
  - Компилятор `:boundary` на compilation tracers. Нарушение — предупреждение: «a deliberate decision made to
    avoid disrupting the development flow… it's worth enforcing boundaries on the CI… `--warnings-as-errors`»
    [BND-CMP].
  - В проекте серии: «code can only be merged if it fully complies» [TME3]. Свои правила вёрстки — через
    Credo; проверка `StrictModuleLayout` отправлена в Credo upstream [TME1].
  - Цена:
    - каждый модуль надо классифицировать (иначе «X is not included in any boundary»);
    - списки exports;
    - `dirty_xrefs` для исключений;
    - для test support — отдельная граница с `check: [in: false, out: false]` [BND-DOC].
  - Ограничения [BND-DOC, BND-CL]:
    - вызовы `:elixir` и pure-Erlang приложений ограничить нельзя;
    - реализации протоколов по умолчанию не проверяются;
    - «it's not possible permitting some dependency only at runtime»;
    - ссылки по алиасу и `apply(Foo, ...)` проверяются только с `check: [aliases: true]`.
- **К8.** Boundary проверяет граф вызовов, но compile-time связи не снижает. Своя стоимость проверки по 0.10.1:
  «On a large project (7k+ files, 480k LOC), the running time is reduced from about 50 seconds to about 1
  second» [BND-CL]. Зависимость только на время компиляции записывается `deps: [{Mix, :compile}]` [BND-DOC].
  Вывод: запрет обратного ребра core → interface убирает класс циклов, которые xref (§10) считает главным
  источником каскадов. Источник об этом не говорит.
- **К9.** Тесты по умолчанию идут через интерфейс. Repo напрямую не трогают: «we rely on the public API to bring
  the system into the desired state» [TME5]. Двойники — «We mostly reach for them to fake a remote service»
  [TME5]. Mox в серии не упоминается. Test support выносится в границу с выключенными проверками [BND-DOC].
- **К10.** Стоимость и границы применимости:
  - Опыт серии — проект примерно из 100 модулей: 50 схем, 23 модуля в `Xyz` [TME3]. Тесты через интерфейс
    «doesn't scale well with the number of tests» в «our projects, which are not very large» [TME5].
  - Схемы вынесены в отдельную границу: «Somewhat controversially, we decided to group our Ecto schema modules
    under the same top-level boundary» [TME3].
  - Против дробления: «a huge amount of micro-modules… the code was incredibly confusing» [SJ-F5].
  - Раздел Status в README устарел: «has not been tested on larger projects or umbrella projects» [BND].
  - Внедрение в живой проект — постепенное, через `check: [out: false]` на части пространств [BND-70]. На
    кэшированном `_build` бывают ложные «unknown module … is listed as an export» [BND-72].
  - Применимость core/interface по Jurić: «the basic minimum… in any long-term real-life project», но «less
    useful, possibly even counterproductive, in small one-off projects» [TME2].
  - О DDD: «In my view, Phoenix contexts are not DDD bounded contexts… it's fine for multiple contexts to use
    the same tables» [SJ-F4].

## 4. Слои «Designing Elixir Systems with OTP» и functional core / imperative shell

Далее в тексте и таблицах: DESO — книга «Designing Elixir Systems with OTP», FC-IS — functional core /
imperative shell.

Первоисточники:

- [DES1] James Edward Gray II, Bruce A. Tate, «Designing Elixir Systems with OTP», Pragmatic Bookshelf, декабрь
  2019 — аннотация и оглавление: https://pragprog.com/titles/jgotp/designing-elixir-systems-with-otp/
- [DES2] фрагмент гл. 1 «Build Your Project in Layers»: https://media.pragprog.com/titles/jgotp/start.pdf
- [DES3] фрагмент «Introduction»: https://media.pragprog.com/titles/jgotp/intro.pdf
- [DES4] фрагмент гл. 6 «Isolate Process Machinery in a Boundary» (итог «Wrap Your Core in a Boundary API»):
  https://media.pragprog.com/titles/jgotp/boundaries.pdf
- [GB1] Gary Bernhardt, «Boundaries», SCNA 2012: https://www.destroyallsoftware.com/talks/boundaries
- [GB2] Gary Bernhardt, «Functional Core, Imperative Shell», 2012-07-12:
  https://www.destroyallsoftware.com/screencasts/catalog/functional-core-imperative-shell

Суть:

- Слои: «data structures, a functional core, tests, boundaries, lifecycle, and workers». Мнемоника — «Do fun
  things with big, loud worker-bees» [DES2].
- Набор слоёв не обязателен: «Not every project will have all of these layers… It's your job as the author of a
  codebase to decide which layers are worth the price» [DES2].
- Ядро — «what some programmers call the business logic. This inner layer does not care about any of the
  machinery related to processes; it does not try to preserve state; and it has no side effects» [DES2].
- Граница (boundary) — процессы, состояние и API над ними: «we left our safe bubble of the functional core and
  ventured out to the real world to deal with state, processes, and communication between components»
  [DES4]. Там же: `with` для неопределённого входа, `handle_call` вместо `handle_cast` ради back pressure.
- Единица — компонент: «We'll call each unit of software you build that honors these concepts a component»
  [DES2].
- OTP не по умолчанию: «Sometimes OTP is the wrong thing to do. The first half of this book does not cover OTP
  at all!» [DES3].
- Bernhardt: оболочка «manipulates stdin, stdout, the database, and the network, all based on values produced
  by the functional core». Тестирование ядра «often naturally allows isolated testing with no test doubles»
  [GB2]. Простые значения служат «as the boundaries between components and subsystems» [GB1].

По критериям:

- **К1.** Единица — компонент со слоями [DES2]. Персистентность в книге — отдельная зависимость: главы
  «Add Persistence as a Boundary Service», «Integrate MasteryPersistence into Mastery» [DES1]. Раскладку
  каталогов фрагменты не показывают.
- **К2.** Boundary зависит от core; core не зависит ни от чего, потому что в нём нет процессов и эффектов
  [DES2]. Наружу торчит API-слой: «we built an API layer to access our server layer in a convenient way»
  [DES4].
- **К3.** Вызов идёт через API-модуль границы, который скрывает `GenServer.call` [DES4]. Персистентность — как
  «Boundary Service» [DES1].
- **К4.** Отдельные слои lifecycle и workers: «Configure Applications to Start Supervisors», «Start Per-User
  Processes with a Dynamic Supervisor» [DES1].
- **К5.** Phoenix — потребитель компонентов: глава «Integrate Your OTP Dependencies into Phoenix» [DES1].
- **К6.** Эффекты — только в границе и воркерах [DES2, GB2]. Разделения write/read и ES нет.
- **К7.** Нет, только дисциплина.
- **К8.** Во фрагментах не обсуждается.
- **К9.** Тесты — отдельный слой. Главы «Test Your Core» (фикстуры, named setups) и «Test the Boundary» с
  разделом «Tests Call the API as a User Would» [DES1]. У Bernhardt ядро тестируется без двойников [GB2].
- **К10.** Пример книги (квиз Mastery) мал, масштаб сотен модулей не обсуждается. Цену слоёв авторы
  предлагают взвешивать самому [DES2].

## 5. Hexagonal / ports & adapters и его Elixir-форма

Первоисточники:

- [AC1] Alistair Cockburn, «The Hexagonal (Ports & Adapters) Architecture», HaT Technical Report 2005.02,
  2005-09-04: https://alistair.cockburn.us/hexagonal-architecture/
- [JV1] José Valim, «Mocks and explicit contracts», 2015-10-14: https://dashbit.co/blog/mocks-and-explicit-contracts
- [MOX] README: https://github.com/dashbitco/mox; moduledoc: https://mox.hexdocs.pm/Mox.html

Суть:

- Intent: «Allow an application to equally be driven by users, programs, automated test or batch scripts, and to
  be developed and tested in isolation from its eventual run-time devices and databases» [AC1].
- Порт — «a purposeful conversation». На один порт приходится несколько адаптеров: «a test harness, a batch
  driver, an http interface, … a mock (in-memory) database, a real database» [AC1].
- Primary (driving) и secondary (driven): «The distinction between primary and secondary lies in who triggers
  or is in charge of the conversation» [AC1]. Портов мало: «My selection tends to favor a small number, two,
  three or four» [AC1].
- Elixir-форма у Valim: контракт — behaviour с `@callback`, реализация выбирается конфигурацией приложения.
  Мок — «a noun, never a verb» [JV1].
- Правило Valim: «for each test using a mock, you must have an integration test covering the usage of that mock»
  [JV1].
- Где контракт не нужен: «we invoke modules such as URI and Enum … and we don't want to hide those behind
  contracts. But if we are talking about something as complex as an external API, defining an explicit
  contract … is going to do your code wonders» [JV1].
- Mox: «No ad-hoc mocks. You can only create mocks based on behaviours», «Tests using the same mock can still
  use `async: true`» [MOX]. Шаблон — прокси-модуль с `@callback` и `defp impl, do:
  Application.get_env(:my_app, :weather, MyApp.ExternalWeatherAPI)` [MOX].

По критериям:

- **К1.** Единица — приложение («inside») с портами. Адаптеры — снаружи. В Elixir порт — behaviour-модуль,
  адаптер — модуль с `@behaviour` [JV1]. Раскладку каталогов Cockburn не задаёт.
- **К2.** Адаптеры зависят от приложения. Приложение «blissfully ignorant of the nature of the input device»
  [AC1]. У Valim: «[MyApp] -> [MyApp.Twitter (contract)]», «[MyApp.Twitter.HTTP (contract impl)] ->
  [HTTPClient] -> [Twitter API]» [JV1].
- **К3.** Связь — через порт: вызов функции behaviour-модуля с диспетчеризацией на реализацию из конфига
  [JV1, MOX].
- **К4.** Не регламентируется.
- **К5.** Primary-адаптеры «on the left side (or top)»: HTTP, тестовый драйвер, batch [AC1]. Вывод: контроллеры,
  подписчики брокера и воркеры — primary-адаптеры.
- **К6.** Secondary-порты: БД и внешние системы [AC1]. Вывод: паблишер брокера — secondary-адаптер. Разделение
  write/read — не предмет паттерна.
- **К7.** У Cockburn нет. В Elixir компилятор проверяет `@behaviour`/`@impl`: «Elixir will help you provide the
  expected API» [JV1].
- **К8.** Источник молчит. Вывод: в шаблоне Mox реализация резолвится в рантайме, поэтому вызывающий модуль
  связан с behaviour runtime-зависимостью. Выбор реализации через `compile_env` дал бы compile-time связь
  с конфигом.
- **К9.** Изоляция ради тестов — главная мотивация [AC1]. Mox работает с `async: true` [MOX]. Valim требует
  интеграционный тест на каждый мок [JV1].
- **К10.** «Define too many boundaries and you have too many moving parts» [JV1]. Число портов — вопрос
  интуиции, жёсткого правила Cockburn не даёт [AC1]. Критику Bogard против слоёв и моков — см. §9.

## 6. Commanded

Первоисточники (гайды — https://github.com/commanded/commanded/tree/main/guides):

- [CMD-U] Usage.md; [CMD-APP] Application.md; [CMD-AGG] Aggregates.md; [CMD-CMD] Commands.md; [CMD-EV] Events.md;
  [CMD-PM] «Process Managers.md»; [CMD-RM] «Read Model Projections.md»; [CMD-T] Testing.md; [CMD-DEP]
  Deployment.md; [CMD-ES] «Choosing an Event Store.md»
- [CMD-AGS] https://github.com/commanded/commanded/blob/main/lib/commanded/aggregates/aggregate.ex
- [CMD-FAQ] https://github.com/commanded/commanded/wiki/FAQ
- [CMD-FCIS] https://github.com/commanded/commanded/wiki/Functional-core,-imperative-shell
- [CMD-PR547] https://github.com/commanded/commanded/pull/547
- [CEP] https://github.com/commanded/commanded-ecto-projections/blob/master/guides/Usage.md
- [CDT] Conduit (пример автора Commanded, последний push 2021-03-07): https://github.com/slashdotdash/conduit
- [BC] Ben Smith, «Building Conduit», Leanpub (помечена «70% complete», обновлена 2019-05-24), главы:
  https://leanpub.com/read/buildingconduit/chapter-contexts,
  https://leanpub.com/read/buildingconduit/chapter-introduction
- [HEX] версии: commanded 1.4.11 (2026-07-27), commanded_ecto_projections 1.4.0 (2024-01-18), eventstore 1.4.10
  (2026-09-29) — https://hex.pm/api/packages/commanded и т. п.

Суть:

- Блоки:
  - Aggregate с `execute/2` и `apply/2`;
  - команды и Router (`dispatch`, `identify`, `middleware`);
  - event handlers, process managers, Ecto-проекции.
  «aggregates handle commands and create events; process managers handle events and create commands» [CMD-PM].
- Согласованность: «strong consistency for command dispatch (write model) and eventual consistency, by default,
  for the read model» [CMD-U]. `consistency: :strong` блокирует dispatch, пока события не обработают
  сильно-согласованные хендлеры [CMD-CMD].
- Агрегат — GenServer на экземпляр; конкурентные команды «are serialized and executed in the order received»
  [CMD-AGS]. Wiki: «Functional core, imperative shell … is how I recommend using Commanded» [CMD-FCIS].
- Данные чужого агрегата: «lookup the data from a projection and include it in the command before dispatch»
  [CMD-AGG].
- Раскладку по контекстам фреймворк не предписывает. Единственное упоминание — `CompositeRouter`, «useful if
  you prefer to construct a router per context» [CMD-CMD]. Conduit раскладывает по контекстам, см. К1.

По критериям:

- **К1.** Единица — `Commanded.Application`, «also a composite router» [CMD-APP]. Предметная единица в Conduit
  — каталог контекста `lib/conduit/<context>/` [CDT]:
  - фасад `<context>.ex`;
  - подкаталоги по виду артефакта: `aggregates`, `commands`, `events`, `projections`, `projectors`, `queries`,
    `validators`, `workflows`;
  - свой `supervisor.ex`.
  В книге: «Contexts have their own folder within lib/conduit which immediately shows at a high level what the
  Conduit app does» [BC].
- **К2.** Контроллер зовёт фасад контекста (`Accounts.register_user/1`). Фасад делает `App.dispatch(...,
  consistency: :strong)` и читает проекцию через `Queries.*` и `Repo` [CDT]. Агрегат не зовёт агрегаты [CMD-AGG].
- **К3.** Между контекстами — события. В Conduit хендлер `Blog.Workflows.CreateAuthorFromUser` ловит
  `Accounts.Events.UserRegistered` и вызывает `Blog.create_author` [CDT]. Process managers превращают события
  в команды [CMD-PM]. Валидатор уникальности читает проекцию другого контекста [CDT].
- **К4.** Процессами управляет фреймворк:
  - DynamicSupervisor `Commanded.Aggregates.Supervisor`;
  - агрегат с `restart: :temporary` и behaviour `AggregateLifespan` [CMD-AGS, CMD-CMD].
  Хендлеры, PM и проекторы пользователь стартует в своём супервизоре [CMD-U]; в Conduit — `supervisor.ex`
  контекста [CDT]. «Commanded guarantees only one instance of an event handler will run, regardless of how
  many nodes are running» (advisory locks) [CMD-EV]. Реестры: `:local`, `:global`, swarm [CMD-DEP].
- **К5.** HTTP идёт через фасад к dispatch. Middleware — «command validation, authorization, logging» [CMD-CMD].
  Kafka как хранилище событий: «Can I use Apache Kafka with Commanded? No» [CMD-FAQ]. Входящие подписчики
  брокеров фреймворк не описывает.
- **К6.** Write и read:
  - Write — агрегаты в event store.
  - Read — Ecto-проекции. `project` с `Ecto.Multi`: «These will all be executed within a single transaction»;
    таблица `projection_versions` следит, чтобы «events are only projected once» [CEP].
  - Эффекты — в event handlers («sending emails», «third-party systems») [CMD-EV, CMD-FCIS].
  - Доставка at-least-once, повтор пропускается через `{:error, :already_seen_event}` [CMD-EV]. Outbox в
    коде, гайдах, wiki и issues не найден.
  - Read-after-write — `:strong` или версия агрегата как ETAG [CMD-CMD, CMD-RM].
- **К7.** Границ контекстов фреймворк не проверяет.
- **К8.** Router построен на макросах. Сопровождающие снижали его compile-связи: PR #547 «Refactor router
  macros to limit compile-time dependencies» [CMD-PR547], #363 «Remove router module compile-time checking».
  У проекций «`:repo` must be specified at compile-time» [CEP].
- **К9.** Тесты:
  - `Commanded.Assertions.EventAssertions`: `assert_receive_event`, `wait_for_event` [CMD-T];
  - InMemory event store «for **test use only**»; сброс через `Storage.reset!()` плюс TRUNCATE
    `projection_versions` [CMD-T];
  - given/when/then агрегата без процессов — `test/support/aggregate_case.ex` в Conduit, в hex-пакет не входит
    [CDT].
- **К10.** Названные провалы:
  - Каскад остановок хендлеров «can lead the supervisor itself to give up… until it stops your application»
    [CMD-EV].
  - Анти-паттерн «blindly copying all event data into aggregate state» [CMD-AGG].
  - В книге: «Domain events provide a history of your poor design decisions and they are immutable», плюс
    сложность eventual consistency [BC].
  - Production-хранилище — только PostgreSQL EventStore [CMD-ES].
  - Conduit и книга не обновлялись с 2019–2021.

## 7. Ash Framework

Первоисточники (документация — https://github.com/ash-project/ash/tree/main/documentation):

- [ASH-WHAT] topics/about_ash/what-is-ash.md; [ASH-DP] topics/about_ash/design-principles.md
- [ASH-GL] topics/reference/glossary.md; [ASH-DOM] topics/resources/domains.md
- [ASH-ACT] topics/actions/actions.md; [ASH-PS] topics/development/project-structure.md
- [ASH-CI] topics/resources/code-interfaces.md; [ASH-UP3] topics/development/upgrading-to-3.0.md
- [ASH-DSL] dsls/DSL-Ash.Domain.md; [ASH-REL] topics/resources/relationships.md
- [ASH-NOT] topics/resources/notifiers.md; [ASH-MSA] topics/advanced/multi-step-actions.md
- [ASH-TEST] topics/development/testing.md; [ASH-TR] how-to/test-resources.livemd
- [ASH-UR] https://github.com/ash-project/ash/blob/main/usage-rules/code_interfaces.md
- [ASH-URT] https://github.com/ash-project/ash/blob/main/usage-rules/testing.md
- [ASH-RES] https://github.com/ash-project/ash/blob/main/lib/ash/resource.ex
- [ASH-VER]
  https://github.com/ash-project/ash/blob/main/lib/ash/domain/verifiers/validate_related_resource_inclusion.ex
- [SPARK] https://github.com/ash-project/spark/blob/main/documentation/how_to/writing-extensions.md
- [ASH-2267] https://github.com/ash-project/ash/issues/2267
- [ASH-EV] https://github.com/ash-project/ash_events (0.8.2, 2026-09-19)
- [ASH-F] https://elixirforum.com/t/my-thoughts-on-ash/69829
- Версия ash 3.33.11 (2026-09-25).

Суть:

- Форма — ресурсы и действия: «a framework for modeling your application's domain through **Resources** and
  their **Actions**», «Ash is not a web framework… It is a framework for building your application layer»
  [ASH-WHAT].
- Domain — «A method of broadly separating resources into different domains, A.K.A bounded contexts» [ASH-GL].
  «If you are familiar with a Phoenix Context… you can think of a domain as the Ash equivalent» [ASH-DOM].
- Поведение декларативно: Spark DSL, actions, changes, preparations, validations, policies. «A resource, for
  example, is really just a configuration file» [ASH-DP].
- Контракт вызова: «Use code interfaces on domains to define the contract for calling into Ash resources»
  [ASH-UR].
- Notifiers срабатывают «after the current transaction is committed» с семантикой «"at most once"». Надёжный
  эффект — Oban-задача в той же транзакции или Reactor [ASH-NOT].
- «Ash is _not_ a Domain Driven Design framework» [ASH-DP]. ES — отдельное расширение ash_events: журнал
  событий и replay [ASH-EV].

По критериям:

- **К1.** Единица — domain `lib/my_app/accounts.ex` с каталогом ресурсов `accounts/`. Файлы ресурса лежат в
  `accounts/user/{changes,preparations,checks}` [ASH-PS]. Это рекомендация: «None of the things we show you here
  are _requirements_» [ASH-PS].
- **К2.** «All resource interaction ultimately goes through a domain module» [ASH-PS]. Ресурс вне домена даёт
  предупреждение компиляции: «Resource … is not present in any known Ash.Domain module» [ASH-RES]. Чужой
  ресурс в relationship должен быть принят доменом или указан опцией `domain:`, иначе ошибка verifier'а
  [ASH-DSL, ASH-REL, ASH-VER].
- **К3.** Между доменами — relationships (в том числе through по разным доменам) и code interface чужого
  домена [ASH-REL, ASH-CI]. Асинхронно — notifiers (PubSub) и Reactor для саг [ASH-NOT, ASH-MSA]. Ресурс в
  нескольких доменах: «While it is possible for resources to be used with multiple domains, it almost never
  happens in practice» [ASH-UP3].
- **К4.** Процессы приложения Ash не задаёт. Фоновые задачи — AshOban/Oban: «For durable workflows, we suggest
  to use Oban» [ASH-MSA].
- **К5.** Web зовёт code interface. Логика в LiveView — антипример: «this is putting business logic inside of
  your UI/representation layer. Instead, you should write an action» [ASH-PS].
- **К6.** Write и read — actions ресурса над data layer (AshPostgres).
  - «Create, update and destroy actions are run in a transaction by _default_» [ASH-ACT].
  - Хуки: «Use `before_transaction` for external API calls… Use `after_action` for transactional side effects…
    Use `after_transaction` for external notifications» [ASH-ACT].
  - Outbox не упоминается.
  - В ash_events replay «Clears existing records… Applies each event to rebuild resource state», и при replay
    «**all** action lifecycle hooks are automatically skipped» [ASH-EV].
- **К7.** Проверяют verifiers DSL: регистрацию ресурсов в домене и междоменные relationships [ASH-RES,
  ASH-VER]. Цена — обучение DSL (К10).
- **К8.** Spark-transformers работают при компиляции модуля. Verifiers «run after the module is compiled…
  Does not create compile-time dependencies between modules» [SPARK].
  - Рекомендации Ash: `simple_notifiers` — «to avoid unnecessary compile time dependencies» [ASH-NOT]; changes
    выносить в модули, чтобы «keep compile times down» [ASH-MSA].
  - Issue контрибьютора (не сопровождающего) о самом репозитории Ash: «Ash currently has 187 compilation cycles,
    which causes slower compilation time and most of the project to recompile for even small code changes»
    [ASH-2267].
- **К9.** Тесты:
  - `config :ash, :disable_async?, true` «necessary for doing transactional tests with `AshPostgres`»;
    `:missed_notifications, :ignore` [ASH-TEST];
  - property-тесты через `Ash.Generator`, политики — «in isolation» через `Ash.can?` [ASH-TR];
  - usage-rules: «Test your domain actions through the code interface» [ASH-URT].
- **К10.** Сопровождающие и авторы:
  - «The learning curve is definitely the biggest one» (sevenseacat, «Author of Ash Framework») [ASH-F];
  - «ultimately Ash isn't a fit for every person or every project» (Zach Daniel) [ASH-F];
  - «Ash is still niche, so developers may not know it right out of the gate» [ASH-WHAT].
  Вывод: Ash владеет моделью данных и транзакцией action. Внешние ES-агрегаты decide/evolve и своё хранилище
  событий образуют параллельную модель, и ash_events её не заменяет, а оборачивает actions.

## 8. Umbrella, poncho, одно OTP-приложение

Первоисточники:

- [MIX-P] Mix.Project, «Umbrella projects» и «Undoing umbrellas»: https://mix.hexdocs.pm/Mix.Project.html
- [EL-UMB] гайд Elixir 1.18 «Dependencies and umbrella projects»:
  https://hexdocs.pm/elixir/1.18.4/dependencies-and-umbrella-projects.html
- [EL-PR] PR José Valim «Revamp Mix & OTP guides», слит 2025-07-11: https://github.com/elixir-lang/elixir/pull/14637
- [JV-UMB] José Valim, elixir-lang-core, 2017-10-18: https://groups.google.com/d/topic/elixir-lang-core/X4pquETZKWQ
- [CL-1.11] https://github.com/elixir-lang/elixir/blob/v1.11/CHANGELOG.md
- [CL-1.14] https://github.com/elixir-lang/elixir/blob/v1.14/CHANGELOG.md
- [CL-1.15] https://github.com/elixir-lang/elixir/blob/v1.15/CHANGELOG.md
- [PHX-NEW] https://phoenix.hexdocs.pm/Mix.Tasks.Phx.New.html
- [PONCHO] Greg Mefford, «Poncho Projects», 2017-05-19: https://embedded-elixir.com/post/2017-05-19-poncho-projects/
- [NRV] гайд Nerves «User Interfaces» до октября 2024:
  https://github.com/nerves-project/nerves/blob/6f9f8b0b/guides/core/user-interfaces.md
- [SJ-F1], [SJ-F2], [SJ-F3] — §3

Суть:

- Umbrella — `apps/` с OTP-приложениями. Общие `build_path`, `config_path`, `deps_path`, `lockfile`.
  «While it provides a degree of separation between applications, those applications are not fully decoupled,
  as they share the same configuration and the same dependencies» [MIX-P].
- Valim: «Umbrella projects are three things in one: 1. The mono-repo pattern 2. Sharing of dependencies across
  projects 3. Loading all code in the same VM» [JV-UMB]. Далее пересказ того же сообщения: изоляция
  конфигураций внутри umbrella — неверное употребление; для изоляции — mono-repo с path-зависимостями.
- Гайд 1.18: «When using umbrella applications, it is important to have a clear boundary between them… must
  only access public APIs». Раздел так и называется: «Don't drink the kool aid» [EL-UMB].
- В 2025 глава снята из гайда Mix & OTP: «Skip the discussion on umbrellas» [EL-PR]. В Mix.Project остался
  раздел «Undoing umbrellas» [MIX-P].
- Poncho — «plain-old-Elixir projects with applications that use plain-old-dependencies»: `path:` вместо
  `in_umbrella: true` [PONCHO]. Nerves называл poncho «the preferred project structure» [NRV]. В текущей версии
  гайда тема снята как «advanced topics».
- Phoenix: `--umbrella` даёт «one application for your domain, and a second application for the web interface»
  [PHX-NEW]. По умолчанию — одно приложение с `lib/hello` и `lib/hello_web` [PX7].
- Jurić: «I've never used them myself. The boundary project is my attempt to tackle this issue in a different
  way» [SJ-F2]. Boundary с самого анонса «explores the idea of enforcing boundaries in Elixir projects without
  requiring the extra ceremony of umbrella apps» [SJ-F3]. После деамбреллизации проекта примерно из 10
  приложений — «about 2k LOC less… faster test and build times» [SJ-F1].

По критериям:

- **К1.** Единица:
  - umbrella — OTP-приложение `apps/<name>/mix.exs`;
  - poncho — Mix-проект рядом с другими;
  - одно приложение — каталог или неймспейс.
- **К2.** В umbrella зависимость явная: `{:kv, in_umbrella: true}`. С v1.11 компилятор предупреждает о вызове
  модуля sibling-приложения без зависимости — «effectively forbidding cyclic dependencies between apps»
  [CL-1.11]. Публичность — соглашение: «must only access public APIs» [EL-UMB]. В одном приложении языкового
  разделения нет.
- **К3.** Прямые вызовы; другой способ не регламентирован.
- **К4.** У каждого OTP-приложения своё дерево: «developed as a separate application in the umbrella, with its
  own supervision tree and APIs» [EL-UMB]. В одном приложении — один корень.
- **К5.** В Phoenix-umbrella web — отдельное приложение [PHX-NEW].
- **К6.** Не регламентирует.
- **К7.** Принуждение — граница Mix-зависимости: без объявленной зависимости компилятор предупреждает, циклы
  между приложениями невозможны [CL-1.11]. Цена:
  - в umbrella — общий конфиг и общие версии зависимостей [MIX-P];
  - в poncho — ручная сборка конфигов: «configuration won't be applied automatically, so we should either
    `import` it from there or duplicate the required configuration» [NRV];
  - удобства umbrella («some standard conveniences», общий `mix test`) poncho теряет [PONCHO, EL-UMB].
- **К8.** Перекомпиляция между приложениями:
  - до v1.11 модуль path-зависимости всегда считался compile-time, и «changing an application would cause many
    modules in sibling applications to recompile»;
  - v1.11 тегирует такие модули как exports, «yielding dramatic improvements» [CL-1.11];
  - позже чинили каскады: v1.14 «Ensure semantic recompilation cascades to path dependencies», v1.15 «files
    depending on modules from path dependencies always recompiled» (исправлено) [CL-1.14, CL-1.15].
- **К9.** Тесты — по приложению. Из корня umbrella `mix test` запускает все [EL-UMB].
- **К10.** «If you find yourself in a position where you want to use different configurations in each
  application for the same dependency or use different dependency versions, then it is likely your codebase
  has grown beyond what umbrellas can provide» [MIX-P]. Рецепт отката — свести всё в один проект или разнести
  на отдельные проекты [MIX-P].

## 9. Vertical slice, Clean Architecture, DDD

Первоисточники:

- [JB] Jimmy Bogard, «Vertical Slice Architecture», 2018-04-19: https://www.jimmybogard.com/vertical-slice-architecture/
- [RM] Robert C. Martin, «The Clean Architecture», 2012-08-13:
  https://blog.cleancoder.com/uncle-bob/2012/08/13/the-clean-architecture.html
- [EE-REF] Eric Evans, «Domain-Driven Design Reference», 2015:
  https://www.domainlanguage.com/wp-content/uploads/2016/05/DDD_Reference_2015-03.pdf
- [EE-BK] Eric Evans, «Domain-Driven Design: Tackling Complexity in the Heart of Software», 2003. Главы 4
  «Isolating the Domain», 6 «The Life Cycle of a Domain Object», 14 «Maintaining Model Integrity» (оглавление:
  https://www.informit.com/store/domain-driven-design-tackling-complexity-in-the-heart-9780321125217)
- [VV-EAD] Vaughn Vernon, «Effective Aggregate Design», Part I и II, 2011:
  https://www.dddcommunity.org/wp-content/uploads/files/pdf_articles/Vernon_2011_1.pdf (и `_2.pdf`)
- [VV-IDDD] Vaughn Vernon, «Implementing Domain-Driven Design», 2013. Главы 2 «Domains, Subdomains, and Bounded
  Contexts», 3 «Context Maps», 4 «Architecture», 8 «Domain Events», 10 «Aggregates», 13 «Integrating Bounded
  Contexts», приложение A «Aggregates and Event Sourcing: A+ES» (оглавление издателя:
  https://www.informit.com/store/implementing-domain-driven-design-9780321834577)
- [CR-OB] Chris Richardson, «Pattern: Transactional outbox»:
  https://microservices.io/patterns/data/transactional-outbox.html

Применение к Elixir. Авторы трёх подходов о Elixir не пишут. Elixir-формы их идей — у других авторов:
- Ash называет domain «A.K.A bounded contexts» [ASH-GL];
- Conduit раскладывает агрегаты по контекстам [CDT];
- Jurić: «Phoenix contexts are not DDD bounded contexts» [SJ-F4];
- Phoenix 1.4 вводил отдельную структуру автора `CMS.Author` вместо общего `%User{}` «that has to be everything
  to everyone» (https://github.com/phoenixframework/phoenix/blob/v1.4.0/guides/contexts.md).

### 9.1. Vertical slice (Bogard)

- Срез — запрос: «built around distinct requests, encapsulating and grouping all concerns from front-end to
  back». Правило: «Minimize coupling between slices, and maximize coupling in a slice» [JB].
- Против слоёв: «I tend to see these architectures mock-heavy, with rigid rules around dependency management»;
  «we don't need any kind of "shared" layer abstractions like repositories, services, controllers» [JB].
- Деление на команды и запросы «gives me CQRS out of the gate» [JB].
- Предусловие: «it does assume that your team understands code smells and refactoring» [JB].
- К1 — срез на запрос. К2 — срезы не зависят друг от друга. К3 — общего минимум. К9 — тест на срез. Процессы,
  принуждение и compile-time источник не рассматривает.

### 9.2. Clean Architecture (Martin)

- Dependency Rule: «source code dependencies can only point inwards. Nothing in an inner circle can know
  anything at all about something in an outer circle» [RM].
- Круги — Entities, Use Cases, Interface Adapters, Frameworks and Drivers, причём «the circles are schematic»
  [RM].
- Через границу идут «isolated, simple, data structures» [RM].
- Инверсия: «we would arrange interfaces and inheritance relationships such that the source code dependencies
  oppose the flow of control» [RM]. Вывод: в Elixir эту роль играет behaviour, как в §5.
- К5: Interface Adapters «will wholly contain the MVC architecture of a GUI», а «all the SQL should be
  restricted to this layer» [RM]. К6: use cases «orchestrate the flow of data to and from the entities» [RM].
  Принуждения, процессов и compile-time источник не касается.

### 9.3. DDD (Evans, Vernon)

- Bounded context: «Explicitly define the context within which a model applies. Explicitly set boundaries in
  terms of team organization, usage within specific parts of the application, and physical manifestations such
  as code bases and database schemas» [EE-REF].
- Context map: «Describe the points of contact between the models, outlining explicit translation for any
  communication» [EE-REF].
  - Shared kernel — «Keep this kernel small» [EE-REF].
  - Anticorruption layer — «create an isolating layer to provide your system with functionality of the upstream
    system in terms of your own domain model» [EE-REF].
  - Published language — «Use a well-documented shared language that can express the necessary domain
    information as a common medium of communication» [EE-REF].
  - Развёрнуто — гл. 14 «Maintaining Model Integrity» [EE-BK] (текст книги не читался).
- Aggregate: «Use the same aggregate boundaries to govern transactions and distribution. Within an aggregate
  boundary, apply consistency rules synchronously. Across boundaries, handle updates asynchronously» [EE-REF].
- Vernon [VV-EAD]: «a properly designed bounded context modifies only one aggregate instance per transaction in
  all cases». Правила:
  - Model True Invariants In Consistency Boundaries;
  - Design Small Aggregates;
  - Reference Other Aggregates By Identity;
  - Use Eventual Consistency Outside the Boundary.
- Domain events: «Model information about activity in the domain as a series of discrete events» [EE-REF].
  Связка агрегатов с event sourcing — приложение A «Aggregates and Event Sourcing: A+ES» [VV-IDDD] (текст не
  читался).
- Изоляция домена: «Isolate the expression of the domain model and the business logic, and eliminate any
  dependency on infrastructure, user interface, or even application logic that is not business logic»
  [EE-REF].
- Modules: «Choose modules that tell the story of the system and contain a cohesive set of concepts» [EE-REF].
- Outbox (смежный паттерн): «store the message in the database as part of the transaction that updates the
  business entities», и поэтому «a message consumer must be idempotent» [CR-OB].
- По критериям:
  - К1: bounded context, внутри — модули и агрегаты.
  - К2: связи между контекстами описывает context map.
  - К3: перевод, ACL, события.
  - К6: агрегат — граница транзакции; между агрегатами — eventual consistency.
  - Процессы, принуждение и compile-time источник не задаёт.

## 10. Первая сторона языка: анти-паттерны и `mix xref`

Первоисточники:

- [AP-D] https://elixir.hexdocs.pm/design-anti-patterns.html
- [AP-P] https://elixir.hexdocs.pm/process-anti-patterns.html
- [AP-C] https://elixir.hexdocs.pm/code-anti-patterns.html; [AP-M] https://elixir.hexdocs.pm/macro-anti-patterns.html
- [LG] https://elixir.hexdocs.pm/library-guidelines.html; [XREF] https://mix.hexdocs.pm/Mix.Tasks.Xref.html
- [CL-1.11] — §8; [CL-1.13] https://github.com/elixir-lang/elixir/blob/v1.13/CHANGELOG.md
- [CL-1.19] https://github.com/elixir-lang/elixir/blob/v1.19/CHANGELOG.md
- [WM] Wojtek Mach (Dashbit), «Speeding up re-compilation of Elixir projects», 2020-03-23, обновлено под v1.11+.
  Живой URL — 404, снимок:
  https://web.archive.org/web/2023/https://dashbit.co/blog/speeding-up-re-compilation-of-elixir-projects

Это не архитектура, а требования языка к любой из них.

- **Процессы (К4).**
  - Процесс «should only be used to model runtime properties (such as concurrency, access to shared resources,
    error isolation, etc). When you use a process for code organization, it can create bottlenecks»;
    «code organization must be done only through modules and functions» [AP-P].
  - «Scattered process interfaces» лечится тем, что работа с процессом собирается «in a single module» [AP-P].
  - «Unsupervised processes»: долгоживущие процессы вне деревьев мешают «fully controlling their lifecycle»
    [AP-P].
- **Compile-time (К8).** Типы зависимостей — compile, export, runtime [XREF].
  - Compile-connected — «files you depend on at compile-time … which also have their own dependencies» [XREF].
  - Худший случай — цикл: «a change to any file in the cycle will cause all compile-time deps to recompile.
    Therefore, your first priority to reduce constant recompilations is to remove them» [XREF].
  - Инструменты: `mix xref graph --format cycles --label compile-connected` и `--format stats` [XREF];
    `--label compile-connected` появился в v1.13 [CL-1.13].
  - В v1.19 добавлен `--min-cycle-label`: «the issue is not the size of the cycle … but how many compile-time
    dependencies (aka compile labels) in a cycle» [CL-1.19].
  - Пример из документации xref: `lib/livebook_web.ex` имеет 97 входящих compile-connected зависимостей [XREF].
- **Макросы (К8).** «because the `plug MyApp.Authentication` was invoked at compile-time, the module
  `MyApp.Authentication` is now a compile-time dependency of `MyApp`… this can now lead to a large recompilation
  graph». Лечение — `Macro.expand_literals/2` [AP-M].
  - Обратная беда — «Untracked compile-time dependencies» от динамических имён модулей [AP-M].
  - `use` против `import`: `use` «has a *broader scope*, which can be problematic» [AP-M].
- **Данные о каскадах (К8).** В hexpm `touch lib/hexpm/accounts/user.ex` перекомпилировал 90 файлов на v1.10 и
  16 — на v1.11, после перевода `import`/`require` в export-зависимости [CL-1.11]. Dashbit: роутерные `import`
  меняли на `alias`, а `plug_init_mode: :runtime` в dev убирает compile-связь от `plug` [WM].
- **Конфигурация (К7).** «library authors should avoid using the application environment to configure their
  library… the application environment is a **global** state» [AP-D]. Optional-зависимости библиотеки:
  проверять `mix compile --no-optional-deps --warnings-as-errors` [LG].
- **Пространства имён (К2).** «Namespace trespassing»: библиотека держит все модули под своим префиксом [AP-C].
- **Границы приложений (К7).** С v1.11 «Elixir will warn if you invoke a function from an existing module but
  this module does not belong to any of your listed dependencies» [CL-1.11].

## 11. Живые open-source приложения (исходный код)

Выбраны два приложения близкого масштаба (hexpm, Plausible) и два с иной формой: кластер (Realtime) и
приложение без БД с процессами (Livebook). Базовые URL:

- hexpm @ `503f9d6`: https://github.com/hexpm/hexpm/blob/503f9d6/
- Plausible @ `d21298d`: https://github.com/plausible/analytics/blob/d21298d/
- Supabase Realtime @ `3bb2567`: https://github.com/supabase/realtime/blob/3bb2567/
- Livebook @ `81db338`: https://github.com/livebook-dev/livebook/blob/81db338/

Общее для всех четырёх:

- Одно OTP-приложение. Umbrella нет, `boundary` нет.
- `mix xref` в CI нет. CI собирает с `mix compile --warnings-as-errors`.
- Есть ссылки из домена в web:
  - hexpm — `@derive HexpmWeb.Stale` в 13 схемах, `import HexpmWeb.ViewHelpers` в `repository/packages.ex`;
  - Plausible — `PlausibleWeb.Endpoint.broadcast` в `auth/user_sessions.ex`;
  - Realtime — 14 доменных файлов ссылаются на `RealtimeWeb.*`;
  - Livebook — 5 доменных файлов, включая `application.ex`.

### 11.1. hexpm

- **К1.** 454 файла `.ex` в `lib/`. Единица — каталог-контекст без модуля-фасада: файла `accounts.ex` нет.
  Рядом лежат схема и модуль операций во множественном числе (`accounts/user.ex` и `accounts/users.ex`,
  `repository/packages.ex`).
  - `use Hexpm.Context` подключает `Repo`, `Ecto.Query` и `Hexpm.Shared`.
  - `Hexpm.Shared` алиасит около 55 модулей (`lib/hexpm/context.ex`, `lib/hexpm/shared.ex`).
- **К2, К3.** Контексты зовут друг друга напрямую: `repository/owners.ex` → `Organizations.access?`,
  `repository/releases.ex` → `Emails.package_published`.
  - PubSub — только для режима записи (`lib/hexpm/write_mode.ex`). Доменных событий нет.
  - Web делает 22 прямых вызова `Repo` в 13 файлах. Макрос контроллера импортирует `Ecto.Query`.
- **К4.** Дерево в `lib/hexpm/application.ex` собирается по режиму `HEXPM_MODE` (web/worker). Oban-воркеры (16)
  лежат в каталогах фич (`repository/registry_worker.ex`, `emails/outbox_worker.ex`).
- **К5/К9 (порты).** 10 `Mox.defmock` в `test/support/mocks.ex` (Billing, Store, CDN и др.). Шаблон —
  `defp impl(), do: Application.get_env(:hexpm, :billing_impl)` в `billing/billing.ex`.
- **К8.** PR #582 (2017) «Do not set compile time dependencies on the router»:
  https://github.com/hexpm/hexpm/pull/582.
- **К9.** Тесты повторяют `lib/`: `test/hexpm/accounts`, `test/hexpm_web/controllers`. Фабрика лежит в
  `lib/hexpm/factory.ex`.

### 11.2. Plausible Analytics

- **К1.** `lib/` — 517 `.ex`, `extra/lib/` — 100. Каталоги-контексты (`stats`, `teams`, `billing`, …) и модули-
  фасады в корне `lib/plausible/` (`sites.ex`, `teams.ex`, `stats.ex`). Воркеры — `lib/workers/`
  (`Plausible.Workers.*`).
- **К7.** Единственная механически проверяемая граница из четырёх — CE/EE:
  - `elixirc_paths` по `MIX_ENV` включает или исключает `extra/lib`;
  - макросы `on_ee` / `on_ce` выбирают ветку при компиляции (261 вхождение в 101 файле);
  - CI собирает матрицу `mix_env: ["test", "ce_test"]` с `--warnings-as-errors`. Ссылка из `lib` в `extra`
    вне `on_ee` ломает CE-сборку (`lib/plausible.ex`, `mix.exs`, `.github/workflows/elixir.yml`).
- **К2, К3.** `PlausibleWeb.SiteController` подключает `use Plausible.Repo` и делает 35 вызовов `Repo`. Всего в
  web 141 вызов `Repo` в 39 файлах. Контексты алиасят друг друга напрямую
  (`alias Plausible.{Auth, Repo, Site, Teams, Billing}` в `sites.ex`).
- **К4.** В `application.ex` несколько Repo (Postgres и ClickHouse), буферы записи, кеши, PubSub, Oban.
- **К5/К9 (порты).** `@callback` + `Application.get_env(:plausible, :http_impl, __MODULE__)`,
  `Mox.defmock(Plausible.HTTPClient.Mock, …)`.

### 11.3. Supabase Realtime

- **К1.** 252 `.ex`. Корень `lib/realtime/` с модулями `tenants.ex`, `api.ex` и каталогом `tenants/` (из 110
  файлов 88 — миграции). Плюс `lib/extensions/` и path-зависимость `{:forum, path: "./forum"}` — отдельный
  Mix-проект со своим CI, то есть частичный poncho.
- **К3.** Расширения подключаются через behaviour `Realtime.PostgresCdc` и `Application.compile_env(:realtime,
  :extensions)`, вызов — `apply(module, :handle_connect, [opts])` (`lib/realtime/postgres_cdc.ex`).
- **К4.** Процессы на тенанта: `PartitionSupervisor` над `DynamicSupervisor`, `:syn`, `libcluster`, `gen_rpc`.
  ARCHITECTURE.md: «Realtime is a multi-tenant Phoenix app where every node in the cluster runs the same code»;
  «Two things are started once per tenant for the whole cluster on a node chosen by the placement rules».
- **К5.** Web вызывает модули домена (`Api.get_tenant_by_external_id`, `Tenants.health_check`). Прямых вызовов
  `Repo.<fun>` из `realtime_web` нет.
- **К9.** Mimic вместо Mox (29 `Mimic.copy`). `test/support/clustered.ex` поднимает peer-ноды.

### 11.4. Livebook

- **К1.** 265 `.ex`, БД нет. Ecto — только `embedded_schema` и changeset'ы. Модули-фасады в корне `lib/livebook/`
  (`session.ex`, `sessions.ex`, `runtime.ex`, `hubs.ex`) и каталоги рядом.
- **К3, К5.** Web вызывает клиентский API GenServer'ов (`Session.register_client`, `Session.queue_cell_evaluation`
  — около 50 вызовов из `session_live.ex`). События: `subscribe/1` и `Phoenix.PubSub.broadcast` объявлены в
  доменных модулях. Рассылают 11 доменных файлов, подписываются 14 web-файлов.
- **Порты — протоколы, а не behaviour.** `defprotocol Livebook.Runtime` с реализациями Attached, Embedded, Fly,
  K8s, Standalone; `Livebook.FileSystem` — Local, S3, Git. Тестовый двойник — `defimpl` в
  `test/support/noop_runtime.ex`. Цель протокола в moduledoc: «not to abstract language backend, but to abstract
  where the code runs».
- **К4.** В `application.ex`: `Livebook.Storage`, `DynamicSupervisor` сессий, `RuntimeSupervisor`,
  `HubsSupervisor`, `Tracker`.

## 12. Компоненты Dave Thomas (добавлено: значимая Elixir-специфичная позиция)

Первоисточник:

- [DT] Dave Thomas, «Splitting APIs, Servers, and Implementations in Elixir», 2017-07-13:
  https://pragdave.me/thoughts/active/2017-07-13-decoupling-interface-and-implementation-in-elixir.html

Суть:

- «I think the conventional way of structuring Elixir code could be improved by paying more attention to
  decoupling.» Все цитаты раздела — [DT].
- Раскладка: `lib/kv.ex` — API («the API belongs in here»), `lib/kv/impl.ex` — логика без GenServer,
  `lib/kv/server.ex` — процесс. Подсерверы — тот же шаблон уровнем ниже. «The rule here is that no one outside
  the application is allowed to call functions outside `lib/kv.ex`.»
- «Erlang applications are really just components.» Thomas пишет код «as series of separate applications, each
  as small as I can make it. And I'm not using umbrella projects for this… I just use file dependencies.»
- О Phoenix: «why do you have contexts in the web layer? Maybe the contexts each correspond to an external app.»

По критериям:

- К1 — OTP-приложение-компонент.
- К2 — внешний мир видит только `lib/kv.ex`.
- К3 — вызов API-модуля.
- К4 — `server.ex` на компонент.
- К7 — граница path-зависимости.
- К9 — «I can also write tests directly against this logic» (против `impl`).
- К10 — цена отдельных проектов та же, что у poncho (§8). Масштаб источник не обсуждает.

---

## Сводная таблица

Ячейки — сжатый пересказ разделов выше со ссылками на те же источники. «—» значит, что источник молчит.

Таблица A — единица, зависимости, взаимодействие.

| Подход | К1 единица | К2 зависимости / публичное | К3 связь единиц |
|---|---|---|---|
| Phoenix contexts | модуль-фасад + каталог | web→ctx→Repo; `@doc false` | прямой вызов; join в БД |
| Halvorsen | Mix-проект ядра | web→ядро; ядро не знает web | вызов API ядра |
| Jurić + Boundary | граница (префикс модуля) | `deps`/`exports`, компилятор | вызов экспорта; behaviour |
| DESO / FC-IS | компонент со слоями | boundary→core | API-модуль границы |
| Hexagonal | приложение + порты | адаптер→порт | порт = behaviour |
| Commanded | каталог контекста | фасад→dispatch / проекция | события, PM, команды |
| Ash | domain + ресурсы | всё через domain | code interface, relationships |
| Umbrella | OTP-app в `apps/` | `in_umbrella`, без циклов | вызов публичного API |
| Poncho | Mix-проект, `path:` | deps Mix | вызов публичного API |
| Один OTP-app | каталог / неймспейс | механизма нет | прямой вызов |
| VSA | срез = запрос | срезы не связаны | минимум общего |
| Clean | круг | только внутрь | простые данные; инверсия |
| DDD | bounded context, агрегат | context map | перевод, ACL, события |
| Dave Thomas | OTP-app-компонент | только `lib/kv.ex` | вызов API-модуля |

Таблица B — процессы, входы, write/read/эффекты.

| Подход | К4 процессы | К5 web и входы | К6 write / read / эффекты |
|---|---|---|---|
| Phoenix contexts | один `application.ex` | `lib/app_web` | CRUD в контексте; broadcast |
| Halvorsen | в ядре | Phoenix — зависимый проект | в памяти, БД нет |
| Jurić + Boundary | runtime-забота; `XyzApp` | REST/GQL/WS | core: БД, Oban в TX |
| DESO / FC-IS | слои lifecycle, workers | Phoenix — потребитель | эффекты только в оболочке |
| Hexagonal | — | primary adapters | secondary ports |
| Commanded | фреймворк: GenServer/агрегат | фасад → dispatch | ES + Ecto-проекции; handlers |
| Ash | —; AshOban | code interface | actions; notifiers после TX |
| Umbrella | дерево на app | web — отдельный app | — |
| Poncho | дерево на проект | web — отдельный проект | — |
| Один OTP-app | один корень | `lib/app_web` | — |
| VSA | — | вход среза | CQRS по запросу |
| Clean | внешний круг | Interface Adapters | use cases; SQL снаружи |
| DDD | — | — | агрегат = граница TX |
| Dave Thomas | `server.ex` на компонент | отдельный app | — |

Таблица C — принуждение, compile-time, тесты.

| Подход | К7 принуждение | К8 compile-time | К9 тесты |
|---|---|---|---|
| Phoenix contexts | нет | — | DataCase на контекст |
| Halvorsen | граница Mix-проекта | как path-deps | ядро без HTTP |
| Jurić + Boundary | компилятор `:boundary` + CI | не снижает; проверка ~1 с | через интерфейс |
| DESO / FC-IS | нет | — | ядро; граница как user |
| Hexagonal | `@behaviour`/`@impl` | runtime-резолв (вывод) | Mox async; интеграция |
| Commanded | нет | макросы роутера | given/when/then; wait |
| Ash | verifiers DSL | Spark; циклы (issue) | code interface |
| Umbrella | deps + warning ≥1.11 | export-deps ≥1.11 | по app |
| Poncho | deps Mix | как path-deps | по проекту |
| Один OTP-app | нет; xref/линтер | xref | общий `test/` |
| VSA | нет | — | на срез |
| Clean | нет | — | — |
| DDD | нет | — | — |
| Dave Thomas | path-deps | как path-deps | `impl` напрямую |

Таблица D — стоимость и провалы (К10), как их называют сами источники.

| Подход | К10 |
|---|---|
| Phoenix contexts | «large contexts of loosely related entities»; «one large context» |
| Halvorsen | учебный масштаб; БД не рассмотрена |
| Jurić + Boundary | опыт на ~100 модулях; тесты через интерфейс «doesn't scale well with the number of tests» |
| DESO / FC-IS | слои выбирать «worth the price»; масштаб не обсуждается |
| Hexagonal | «too many boundaries … too many moving parts» |
| Commanded | каскад остановок хендлеров; события хранят «poor design decisions» |
| Ash | кривая обучения; «isn't a fit for every … project» |
| Umbrella | общий конфиг и версии; «grown beyond what umbrellas can provide» |
| Poncho | ручная сборка конфигов |
| Один OTP-app | границы только соглашением (все 4 живых приложения) |
| VSA | нужна культура рефакторинга |
| Clean, DDD | — |
| Dave Thomas | цена отдельных проектов |

## Совместимость элементов

Элементы, которые можно брать из разных подходов:

- **Э1** — модуль-фасад контекста (Phoenix).
- **Э2** — граница `deps`/`exports` с проверкой компилятором (Boundary).
- **Э3** — разделение core и interface (Jurić).
- **Э4** — functional core / imperative shell (DESO, Bernhardt, wiki Commanded).
- **Э5** — порт = behaviour + реализация из конфигурации (Cockburn, Valim, Mox).
- **Э6** — CQRS: write-агрегаты плюс read-проекции (Commanded, DDD, VSA).
- **Э7** — связь контекстов событиями: handler или process manager (Commanded, DDD).
- **Э8** — прямой вызов фасада чужого контекста (Phoenix, Jurić).
- **Э9** — физическое разделение: umbrella, poncho, компоненты Dave Thomas.
- **Э10** — вертикальный срез на запрос (Bogard).
- **Э11** — ресурсы и actions на DSL (Ash).
- **Э12** — Dependency Rule (Martin).
- **Э13** — схемы как отдельная граница (`XyzSchemas`) и sink-граница инфраструктуры (`Xyz.Infra`) (Jurić).

### Сочетаются

- **Э2 поверх Э1.** README Boundary строит пример на Phoenix-паре `MySystem` / `MySystemWeb` [BND]. У Jurić
  контексты — core под Boundary [TME2, TME3]. Фасад контекста становится корнем границы, внутренние модули —
  неэкспортируемыми. Ограничение: длинные exports Boundary считает признаком фрагментации [BND-DOC].
- **Э4 внутри Э1.** Commanded прямо рекомендует чистые агрегаты и PM, а эффекты — в handlers [CMD-FCIS]. Фасад
  контекста играет роль imperative shell, decide/evolve — functional core (вывод).
  Терминологическая ловушка: «core» у Jurić включает персистентность и сторонние сервисы [TME2], а у DESO и
  Bernhardt — нет [DES2, GB2]. Это разные слои с одним словом.
- **Э5 только на внешних системах.** Valim: не прятать за контрактом модули уровня `URI`/`Enum`, прятать
  «something as complex as an external API» [JV1]. Jurić держит двойники в основном для «a remote service»
  [TME5]. Живые приложения ставят behaviour на биллинг, хранилище, CDN, HTTP-клиент (hexpm, Plausible), а не
  на свой Repo (§11). Расхождение: Cockburn считает БД портом с mock-адаптером [AC1], а Valim пишет, что моки
  БД делают набор тестов «more fragile» [JV1].
- **Э5 как инструмент Э12.** Инверсия Martin через «interfaces» [RM] в Elixir — behaviour. Пример — Jurić:
  `MySystem.UrlProvider` с реализацией в web [TME2].
- **Э3 и primary-адаптеры (Э5).** Критерий Jurić «If some problem is protocol-specific, then it is an interface
  concern» [TME2] совпадает с primary-адаптерами Cockburn [AC1]. Вывод: подписчик брокера и воркер по этому
  критерию попадают в interface, хотя сам Jurić перечисляет только REST, GraphQL и WebSocket.
- **Э13 (`Xyz.Infra`) и Э5.** Обе изолируют инфраструктуру. Jurić делает это границей-«sink» без абстракции:
  снаружи core Repo и AWS-клиент недоступны [TME3]. Hexagonal делает это портом-behaviour [AC1, JV1]. Вывод:
  совмещаются — граница закрывает доступ, behaviour ставится только там, где нужна подмена.
- **Э6 внутри Э1.** Conduit: фасад контекста шлёт команду и читает проекцию [CDT]. Read-модель живёт в
  каталоге того же контекста (`projections/`, `projectors/`, `queries/`).
- **Э7 и Э2.** Совместимы с ценой: модуль события контекста A становится частью его публичного API, раз
  handler контекста B на него матчится (вывод; в Conduit `Blog.Workflows` использует
  `Accounts.Events.UserRegistered` [CDT]). Под Boundary это выглядит так: `deps: [Accounts]` и события в
  `exports`.
- **Э2 вместо Э9.** Jurić: «single project + boundary» даёт то же, что umbrella без раздельного деплоя
  [SJ-F1]. Mix.Project сам описывает откат umbrella в один проект [MIX-P].
- **Outbox-подобные эффекты.** Источники сходятся на одном: эффект фиксируется в той же транзакции, что и
  изменение.
  - Jurić — Oban-задача внутри `Repo.transact` [TME2].
  - Ash — «commit a "job" in the same transaction as your changes» [ASH-NOT].
  - Richardson — outbox [CR-OB].
  - Commanded вместо этого опирается на at-least-once подписки event store и идемпотентность [CMD-EV].
- **Процессы в любой единице.** Язык [AP-P], Jurić [SJ-SPAWN] и DESO [DES1] одинаково считают процесс
  runtime-решением внутри единицы, а не единицей модульности. С любой схемой модульности это совместимо.

### Конфликтуют или требуют выбора

- **Э1/Э8 (Phoenix, Jurić) против DDD (bounded context, агрегат).**
  - Phoenix сознательно связывает данные контекстов через `belongs_to`/join [PX4]. Jurić: «Phoenix contexts are
    not DDD bounded contexts… it's fine for multiple contexts to use the same tables» [SJ-F4].
  - DDD: границы проводятся вплоть до «code bases and database schemas» [EE-REF]. Vernon: «Reference Other
    Aggregates By Identity», один агрегат на транзакцию [VV-EAD].
  - Phoenix при этом ведёт транзакцию через два контекста [PX5]. Это прямо противоречит правилу Vernon.
- **Changeset как контракт.**
  - Phoenix: changeset — «a good choice» между контекстом и web [PX6].
  - Jurić: changeset только в error-ветке, сигнатуры узкие (`register(email, password)`): «Broad types, such as
    map and any, are treated as code smells» [TME2].
  - Martin: через границу — «isolated, simple, data structures» [RM].
  Три несовместимых ответа на вопрос о типе на границе.
- **Э10 против Э1/Э2.**
  - Bogard отвергает общие абстракции слоя: «repositories, services, controllers» [JB].
  - Jurić: «One context per operation, with a generic call function is not something I'd do» [SJ-F5]; против
    «a huge amount of micro-modules» [SJ-F5].
  - Commanded устроен как generic dispatch структур-команд через роутер [CMD-CMD] — по форме ближе к срезам.
  Если брать срезы, то внутри контекста, а не вместо него (вывод).
- **Э11 против внешней ES-библиотеки.** Ash владеет транзакцией action и data layer. Notifiers гарантируют
  «at most once» [ASH-NOT]. ES в Ash — обёртка над actions с replay в те же ресурсы [ASH-EV]. Вывод: агрегаты
  decide/evolve с собственным хранилищем событий дублировали бы модель Ash. Из Ash переносимы идеи (code
  interface как контракт домена, хуки до и после транзакции), а не механизм.
- **Э13 (`XyzSchemas`) против Э1.**
  - Phoenix кладёт схемы в каталог своего контекста (`lib/hello/catalog/product.ex`) [PX2].
  - Jurić собирает все схемы в отдельную границу верхнего уровня, которой запрещено зависеть от других [TME3].
  - Boundary допускает третий путь — экспорт схем из контекста как исключение из правила коротких exports
    [BND-DOC].
  Выбор: схема — часть интерфейса контекста или общий слой типов данных.
- **Э9 (umbrella) против единой конфигурации.** Umbrella делит config и deps [MIX-P]. Разная конфигурация
  одной зависимости в разных частях — признак, что umbrella перерос [MIX-P]. Poncho снимает это ценой ручной
  сборки конфигов [NRV].
- **Тесты через интерфейс против изолированных тестов ядра.**
  - Jurić по умолчанию тестирует через interface [TME5].
  - Bernhardt и DESO тестируют ядро изолированно, без двойников [GB2, DES1].
  - Commanded тестирует агрегат как given/when/then [CDT].
  Это не взаимоисключение, а выбор уровня по умолчанию. Jurić сам оговаривает плохое масштабирование по числу
  тестов [TME5].
- **Phoenix PubSub broadcast из контекста против событий как интеграции.** В гайде broadcast — уведомление
  LiveView [PX4]; в Livebook на рассылки доменных модулей подписываются web-модули (§11). Commanded и DDD
  используют доменные события для согласования [CMD-EV, EE-REF]. Смешивать роли в одном механизме источники
  не предлагают.

## Открытые вопросы

Чего первоисточники не решают:

1. **Гранулярность на ~800 модулях.**
   - Ни один источник не даёт числа контекстов или границ для такого объёма.
   - Опыт Jurić — около 100 модулей [TME3]. Данные Boundary о проекте с 7k+ файлов касаются только скорости
     проверки [BND-CL]. Phoenix ограничивается советом «prefer separate modules» [PX3].
2. **Место ES-агрегата относительно контекста.**
   - Conduit кладёт агрегаты внутрь каталога контекста [CDT], DDD — внутрь bounded context [EE-REF].
   - Сколько агрегатов на контекст и всегда ли агрегат — подграница, источники не говорят.
3. **Владелец read-модели, которая читает события нескольких контекстов.**
   - Conduit держит проекцию в каталоге контекста-источника [CDT].
   - Для проекции, собранной из событий двух контекстов, ответа нет ни у Commanded, ни у Boundary.
4. **События как публичный API между контекстами одного процесса.**
   - DDD описывает Published Language и ACL между командами и системами [EE-REF]. Commanded даёт upcasting
     событий [CMD-EV].
   - Разделять ли внутренние и внешние события внутри одного сервиса и как их версионировать — не решено.
5. **Входящий подписчик брокера: interface или контекст.**
   - Jurić перечисляет interface как REST/GraphQL/WebSocket [TME2]. Cockburn относит такой вход к primary-
     адаптерам [AC1].
   - Где переводить сообщение в команду и кто владеет идемпотентностью входа, прямо не сказано. Есть только
     требование идемпотентного потребителя у outbox [CR-OB] и `:already_seen_event` у Commanded [CMD-EV].
6. **Compile-time цена DSL-библиотеки в каждом контексте.**
   - Анти-паттерны языка говорят о compile-time зависимостях от макросов [AP-M]. Spark/Ash и Commanded
     отдельно снижали свои [SPARK, CMD-PR547].
   - Измерений для приложения, где сотни модулей делают `use` одной библиотеки с DSL, в источниках нет.
7. **Тип данных на границе.** Changeset, узкие сигнатуры или простые структуры — источники расходятся (см.
   «Конфликтуют»). Влияние вывода типов Elixir 1.19–1.20 на этот выбор ни один архитектурный источник не
   рассматривает.
8. **Схемы и таблицы: общие или свои.**
   - Phoenix и Jurić допускают общие таблицы и схемы как интерфейс контекста [PX4, SJ-F4]. DDD требует
     раздельных моделей [EE-REF].
   - Для ES-системы, где write-модель — события, а read-модель — проекции, вопрос не поставлен.
9. **Постепенное внедрение принуждения в существующий код.**
   - Для Boundary есть только совет из issue (`check: [out: false]` на части пространств) [BND-70].
   - Ни одно из четырёх живых приложений механических границ не держит (кроме CE/EE у Plausible), так что
     опыта внедрения на этом масштабе в выборке нет.
10. **Read-after-write в HTTP поверх eventual-проекций.**
    - Commanded даёт `:strong` и версию-ETAG [CMD-CMD, CMD-RM].
    - Как это совмещается с правилом Vernon о eventual consistency между агрегатами [VV-EAD] и с outbox [CR-OB],
      ни один источник целиком не разбирает.
