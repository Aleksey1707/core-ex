# OTP и конкурентность приложения

- **Область.** `lib/my_app/application.ex`, корни компонентов `<Component>.Supervisor`,
  периодические процессы, реестры наблюдаемых процессов.
- **Читать перед.** Добавлением процесса в дерево, правкой порядка старта, заведением компонента,
  правкой его тумблера и списка наблюдаемых процессов.
- **Словарь.** Плейсхолдеры и модальность — `deps/core/docs/rules/00-index.md`.

Общие нормы BEAM — `init/1` против `handle_continue/2`, таймауты `GenServer.call`, mailbox и
backpressure, `trap_exit`, backoff у периодических циклов — нормирует
`deps/core/docs/rules/17-otp-concurrency.md`. Здесь — дерево приложения и его эксплуатация.

## Дерево процессов

`MyApp.Application` — композиционный корень, `strategy: :one_for_one`. В нём MUST быть только:

1. `Core.Config.validate!()` и проверки разделяемой инфраструктуры (`10-architecture.md`,
   «Обязательства перед библиотекой») — **до** подъёма детей: неверная конфигурация роняет старт,
   а не всплывает на первом запросе;
2. сама разделяемая инфраструктура: PromEx, `DAO`, кластер, PubSub, соединения с брокером;
3. корни компонентов («Компонент») — плоско, списком детей.

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
5. компоненты кешей — кеш вместе с его инвалидатором;
6. очередь, проекции, планировщик фоновых задач и остальные компоненты;
7. HTTP-эндпоинт — последним: он поднимается, когда зависимости готовы.

```elixir
# плохо — кеш рядом с супервизором своего инвалидатора, проверка компонента в start/2
def start(_type, _args) do
  Core.Config.validate!()
  MyApp.<Subsystem>.Registry.load!()

  children = [
    MyApp.PromEx,
    MyApp.DAO,
    {Cachex, name: MyApp.Domain.<BC>.Common.<ReadModel>.ReadRepo.Cache},
    MyApp.Domain.<BC>.Common.<ReadModel>.ReadRepo.Supervisor,
    MyAppWeb.Endpoint
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end

# хорошо — разделяемая инфраструктура и корни компонентов плоско
def start(_type, _args) do
  Core.Config.validate!()
  Core.Mq.Stream.ensure_available!()

  children = [
    MyApp.PromEx,
    MyApp.DAO,
    {Phoenix.PubSub, name: MyApp.PubSub},
    MyApp.Mq.Connection,
    MyApp.Domain.<BC>.Common.<ReadModel>.ReadRepo.Supervisor,
    MyApp.Outbox.Supervisor,
    {Core.Es.Projection.Supervisor, MyApp.Projections.opts()},
    MyApp.<Subsystem>.Supervisor,
    MyAppWeb.Endpoint
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
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
children = [dlq_writer, reader, subscriber, {MyApp.Domain.<BC>.System.Subscribe, subscribers: [subscriber]}]
Supervisor.init(children, strategy: :rest_for_one)

# хорошо — дерево библиотеки внутри корня компонента: тумблер у корня, дереву — enabled: true
{Core.PubSub.MqSubscriberReliable.Supervisor,
 enabled: true,
 dlq_writer: {Core.Mq.Stream.Writer, dlq_opts},
 topics: [[reader: {Core.Mq.Stream.Reader, reader_opts}, subscriber: subscriber_opts]]}
```

## Компонент

Компонент — процессы с одним назначением и одним тумблером: они включаются, выключаются и
наблюдаются целиком. Граница компонента — единица тумблера: всё, что включается вместе, MUST
жить под одним корнем `<Component>.Supervisor`; процессы с разными тумблерами — разные
компоненты.

Корень компонента MUST сам владеть:

- тумблером: выключенный компонент отдаёт `:ignore` из `start_link/1` и пишет причину на `info`
  («Тумблер компонента»);
- сборкой опций своих процессов из конфигурации («Опции процессов»);
- проверками старта своего компонента — единственность на кластере, загрузка реестра,
  доступность клиента внешнего сервиса: проверка живёт рядом с тем, что защищает. Клиент брокера —
  разделяемая инфраструктура, его проверяет `Application`;
- `watch_list/0` — своими процессами, отфильтрованными **тем же** тумблером, что и старт
  («Наблюдение за процессами»); дерево библиотеки внутри корня входит в него своим `watch_list/1`
  с теми же опциями, что и его старт.

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
        MyApp.<Subsystem>.Registry.load!()
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

Компонент, который целиком — дерево библиотеки (`Core.Es.Projection.Supervisor`), MAY стоять в
`Application` без своего корня: тумблер `enabled:` и `watch_list/1` у дерева уже есть, а опции
собирает одна функция приложения («Проекции и процессы агрегата»).

### Место компонента

Компонент — единица раскладки: каталог компонента с корнем `supervisor.ex` и процессами компонента
рядом. Каталог MUST лежать там, куда компонент относится по назначению:

| Компонент | Где лежит |
|---|---|
| зовёт usecases: воркер, подписчик брокера, импорт | срез своего инициатора, `lib/my_app/domain/<bc>/<actor>/<component>/` |
| без доменной логики: клиент внешнего сервиса, реестр | подсистема `MyApp.<Subsystem>` (`10-architecture.md`, «Состав контекста») |
| кеш read-модели и его инвалидатор | каталог read-модели, `<read_model>/read_repo/supervisor.ex` (`16-caching.md`) |
| очередь outbox | `MyApp.Outbox` (`10-architecture.md`, «Top-level namespaces») |

