# OTP и конкурентность приложения

- **Область.** `lib/my_app_app/application.ex`, объявления контекстов
  `lib/my_app/domain/<bc>/supervision.ex`, корни компонентов `<Component>.Supervisor`,
  периодические процессы, реестры наблюдаемых процессов.
- **Читать перед.** Добавлением процесса в дерево, правкой порядка старта, заведением компонента,
  проекции или процесса агрегата, правкой тумблера и списка наблюдаемых процессов.
- **Словарь.** Плейсхолдеры и модальность — `deps/core/docs/rules/00-index.md`.

Общие нормы BEAM — `init/1` против `handle_continue/2`, таймауты `GenServer.call`, mailbox и
backpressure, `trap_exit`, backoff у периодических циклов — нормирует
`deps/core/docs/rules/17-otp-concurrency.md`. Здесь — дерево приложения и его эксплуатация.

## Дерево процессов

`MyAppApp.Application` — композиционный корень, `strategy: :one_for_one`. В нём MUST быть только:

1. `Core.Config.validate!()` и проверки разделяемой инфраструктуры (`10-architecture.md`,
   «Обязательства перед библиотекой») — **до** подъёма детей: неверная конфигурация роняет старт,
   а не всплывает на первом запросе;
2. инициализация общего состояния без процессов («Состояние без процессов») — там же, до детей;
3. сама разделяемая инфраструктура: PromEx, `DAO`, кластер, PubSub, соединения с брокером,
   планировщик задач `Oban`. Соединение, у которого один пользователь, — не разделяемое: оно
   живёт в корне этого компонента под его тумблером. Тумблер разделяемой инфраструктуры — функция
   её владельца (`MyApp.Mq.Kafka.enabled?/0`): её читают ребёнок `Application`, провайдер
   `watch_list` и компоненты, которым инфраструктура нужна;
4. шаги инициализации, которым нужен процесс дерева («Состояние без процессов»), — сразу после
   этого процесса;
5. корни компонентов («Компонент») и готовые деревья Core с тумблером, которым свой корень не
   нужен («Готовое дерево без корня»), — плоско, списком детей; корни компонентов контекста —
   из `children/0` его объявлений («Объявления контекста»);
6. web и метрики вне дерева компонентов: `MyAppWeb.Telemetry`, сервер метрик
   `MyAppApp.MetricsServer` (`21-observability.md`), `MyAppWeb.Endpoint` — последним.

`strategy: :one_for_one` — и при значимом порядке детей: порядок здесь — только порядок старта.
`rest_for_one` из общего правила (`deps/core/docs/rules/17-otp-concurrency.md`, «Дерево
процессов») относится к поддереву с внутренней зависимостью; у корня приложения он каскадом
перезапускал бы всё после упавшего ребёнка, вплоть до `Endpoint`, из-за сбоя одного компонента.

Процесс компонента отдельным ребёнком `Application` и проверка старта компонента в `start/2` —
MUST NOT: тумблер, опции и наблюдение компонента расходятся по двум местам, и `Application`
начинает знать его внутренности. Корень над корнями компонентов (`MyApp.Domain.<BC>.Supervisor`
на контекст) — MUST NOT: порядок старта глобальный и виден только в `Application`, а лишний
уровень перезапуска ни одной зависимости не упорядочивает.

Порядок детей значим — зависимости идут раньше потребителей:

1. сбор метрик и сервер метрик — раньше всех: PromEx ловит init-события детей
   (`[:ecto, :repo, :init]` у `PromEx.Plugins.Ecto`), а опрос БД плагинами `Core.*.PromEx`
   до старта пула пропускает цикл (`Core.PromEx.Safe`), а не роняет процесс;
2. пул БД — раньше всех, кто в неё ходит;
3. кластеризация и внутренняя шина;
4. соединение с брокером — раньше подписчиков и очереди;
5. планировщик фоновых задач — разделяемая инфраструктура: раньше компонентов, которые ставят
   задачи;
6. очередь, дерево проекций, процессы агрегатов, затем компоненты подсистем, дети контекстов и
   компоненты границы входа `MyAppIngest` — граница после тех, от кого она зависит: дети
   контекстов в порядке `MyAppApp.contexts/0`, а внутри `children/0` контекста кеш read-модели с
   его инвалидатором — раньше прочих компонентов контекста;
7. HTTP-эндпоинт — последним: он поднимается, когда зависимости готовы.

Кеш контекста поднимается после планировщика: задача, взятая в первые мгновения старта, может не
застать кеш и уйдёт в повтор планировщика. Порядок по контекстам держит `contexts/0`, а не
склейка: компонент контекста стартует после детей контекстов, от которых тот зависит.

```elixir
# плохо — кеш рядом с супервизором своего инвалидатора, проверка компонента в start/2
def start(_type, _args) do
  Core.Config.validate!()
  Core.Outbox.check_singleton!(outbox_opts)

  children = [
    MyAppApp.PromEx,
    MyApp.Infra.DAO,
    {Cachex, name: MyApp.Domain.<BC>.<ReadModel>.ReadRepo.Cache},
    MyApp.Domain.<BC>.<ReadModel>.ReadRepo.Supervisor,
    MyAppWeb.Endpoint
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyAppApp.Supervisor)
end

# хорошо — разделяемая инфраструктура и корни компонентов плоско, дети контекстов — из объявлений
def start(_type, _args) do
  Core.Config.validate!()
  Core.Mq.Stream.ensure_available!()

  children =
    [
      MyAppApp.PromEx,
      MyApp.Infra.DAO,
      {Phoenix.PubSub, name: MyApp.PubSub},
      MyApp.Mq.Connection,
      {Oban, Application.fetch_env!(:my_app, Oban)},
      MyAppApp.Outbox.Supervisor,
      {Core.Es.Projection.Supervisor, projection_opts()}
    ] ++
      Enum.map(processes(), &{&1, process_opts(&1)}) ++
      [MyApp.<Subsystem>.Supervisor] ++
      Enum.flat_map(MyAppApp.contexts(), & &1.children()) ++
      [MyAppIngest.<Source>.Supervisor, MyAppWeb.Endpoint]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyAppApp.Supervisor)
end
```

Поддерево с внутренним порядком запуска (writer → поллер → cleaner) — собственный `Supervisor`
со `strategy: :rest_for_one` (`deps/core/docs/rules/17-otp-concurrency.md`, «Дерево процессов»).

Поддерево подписчиков брокера MUST строиться деревом библиотеки
`Core.PubSub.MqSubscriberReliable.Supervisor`, а не своим супервизором: порядок детей — свой
DLQ-writer (`14-events-outbox.md`, «Подписчики»), затем на каждый топик
`Core.Mq.Stream.Reader` и его `MqSubscriberReliable` — держится построением, а подписчик подписан
сразу после `init/1`. Копия супервизора в каждом компоненте расходится с остальными по порядку
детей и по семантике отказа подписки: сбой процесса-bootstrap, записанный в лог с нормальным
выходом, оставляет читателя и подписчика живыми — `WorkerDown` молчит, а сообщения не читаются.

```elixir
# плохо — свой супервизор: порядок детей и связки опций в каждом компоненте свои
children = [dlq_writer, reader, subscriber, {<Component>.Subscribe, subscribers: [subscriber]}]
Supervisor.init(children, strategy: :rest_for_one)

# хорошо — дерево библиотеки внутри корня компонента: тумблер у корня, дереву — enabled: true
{Core.PubSub.MqSubscriberReliable.Supervisor,
 enabled: true,
 component: "<component>",
 dlq_writer: {Core.Mq.Stream.Writer, dlq_opts},
 topics: [[reader: {Core.Mq.Stream.Reader, reader_opts}, subscriber: subscriber_opts]]}
```

### Состояние без процессов

Общее состояние, которое собирается один раз на старте и живёт без процессов (реестр из
деклараций кода в `:persistent_term`), — не компонент: тумблера, процессов и `watch_list` у него
нет, и корень компонента для него был бы супервизором без детей. Его инициализация MUST быть одним
вызовом функции владельца в `start/2` до подъёма дерева, рядом с `Core.Config.validate!()`:
ошибка сборки роняет старт, а не всплывает на первом запросе.

Если инициализации нужен процесс дерева (чтение из БД), `start/2` для неё рано: она MUST быть
ребёнком `Application` сразу после этого процесса, чей `start` выполняет загрузку и отдаёт
`:ignore` — процесса нет, а порядок держит дерево.

```elixir
def start(_type, _args) do
  Core.Config.validate!()
  MyApp.<Subsystem>.Registry.load!()
  ...
end

# нужен процесс дерева — шаг после него, без процесса
children = [MyApp.Infra.DAO, %{id: MyApp.<Subsystem>.Catalog, start: {MyApp.<Subsystem>.Catalog, :load, []}}, ...]
```