Компонент в `Common` вне каталога read-модели — MUST NOT: зовущий usecases нарушил бы
направление `Common` → срез (`10-architecture.md`, «Направления зависимостей»), а без доменной
логики контексту он не принадлежит.

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

- Список проекций и опции MUST собирать одна функция приложения (`MyApp.Projections.opts/0`):
  её же принимают `Core.Es.Projection.Supervisor.watch_list/1` и PromEx-плагин
  (`21-observability.md`). Вторая сборка разошлась бы со списком, который видят `await` и метрики.
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
 projections: [MyApp.Domain.<BC>.Common.<ReadModel>.Projection], enabled: true}

# хорошо — одна функция; её же читают watch_list/1 и Core.Es.PromEx
defmodule MyApp.Projections do
  def opts do
    [projections: [MyApp.Domain.<BC>.Common.<ReadModel>.Projection]] ++
      Application.fetch_env!(:my_app, __MODULE__)
  end
end

children = [{Core.Es.Projection.Supervisor, MyApp.Projections.opts()}]

# config/runtime.exs
config :my_app, MyApp.Projections,
  enabled: System.get_env("ES_PROJECTIONS_ENABLED", "true") == "true",
  poll_interval_ms:
    Core.DurationParser.to_timeout!(System.get_env("ES_PROJECTIONS_POLL_INTERVAL", "1s")),
  await_min_ms:
    Core.DurationParser.to_timeout!(System.get_env("ES_PROJECTIONS_AWAIT_MIN", "10ms")),
  await_max_ms:
    Core.DurationParser.to_timeout!(System.get_env("ES_PROJECTIONS_AWAIT_MAX", "100ms")),
  notifications: System.get_env("ES_PROJECTIONS_NOTIFICATIONS", "true") == "true"

# хорошо — одна нода: сигнала внутри ноды хватает, NOTIFY пачек не нужен
config :my_app, MyApp.Projections, notifications: false
```

```text
# плохо — лимит соединений посчитан по пулам repo: соединения слушателей нод в него не входят
max_connections >= ноды × pool_size

# хорошо — плюс по соединению слушателя на каждый различный repo: проекций на каждой ноде
max_connections >= ноды × (pool_size + различных repo: проекций)
```

Процесс агрегата ставится в дерево элементом `{<Aggregate>.Process, enabled: …}`
(`13-repos.md`, «Процесс агрегата»). При `enabled: false` команда идёт тем же путём, но без
процесса на id — это рабочий режим, а не отключённый компонент.

## Наблюдение за процессами

Каждый критичный именованный процесс MUST быть в `watch_list/0` своего компонента — по нему
работает алерт на падение (`21-observability.md`). `watch_list/0` приложения MUST быть
конкатенацией списков компонентов и деревьев библиотеки, без своих элементов и своих проверок
тумблеров.

- Новый именованный процесс, чьё падение меняет поведение системы, MUST попадать в
  `watch_list/0` компонента **той же правкой**, что и в дерево: процесс без наблюдения падает
  молча.
- Список компонента фильтруется его корнем по **текущей** конфигурации — тем же тумблером, что и
  старт: элемент выключенного компонента дал бы вечный алерт «процесс отсутствует»
  (`deps/core/docs/rules/17-otp-concurrency.md`, «Дерево процессов»). Вычислять тумблер компонента
  второй раз в реестре приложения MUST NOT: у тумблера два места, и они расходятся молча.
- Имя процесса берётся у его владельца (функция супервизора, `cache/0` фасада), а не
  повторяется литералом в двух местах.
- Читателей проекций перечисляет само дерево (`Core.Es.Projection.Supervisor.watch_list/1`), а не
  третий список в реестре приложения: иначе он разойдётся с деревом молча.

```elixir
# плохо — реестр повторяет тумблеры и имена процессов компонентов
def watch_list do
  if Application.fetch_env!(:my_app, MyApp.<Subsystem>.Supervisor)[:enabled],
    do: [%{component: "<subsystem>", name: MyApp.<Subsystem>.Worker}],
    else: []
end

# хорошо — конкатенация списков, каждый отфильтрован своим корнем
def watch_list do
  MyApp.Domain.<BC>.Common.<ReadModel>.ReadRepo.Supervisor.watch_list() ++
    MyApp.Outbox.Supervisor.watch_list() ++
    MyApp.<Subsystem>.Supervisor.watch_list() ++
    Core.Es.Projection.Supervisor.watch_list(MyApp.Projections.opts())
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

- Периодические и отложенные работы — планировщик задач, а не самописный цикл с
  `Process.send_after/3`.
- Задача MUST быть идемпотентна по своему ключу (`14-events-outbox.md`) и собирать контекст
  сама (`11-domain.md`).
- Расписание задаётся в `config/runtime.exs` и выключается тумблером.
- Размер пачки — параметр, а не константа в коде: один прогон не должен держать транзакцию на
  произвольном объёме.

## Связанные правила

- Композиционный корень и boundary — `10-architecture.md`
- Время жизни контекста в процессе — `11-domain.md`
- Очередь, подписчики, порядок доставки — `14-events-outbox.md`
- Кеш и его инвалидация — `16-caching.md`
- Метрики и алерты — `21-observability.md`
- Тесты — `19-testing.md`; тесты процессов — `deps/core/docs/rules/19-testing.md`, «Процессы»