## Компонент

Компонент — процессы с одним назначением: они включаются, выключаются и наблюдаются целиком.
Первичный признак компонента — назначение; тумблер у него MAY быть. Всё, что включается вместе,
MUST жить под одним корнем `<Component>.Supervisor`; процессы с разными тумблерами — разные
компоненты, кроме части с подчинённым тумблером («Подчинённый тумблер»). Это ограничение, а не
правило склейки: всегда включённые процессы разного назначения — разные компоненты.

Корень компонента MUST сам владеть:

- тумблером: выключенный компонент отдаёт `:ignore` из `start_link/1` и пишет причину на `info`
  («Тумблер компонента»);
- сборкой опций своих процессов из конфигурации («Опции процессов»);
- проверками старта своего компонента — единственность на кластере, доступность клиента внешнего
  сервиса: проверка живёт рядом с тем, что защищает. Клиент брокера —
  разделяемая инфраструктура, его проверяет `Application`;
- `watch_list/0` — своими процессами, отфильтрованными **тем же** тумблером, что и старт
  («Наблюдение за процессами»); дерево библиотеки внутри корня входит в него своим `watch_list/1`
  с теми же опциями, что и его старт. Если внутри есть дерево подписчиков — так же `readers/0`
  из его `readers/1`: дереву передаётся `enabled: true` (или подчинённый тумблер), и отфильтровать
  список тумблером корня может только корень.

```elixir
defmodule MyApp.<Subsystem>.Supervisor do
  use Supervisor

  require Logger

  def start_link(_arg) do
    opts = opts()

    case Keyword.fetch!(opts, :enabled) do
      false ->
        Logger.info("<subsystem>: отключён")
        :ignore

      true ->
        MyApp.<Subsystem>.Client.ensure_available!(opts)
        Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  def watch_list do
    case Keyword.fetch!(opts(), :enabled) do
      false -> []
      true -> [%{component: "<subsystem>", name: MyApp.<Subsystem>.Worker}]
    end
  end

  @impl true
  def init(opts), do: Supervisor.init([{MyApp.<Subsystem>.Worker, opts}], strategy: :one_for_one)

  # ---

  defp opts, do: Application.fetch_env!(:my_app, __MODULE__)
end
```

### Готовое дерево без корня

Компонент, который целиком — готовое дерево Core с тумблером (`enabled:` → `:ignore` с `info`) и
`watch_list/1`, MAY стоять в `Application` без своего корня: корень повторил бы тумблер и
`watch_list`, которые у дерева уже есть. Таковы `Core.Es.Projection.Supervisor` и
`<Aggregate>.Process`. Опции и тумблер MUST собирать одна функция приложения из
`config/runtime.exs` — `projection_opts/0`, `process_opts/1` корня («Проекции и процессы
агрегата»), — а `watch_list/1` дерева MUST входить в склейку («Наблюдение за процессами»).

Дерево сторонней библиотеки без этих контрактов (`Oban`) — разделяемая инфраструктура: оно
включается своими опциями (`queues:`, `plugins:`, `testing:`), а его супервизор перечисляет
провайдер `watch_list` среди элементов инфраструктуры.

- Тестовый дублёр процесса (хранилище в памяти вместо внешнего) стоит в дереве тем же ребёнком и
  под тем же тумблером, что и реализация, которую он заменяет.

### Подчинённый тумблер

Часть компонента, без которой он работает в ослабленном режиме, MAY иметь свой тумблер внутри
корня: кеш read-модели без инвалидатора работает на одном TTL (`16-caching.md`). Корень
остаётся один: кеш стоит всегда, дереву подписчиков передаётся `enabled:` подчинённого тумблера.
Элементы подчинённой части в `watch_list/0` и `readers/0` корня фильтруются подчинённым тумблером,
элементы кеша — только тумблером корня. Процессы, которые нельзя выключить
независимо, — одна часть без своего тумблера.

### Место компонента

Компонент — единица раскладки: каталог компонента с корнем `supervisor.ex` и процессами компонента
рядом. Каталог MUST лежать у исполнителя: реакция на доменное событие — рядом с usecases, которые
она зовёт, а не у производителя события; вход внешней системы — в границе входа, как web;
компонент без вызовов usecases — по назначению:

| Компонент | Где лежит |
|---|---|
| реакция на доменное событие — подписчик топика своего приложения, зовёт usecases одного агрегата | реагирующий контекст, каталог агрегата, чей usecase зовёт: `lib/my_app/domain/<bc>/<aggregate>/<component>/` |
| реакция, которая зовёт usecases нескольких агрегатов | реагирующий контекст, `lib/my_app/domain/<bc>/reactions/<component>/` |
| кеш read-модели и его инвалидатор | каталог read-модели, `<read_model>/read_repo/supervisor.ex` (`16-caching.md`) |
| вход внешней системы: подписчик её брокера, разбор её формата, DLQ отклонённого | граница входа `MyAppIngest`, `lib/my_app_ingest/<source>/` (`10-architecture.md`, «Boundary») |
| usecases не зовёт: клиент внешнего сервиса, реестр, техническое состояние без версии и событий (сессии, журнал прогонов) | подсистема `MyApp.<Subsystem>` — своя граница (`10-architecture.md`, «Состав контекста») |
| очередь outbox | корень, `MyAppApp.Outbox` (`10-architecture.md`, «Корень и сток») |

- Компонент контекста MUST NOT звать изменяющие usecases другого контекста: его место — у того
  контекста, реакцией или воркером (`10-architecture.md`, «Usecases»). События производителя
  реакция видит через его `exports`, а производитель о ней не знает.
- Разбор формата внешней системы и DLQ отклонённого MUST лежать в границе входа, а не в
  контексте: контекст получает уже доменные значения вызовом своего экспортированного usecase.
  Вход, который пишет несколько контекстов, зовёт usecases каждого.
- Воркер фоновой задачи — не компонент: его место — «Фоновые задания».

Почему у исполнителя, а не у инициатора, и почему вход — своя граница —
`deps/core/docs/adr/0040-component-at-executor.md`.

```text
# плохо — реакция контекста Billing на событие заказа лежит у производителя и зовёт usecases Billing
lib/my_app/domain/orders/order/invoicing/supervisor.ex
# плохо — разбор топика внешней системы и его DLQ в контексте, чьи usecases он зовёт
lib/my_app/domain/billing/invoice/<source>_feed/supervisor.ex

# хорошо — реакция у реагирующего, рядом с usecases, которые зовёт; вход — своя граница
lib/my_app/domain/billing/invoice/order_events/supervisor.ex
lib/my_app_ingest/<source>/supervisor.ex
```

## Объявления контекста

Контекст сам объявляет то, что поднимает и наблюдает корень: модуль объявлений
`MyApp.Domain.<BC>.Supervision` (`lib/my_app/domain/<bc>/supervision.ex`) отдаёт списки его части,
а `MyAppApp.Application` склеивает их по списку `MyAppApp.contexts/0`. Новая проекция, процесс
или компонент правят свой контекст, а не центральный список. Модуль объявлений — не супервизор:
процессов он не поднимает.

| Функция `<BC>.Supervision` | Что отдаёт | Кто склеивает |
|---|---|---|
| `projections/0` | модули проекций | `projection_opts/0` корня («Проекции и процессы агрегата») |
| `processes/0` | модули процессов агрегатов | `processes/0` корня |
| `children/0` | корни компонентов контекста в порядке старта | `start/2` («Дерево процессов») |
| `watch_list/0` | `watch_list/0` тех же корней | `watch_list/0` корня («Наблюдение за процессами») |
| `readers/0`, `kafka_readers/0` | читатели деревьев подписчиков контекста | провайдеры `readers:` и `kafka_readers:` плагина `Core.Mq.PromEx` |
| `caches/0` | кеши контекста под наблюдением | провайдер `sizes:` плагина `Core.Cache.PromEx` |

- Контекст MUST объявлять четыре первые функции, а `readers/0`, `kafka_readers/0` и `caches/0` —
  если приложение подключает плагин с этим провайдером; пустая часть — пустой список: корень
  зовёт функции у каждого контекста, не разбирая, что в нём есть.
- Объявления MUST лежать в `<BC>.Supervision`, а не в оглавлении: фасад кодека зависит от
  оглавления на компиляции (`codec_plugins/0`, `11-domain.md`, «Фасады и реестр плагинов»), а
  объявления ссылаются на проекции и корни компонентов, которые зовут фасад, — правка любого
  модуля контекста пересобирала бы фасад. Контекст экспортирует `Supervision` (`10-architecture.md`,
  «Boundary»): корень видит контекст только через его `exports`, а корни компонентов в них не
  входят.
- Детей контекст MUST отдавать списком, а не своим супервизором («Дерево процессов»).
- `children/0` и `watch_list/0` MUST перечислять одни и те же корни: компонент без строки в
  `watch_list/0` падает молча («Наблюдение за процессами»).
- `MyAppApp.contexts/0` MUST перечислять модули объявлений контекстов в порядке зависимостей —
  контекст после тех, от кого он зависит: этот порядок задаёт старт детей контекстов.

```elixir
# lib/my_app/domain/orders/supervision.ex — объявления контекста для корня
defmodule MyApp.Domain.Orders.Supervision do
  alias MyApp.Domain.Orders.Order

  def projections, do: [Order.Projection, <ReadModel>.Projection]
  def processes, do: [Order.Process]
  def children, do: [<ReadModel>.ReadRepo.Supervisor]
  def watch_list, do: <ReadModel>.ReadRepo.Supervisor.watch_list()
end

# lib/my_app_app.ex — корень: контексты в порядке зависимостей
defmodule MyAppApp do
  use Boundary,
    deps: [MyApp.Domain.Billing, MyApp.Domain.Orders, MyApp.Infra, MyAppWeb, MyAppIngest]

  def contexts, do: [MyApp.Domain.Billing.Supervision, MyApp.Domain.Orders.Supervision]
end
```

## Тумблер компонента

Компонент, который можно выключить, отдаёт `:ignore` из `start_link/1` и пишет причину на
`info` — «запущено» / «отключено» / «пропущено: нет зависимости»
(`deps/core/docs/rules/17-otp-concurrency.md`, «Дерево процессов»): приложение обязано стартовать
без него, а молча отсутствующее поддерево не отличить от упавшего.

- Третий случай — компоненту нечего запускать: `Core.Es.Projection.Supervisor` при
  `projections: []` отдаёт `:ignore` с `info` «пропущен: нет проекций». Недоступная внешняя
  система к нему не относится: подключение идёт в `handle_continue/2` с backoff
  (`deps/core/docs/rules/17-otp-concurrency.md`, «`init/1`»).
- Тумблер компонента и его значения из env (tunables очереди, проекций, кеша) живут **только** в
  `config/runtime.exs`; дублировать их в `config.exs` MUST NOT: у значения появились бы два
  источника, и они разойдутся.
- Тумблер читается из того же ключа, что и остальная конфигурация компонента: тумблеры
  приложения — под `:my_app`, тумблер очереди — под `:core`. Расхождение даёт дерево, которое
  считает выключенное включённым.
- Каждый отключаемый компонент MUST иметь записанную цену: что именно перестаёт работать.

## Опции процессов

Опции приходят из `config/runtime.exs` через корень компонента и разбираются в `init/1`
(`Core.Helper.StartOpts`).

- Опция, дефолт которой задаёт `runtime.exs`, объявляется обязательной **без** дефолта в
  модуле: иначе у значения два источника, и они разойдутся.
- Отсутствие ловит `Keyword.fetch!`, недопустимое значение — явный отказ старта, а не
  молчаливое усечение.
- Список, который собирает несколько компонентов (проекции, топики, наблюдаемые процессы), MUST
  собираться **одной** функцией приложения: вторая сборка в другом месте старта разошлась бы с
  первой молча. Пример — «Проекции и процессы агрегата».

## Проекции и процессы агрегата

Контракт дерева проекций — один `Core.Es.Projection.Supervisor` на все проекции и все ноды,
отказы старта, семантика `notifications:` — `deps/core/docs/rules/22-projections.md`, «Дерево».
Config и env библиотека не читает.

- Список проекций и опции MUST собирать одна функция приложения —
  `MyAppApp.Application.projection_opts/0` из `projections/0` объявлений контекстов («Объявления
  контекста»): её же принимают `Core.Es.Projection.Supervisor.watch_list/1` и PromEx-плагин
  (`21-observability.md`). Вторая сборка разошлась бы со списком, который видят `await` и метрики.
- Опции дерева MUST лежать под ключом `config :my_app, Core.Es.Projection.Supervisor`, как опции
  процесса агрегата — под ключом его модуля: ключ называет то, что настраивается.
- Опции приходят из env `ES_PROJECTIONS_*` в `config/runtime.exs`, длительности — через
  `Core.DurationParser`.
- Приложение на одной ноде SHOULD ставить `notifications: false`: сигнала внутри ноды хватает;
  за пулером в transaction mode — keyword с прямым хостом базы.
- Лимиты соединений базы и пулера MUST считаться с учётом слушателей: по соединению на каждый
  различный `repo:` проекций на каждой ноде, сверх `pool_size`.
- Цена выключения дерева (`ES_PROJECTIONS_ENABLED=false`) — read-модель не обновляется: экраны
  отстают, а команды на границе отвечают 202 (`15-web-api.md`).

```elixir
# плохо — список и опции собраны на месте старта: await и метрики видят другой список
{Core.Es.Projection.Supervisor,
 projections: [MyApp.Domain.<BC>.<ReadModel>.Projection], enabled: true}

# хорошо — одна функция корня; её же читают watch_list/1 и Core.Es.PromEx
def projection_opts do
  [projections: Enum.flat_map(MyAppApp.contexts(), & &1.projections())] ++
    Application.fetch_env!(:my_app, Core.Es.Projection.Supervisor)
end

children = [{Core.Es.Projection.Supervisor, projection_opts()}]

# config/runtime.exs
config :my_app, Core.Es.Projection.Supervisor,
  enabled: System.get_env("ES_PROJECTIONS_ENABLED", "true") == "true",
  poll_interval_ms:
    Core.DurationParser.to_timeout!(System.get_env("ES_PROJECTIONS_POLL_INTERVAL", "1s")),
  await_min_ms:
    Core.DurationParser.to_timeout!(System.get_env("ES_PROJECTIONS_AWAIT_MIN", "10ms")),
  await_max_ms:
    Core.DurationParser.to_timeout!(System.get_env("ES_PROJECTIONS_AWAIT_MAX", "100ms")),
  notifications: System.get_env("ES_PROJECTIONS_NOTIFICATIONS", "true") == "true"

# хорошо — одна нода: сигнала внутри ноды хватает, NOTIFY пачек не нужен
config :my_app, Core.Es.Projection.Supervisor, notifications: false
```

```text
# плохо — лимит соединений посчитан по пулам repo: соединения слушателей нод в него не входят
max_connections >= ноды × pool_size

# хорошо — плюс по соединению слушателя на каждый различный repo: проекций на каждой ноде
max_connections >= ноды × (pool_size + различных repo: проекций)
```

Процесс агрегата ставится в дерево элементом
`{<Aggregate>.Process, process_opts(<Aggregate>.Process)}` (`13-repos.md`, «Процесс агрегата») —
готовое дерево без корня. Список процессов и их опции MUST собирать `MyAppApp.Application`:
`processes/0` — модули процессов из `processes/0` объявлений контекстов, `process_opts/1` —
опции процесса из `config/runtime.exs`. Их же читают `<Aggregate>.Process.watch_list/1` в склейке
(«Наблюдение за процессами») и `processes:` плагина `Core.Es.PromEx` (`21-observability.md`):
вторая сборка разошлась бы с деревом.

```elixir
def processes, do: Enum.flat_map(MyAppApp.contexts(), & &1.processes())
def process_opts(process), do: Application.fetch_env!(:my_app, process)

children = [MyApp.Infra.DAO | Enum.map(processes(), &{&1, process_opts(&1)})]
```
 При `enabled: false`
команда идёт тем же путём, но без процесса на id: выключенное дерево не ломает команды, а
только снимает процесс на id.

## Наблюдение за процессами

Каждый критичный именованный процесс MUST быть в `watch_list/0` своего компонента — по нему
работает алерт на падение (`21-observability.md`). `watch_list/0` приложения —
`MyAppApp.Application.watch_list/0`, провайдер плагина `Core.Workers.PromEx` — MUST быть
конкатенацией `watch_list/0` объявлений контекстов, списков остальных компонентов и готовых
деревьев и своих элементов только для разделяемой инфраструктуры — детей, которых `Application`
перечисляет сам (соединение с брокером, `Oban`), под тумблерами их владельцев. Список живёт рядом
с детьми, которых наблюдает: `Application` и `PromEx` — модули одной границы корня
(`10-architecture.md`, «Boundary»).

- Новый именованный процесс, чьё падение меняет поведение системы, MUST попадать в
  `watch_list/0` компонента **той же правкой**, что и в дерево: процесс без наблюдения падает
  молча.
- Список компонента фильтруется его корнем по **текущей** конфигурации — тем же тумблером, что и
  старт: элемент выключенного компонента дал бы вечный алерт «процесс отсутствует»
  (`deps/core/docs/rules/17-otp-concurrency.md`, «Дерево процессов»). Вычислять тумблер компонента
  второй раз в реестре приложения MUST NOT: у тумблера два места, и они расходятся молча.
- Имя процесса берётся у его владельца (функция супервизора, `cache/0` фасада), а не
  повторяется литералом в двух местах. `name:` элемента `watch_list/0` — `GenServer.name()`: атом,
  `{:global, _}` или `{:via, _, _}`; процесс под реестром (`Oban` — `Oban.Registry`) ставится под
  наблюдение тем же элементом, имя отдаёт реестр (`Oban.Registry.via/1`).
- Читателей проекций перечисляет само дерево (`Core.Es.Projection.Supervisor.watch_list/1`), а не
  третий список в реестре приложения: иначе он разойдётся с деревом молча.
- Stream-читателей для `readers:` и читателей Kafka для `kafka_readers:` плагина `Core.Mq.PromEx`
  MUST перечислять деревья подписчиков (`Core.PubSub.MqSubscriberReliable.Supervisor.readers/1` и
  `kafka_readers/1` с опциями старта), а реестр приложения — склеивать их, как `watch_list/0`:
  своя метка у читателя дала бы одному процессу две разные `component` в `workers_up` и
  `mq_reader_*` / `mq_kafka_reader_*`.
- Метка `component` — стабильная строка, а не имя модуля: перенос компонента между слоями меняет
  модуль, и метка из `inspect(name)` порвала бы ряды метрик и заглушки Alertmanager по
  `component`. У дерева подписчиков её задаёт опция `component:`.
- Метка MUST быть уникальна в склеенном списке: `Core.Workers.PromEx` и `Core.Mq.PromEx` сводят
  элементы с одной меткой (`up` и `subscribed` — минимум) и пишут `error` в лог, но по сведённому
  значению не видно, какой из процессов упал.

```elixir
# плохо — реестр повторяет тумблеры и имена процессов компонентов
def watch_list do
  if Application.fetch_env!(:my_app, MyApp.<Subsystem>.Supervisor)[:enabled],
    do: [%{component: "<subsystem>", name: MyApp.<Subsystem>.Worker}],
    else: []
end

# хорошо — конкатенация списков, каждый отфильтрован своим корнем
def watch_list do
  [%{component: "mq_connection", name: MyApp.Mq.Connection}] ++
    [%{component: "oban", name: Oban.Registry.via(Oban)}] ++
    MyAppApp.Outbox.Supervisor.watch_list() ++
    MyApp.<Subsystem>.Supervisor.watch_list() ++
    Enum.flat_map(MyAppApp.contexts(), & &1.watch_list()) ++
    MyAppIngest.<Source>.Supervisor.watch_list() ++
    Core.Es.Projection.Supervisor.watch_list(projection_opts()) ++
    Enum.flat_map(processes(), &(&1.watch_list(process_opts(&1))))
end
```

Проверяется: ратчет состава `watch_list/0` под тумблерами (`19-testing.md`).

## Периодические циклы

- В полёте MUST быть ровно один таймер: перед постановкой нового прежний отменяется — иначе
  тики накапливаются на время долгого цикла. Накопившиеся тики схлопываются.
- Сбой цикла уходит в backoff — `deps/core/docs/rules/17-otp-concurrency.md`, «Backoff у
  периодических циклов».
- Цикл, который ставит фоновую задачу, MUST полагаться на её ключ идемпотентности, а не на то,
  что тик не повторится (`14-events-outbox.md`).
- Ошибка недоступной БД MAY прийти как `exit`: цикл MUST его ловить и уходить в backoff, а не
  падать вместе с супервизором.
- Цикл, который нужно прогнать синхронно (тест, оператор), MUST отдавать `run_once/1` с явным
  таймаутом; ожидание таймера в тесте MUST NOT.
- Таймаут `GenServer.call` к процессу цикла — `deps/core/docs/rules/17-otp-concurrency.md`,
  «`GenServer.call`».

## Фоновые задания

- Периодические и отложенные работы с данными — планировщик задач, а не самописный цикл с
  `Process.send_after/3`. Свой цикл («Периодические циклы») — только для локального состояния
  процесса (чистка кеша в памяти): ему не нужны ни персистентность задачи, ни её повтор.
- Модуль воркера `Oban.Worker` — не компонент и не процесс. Он MUST лежать у исполнителя — в
  каталоге агрегата, чей usecase исполняет (`<Aggregate>.<Name>` в `<bc>/<aggregate>/<name>.ex`,
  у операции над равноправными агрегатами — в каталоге операции), а не у того, кто ставит задачу
  (`deps/core/docs/adr/0040-component-at-executor.md`).
- Постановка — функция модуля воркера (`enqueue/N`): вызывающий зовёт её внутри своей
  транзакции, и задача появится только при commit (`10-architecture.md`, «Что можно внутри
  `Transact.run`»). Воркер, которого ставит другой контекст, исполнитель экспортирует
  (`10-architecture.md`, «Boundary»); собирать задачу чужого воркера (`new/1`, `Oban.insert/2`)
  MUST NOT.
- Аргументы функции постановки MUST быть типами исполнителя или типами, которые он уже видит
  через `exports` (ID учётной записи): постановщик зависит от исполнителя, и его тип в сигнатуре
  замкнул бы цикл границ. Исполнителю нужны данные постановщика — это реакция на его событие
  («Место компонента»).
- Задача-следствие — продолжение решения, закоммиченного вызывающим, — MUST исполняться от
  системной учётной записи (`ContextFactory.system/0`), а не от пользователя, который её
  поставил: его права проверены при постановке, а их перепроверка при исполнении отказала бы в
  том, что commit уже обещал.
- Автор решения, если он нужен аудиту, — явный аргумент функции постановки и операции
  исполнителя и поле нагрузки события исполнителя; `by` события — системная учётная запись.
  Функция постановки задачи-следствия MUST NOT принимать `%Context{}`: `args` хранятся в
  `oban_jobs`, и сохраняемое должно быть видно из сигнатуры.
- Отложенная команда пользователя (отправка от его имени по времени, выгрузка его данных) — его
  собственная операция: задача хранит ID пользователя и MUST исполняться от его имени
  (`ContextFactory.as_user/1`) с проверкой прав при исполнении. Её функция постановки MAY брать
  пользователя из `%Context{}`.
- Задача по расписанию лежит так же — в каталоге агрегата, чей usecase исполняет; `crontab`
  планировщика называет модуль её воркера.
- Задача MUST быть идемпотентна по своему ключу (`14-events-outbox.md`) и собирать контекст
  сама (`11-domain.md`).
- Расписание задаётся в `config/runtime.exs` и выключается тумблером.
- Размер пачки — параметр, а не константа в коде: один прогон не должен держать транзакцию на
  произвольном объёме.

Почему задача-следствие исполняется от системы, а автор решения — аргумент, а не контекст, —
`deps/core/docs/adr/0041-consequence-job-runs-as-system.md`.

```elixir
# плохо — воркер контекста Billing лежит у постановщика, и Orders собирает чужую задачу
defmodule MyApp.Domain.Orders.Order.Client.VoidInvoice do
  use Oban.Worker, queue: :billing
end

# плохо — тип постановщика и контекст в функции постановки, исполнение от имени поставившего
def enqueue(%MyApp.Domain.Orders.Order.ID{} = order_id, %Context{} = context), do: ...
def perform(%Oban.Job{args: %{"user_id" => id}} = job), do: void(job, ContextFactory.as_user(id))

# хорошо — воркер у исполнителя, аргументы — его типы, автор решения — аргумент, исполняет система
defmodule MyApp.Domain.Billing.Invoice.Void do
  use Oban.Worker, queue: :billing, unique: [period: :infinity, keys: [:invoice_id]]

  def enqueue(%Invoice.ID{} = id, %User.ID{} = requested_by), do: ...

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"invoice_id" => raw_id, "requested_by" => raw_by}}) do
    with {:ok, id} <- InCodec.load(Invoice.ID, raw_id),
         {:ok, requested_by} <- InCodec.load(User.ID, raw_by),
         {:ok, _} <- Invoice.System.Usecases.void(id, requested_by, ContextFactory.system()),
         do: :ok
  end
end
```

## Связанные правила

- Композиционный корень и boundary — `10-architecture.md`
- Время жизни контекста в процессе — `11-domain.md`
- Очередь, подписчики, порядок доставки — `14-events-outbox.md`
- Кеш и его инвалидация — `16-caching.md`
- Метрики и алерты — `21-observability.md`
- Тесты — `19-testing.md`; тесты процессов — `deps/core/docs/rules/19-testing.md`, «Процессы»
