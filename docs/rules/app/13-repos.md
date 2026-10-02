# Репозитории приложения

- **Область.** `lib/my_app/domain/<bc>/<aggregate>/{repo,event,cmd}*`,
  `<aggregate>/<name>_key.ex`, каталоги read-моделей
  `<bc>/<read_model>/{view,read_repo,projection}*`, подкаталоги актора
  `<aggregate>/<actor>/{repo,read_repo,view}*`, `lib/my_app/dao.ex`, DI-ключи репозиториев в
  `config/**`.
- **Читать перед.** Новым репозиторием, Ecto-схемой, read-моделью, View, проекцией, Specs, модулем
  ключа, событием или командой; правкой `default_filters`, `constraint_errors`,
  `key_reservations:` и DI.
- **Словарь.** Плейсхолдеры и модальность — `deps/core/docs/rules/00-index.md`.

Контракты `use Core.Repo{,.Pg,.Pg.StateStored,.Pg.Schema}`, `use Core.Es.Aggregate.Repo{,.Pg}`,
`Core.Repo.Sc`, `Core.View`, Specs и `Core.Es.Store` нормирует `deps/core/docs/rules/13-repos.md`,
проекции — `deps/core/docs/rules/22-projections.md`. Здесь — раскладка и решения приложения.

## Раскладка

Деревья ниже — примеры правила «путь файла = имя модуля» (`10-architecture.md`, «Раскладка»).
Всё, что относится к агрегату, MUST лежать **внутри** его каталога; файлов `<aggregate>_repo.ex` и
модулей `<Aggregate>Repo` не бывает. Чтение раскладывается по read-моделям («Read-модель»):

```text
<bc>/<aggregate>.ex                       # агрегат; Prim — вложенные модули или свои файлы
<bc>/<aggregate>/<value>.ex               # опционально: Prim агрегата отдельным файлом
<bc>/<aggregate>/errors.ex                # каталог ошибок
<bc>/<aggregate>/repo.ex                  # write behaviour
<bc>/<aggregate>/repo/pg.ex               # use Repo.Pg (без событий) / Repo.Pg.StateStored
<bc>/<aggregate>/repo/pg/schema.ex        # Ecto-схема write-пути
<bc>/<aggregate>/repo/pg/schema/*.ex      # дочерние таблицы
<bc>/<aggregate>/repo/pg/specs.ex         # фрагменты запросов write-пути
<bc>/<aggregate>/event.ex                 # семейство событий: @moduledoc, @type t
<bc>/<aggregate>/event/<name>.ex          # одно событие; своя нагрузка — вложенный Payload
<bc>/<aggregate>/event/codec.ex           # кодек событий
<bc>/<aggregate>/outbox.ex                # маппинг событий в очередь
```

Event-sourced агрегат добавляет к этому свои модули и **не имеет** схемы состояния:

```text
<bc>/<aggregate>/cmd.ex                   # семейство команд: @moduledoc, @type t
<bc>/<aggregate>/cmd/<name>.ex            # одна команда: use Core.Es.Cmd
<bc>/<aggregate>/repo{.ex,/pg.ex}         # use Core.Es.Aggregate.Repo{,.Pg}
<bc>/<aggregate>/process.ex               # опционально: use Core.Es.Aggregate.Process
<bc>/<aggregate>/<name>_key.ex            # опционально: use Core.Es.KeyReservation
```

- Схема write-пути MUST жить под `Repo.Pg.Schema`, схема read-модели — под
  `ReadRepo.Pg.Schema`; у event-sourced агрегата остаётся только вторая.
- Своего хранилища событий у агрегата нет — `deps/core/docs/rules/13-repos.md`,
  «Хранилище событий (`Core.Es.Store`)».
- Кодек событий, `Outbox`, репозиторий записи и read-модель агрегата лежат в его каталоге и общие
  для всех акторов: в подкаталог актора `<aggregate>/<actor>/` переезжают только его репозитории и
  View — вместе со своим ACL-фильтром или своей формой данных, а не заранее («Репозитории
  актора»; `10-architecture.md`, «Состав контекста»).
- Алиас доменного репозитория — `20-agreements.md`, «Алиасы приложения».

### Read-модель

Read-модель — единица раскладки чтения: View, ReadRepo и проекция, которая пишет её таблицы, MUST
лежать в одном каталоге `<bc>/<read_model>/`: read-модель агрегата — в его каталоге, не по
агрегату — в каталоге по назначению на уровне контекста (`10-architecture.md`, «Состав
контекста»). Правка read-модели затрагивает одно место, а её пересборка — только её таблицы.

```text
<bc>/<read_model>/
  view.ex                                      # View + вложенный View.Codec (dump-only)
  read_repo.ex                                 # read behaviour (only: :read, view:)
  read_repo/pg{,/schema.ex}                    # своя read-only схема (to_view/1)
  read_repo/pg/specs.ex                        # фрагменты запросов read-пути («Specs»)
  read_repo/{cached,invalidator,supervisor}.ex # опционально: кеш (16-caching.md)
  projection.ex                                # use Core.Es.Projection, если таблицы пишет проекция
```

- Имя read-модели — по назначению (`Backlog`, `Delivery`); по умолчанию — имя агрегата, и тогда
  каталог общий с агрегатом: `<aggregate>/view.ex` рядом с `repo.ex`.
- Строка read-модели — один агрегат (его id и `version`), а поля других агрегатов в ней — копии,
  которые проекция берёт из их событий: такая read-модель лежит у этого агрегата, даже если её
  проекция слушает события нескольких. Своё имя и свой каталог нужны, когда строка не равна
  агрегату (очередь, сводка, строка на пару агрегатов): тогда read-модель MUST NOT лежать под одним
  из них.
- ReadRepo MAY читать таблицы чужой read-модели своего контекста (join, подзапрос) своей вложенной
  read-only схемой `<ReadModel>.ReadRepo.Pg.Schema.<Other>` только с нужными полями, а если View
  вкладывает `<Other>.View` целиком — ассоциацией на `<Other>.ReadRepo.Pg.Schema` и её `to_view`:
  копия схемы и маппинга всех полей разошлась бы с владельцем. Таблицы read-модели другого
  контекста ReadRepo читать MUST NOT: join по имени таблицы не видят ни сборка, ни линтер, и
  зависимость от чужой модели обходит его `exports` (`10-architecture.md`, «Направления
  зависимостей»). Нужные поля другого контекста проекция копирует себе из его экспортированных
  событий (`deps/core/docs/adr/0038-one-context-per-transaction.md`). Join через таблицы двух
  проекций видит их разное отставание: граница, которой нужна свежая строка, ждёт и проекцию
  присоединённой таблицы (`15-web-api.md`, «Ожидание проекции»).

  ```elixir
  # плохо — ReadRepo заказов присоединяет таблицу read-модели контекста Billing
  from o in Order.ReadRepo.Pg.Schema,
    join: i in "invoices", on: i.order_id == o.id,
    select: %{o | invoice_status: i.status}

  # хорошо — статус счёта копирует своя проекция из экспортированного события Billing
  def project(%MyApp.Domain.Billing.Invoice.Event.Paid{} = event),
    do: set_invoice_status(event, :paid)
  ```
- Read-модель без таблицы — значение, которое `ReadRepo` собирает на чтении сворачиванием потоков
  (эффективные права пользователя по его ролям), — MAY читать write-репозитории (`get`, `get_many`),
  если своей проекции у неё нет. Как любая read-модель, она только отдаёт данные: решение над ними
  (есть ли доступ) принимает тот, кто её читает, — механизм или usecase. Это исключение из «Read»
  свода библиотеки (`deps/core/docs/rules/13-repos.md`): своей Ecto-схемы у неё нет и
  `use Core.Repo.Pg` она не объявляет, реализация `ReadRepo` — обычный модуль над
  write-репозиториями. Отдаётся она `<ReadModel>.View` из примитивных значений, лежит там же, где
  read-модель с таблицей; кеш — по `16-caching.md`.

  Если её не отдаёт граница (например, её читает только механизм проверки прав), она MAY
  возвращать вместо View неизменяемое доменное значение — struct на Prim и `Core.Enum`, не
  агрегат: значения write-репозиториев уже валидны, и View из примитивов была бы второй формой без
  читателя. Презентер по-прежнему получает только View (`15-web-api.md`, «Presenters»).

  ```elixir
  # плохо — доменное значение уходит на границу: презентер получил не View
  with {:ok, access} <- @access_read_repo.get(user_id, context), do: render(conn, access)

  # хорошо — значение читает только механизм проверки прав, наружу уходит решение
  with {:ok, access} <- @access_read_repo.get(user_id, context),
       do: Access.allows?(access, action)
  ```
- Чтение state-stored агрегата из его собственной таблицы (read-схема над таблицей write-пути,
  без проекции) MUST лежать в каталоге агрегата: таблица принадлежит агрегату.
- View лежит в каталоге read-модели, а не под ReadRepo: его видят behaviour, usecase, презентер и
  кеш.

```text
# плохо — чтение агрегата в трёх местах, отдельный проектор, схема второго агрегата вместо его
# собственной read-модели
<bc>/order/view.ex
<bc>/order/read_repo/pg/projector.ex
<bc>/order/read_repo/pg/schema/shipment.ex
<bc>/projection.ex

# хорошо — read-модель агрегата в его каталоге, read-модель двух агрегатов — в своём
<bc>/order/{view,read_repo,projection}.ex    # строка — заказ, поля отгрузки — копии
<bc>/order/read_repo/pg{,/schema.ex}
<bc>/backlog/{view,read_repo,projection}.ex  # строка — не заказ и не отгрузка
<bc>/backlog/read_repo/pg{,/schema.ex}
```

### Событие и команда

- Событие (у агрегата любого вида) и команда MUST лежать каждое в своём файле
  `event/<name>.ex` / `cmd/<name>.ex`, сколько бы их ни было у агрегата; своя нагрузка события —
  вложенный `Payload` в том же файле. Имя модуля раскладка не меняет: `<Aggregate>.Event.<Name>`,
  `<Aggregate>.Cmd.<Name>`.
- `event.ex` и `cmd.ex` — семейство: `@moduledoc`, `@type t` — объединение `t` членов — и
  помощники приложения над семейством (`name/1`, `names/0`). Вложенные `defmodule` событий и
  команд в них MUST NOT. `t` события даёт `use Es.Event`; команда объявляет `@type t` сама,
  рядом со struct.

Почему: модуль находится по имени без чтения файла, а порог «одним файлом, пока он маленький»
произволен — агрегат на границе переезжал бы туда и обратно.

Проверяется: `deps/core/scripts/boundary_lint.exs --consumer` — правило `module-path`: модуль
`MyApp.Domain.<BC>.<Aggregate>.{Event,Cmd}.<Name>`, вложенный в семейство (кодек семейства —
не член).

```elixir
# плохо — <aggregate>/event.ex: события вложены в семейство
defmodule MyApp.Domain.<BC>.<Aggregate>.Event do
  defmodule Opened do
    defmodule Payload do ... end

    use Es.Event,
      aggregate_id: <Aggregate>.ID,
      by: MyApp.Domain.Users.User.ID,
      payload: Payload
  end

  @type t :: Opened.t() | Closed.t()
end

# хорошо — <aggregate>/event/opened.ex
defmodule MyApp.Domain.<BC>.<Aggregate>.Event.Opened do
  alias MyApp.Domain.<BC>.<Aggregate>

  defmodule Payload do ... end

  use Es.Event,
    aggregate_id: <Aggregate>.ID,
    by: MyApp.Domain.Users.User.ID,
    payload: Payload
end

# хорошо — <aggregate>/event.ex
defmodule MyApp.Domain.<BC>.<Aggregate>.Event do
  @moduledoc "События агрегата."

  alias MyApp.Domain.<BC>.<Aggregate>.Event.Closed
  alias MyApp.Domain.<BC>.<Aggregate>.Event.Opened

  @type t :: Opened.t() | Closed.t()
end
```

### Репозитории актора

Репозитории актора заводятся под его ACL-фильтр (`10-architecture.md`, «Состав контекста») и лежат
в его подкаталоге каталога агрегата: `<aggregate>/<actor>/repo*` — `<Aggregate>.<Actor>.Repo`,
`<aggregate>/<actor>/read_repo*` — `<Aggregate>.<Actor>.ReadRepo`. Без своего фильтра актор читает
и пишет репозитории каталога агрегата.

- ReadRepo актора, который отличается от общего только ACL-фильтром, — в подкаталоге актора лежат
  только `read_repo*` и `read_repo/pg/specs.ex` со своими `default_filters`, а таблица, проекция,
  View и схема остаются в read-модели агрегата. Копия таблицы и проекции на актора MUST NOT; своя
  View актора (`<aggregate>/<actor>/view.ex`) — только при своей форме данных.
- Репозиторий записи актора читает через `use Core.Repo.Pg` со своими `default_filters`, а запись
  делегирует в `<Aggregate>.Repo.Pg`: usecase актора получает агрегат только через свой
  репозиторий, и чужая запись даёт `:not_found` без проверки на каждом call site. Узкий актор MAY
  не иметь `insert` — только `update` / `save`.
- State-stored агрегат с событиями пишет `use Core.Repo.Pg.StateStored` каталога агрегата; у
  event-sourced агрегата репозитория записи актора нет («Event-sourced агрегат»).

```elixir
alias MyApp.Domain.<BC>.<Aggregate>

def insert(%<Aggregate>{} = agg, %Context{} = context, opts \\ []),
  do: <Aggregate>.Repo.Pg.insert(agg, context, opts)
```

## Write и read

| Путь | Что отдаёт | Кто зовёт |
|---|---|---|
| `<Aggregate>.Repo` | агрегат на доменных Prim | usecases команд, включая внутренний `get` перед мутацией |
| `<ReadModel>.ReadRepo` | `<ReadModel>.View` из примитивных значений | usecases запросов: HTTP GET, списки, страницы |

- Write-репозиторий содержит то, что нужно command-flow: `get` / `get!`, `insert` / `update` /
  `save` / `delete`, у event-sourced агрегата — `append`. `count` / `page` / `exists?` в него
  не входят: это отдача наружу.
- `list` / `find_many` / `get_many` в write-репозитории MAY — только когда команда мутирует
  множество агрегатов и метод служит **источником для mutate**, либо его зовёт `ReadRepo`
  read-модели без таблицы («Read-модель»). Загрузка пачки и её сохранение
  живут в теле одной функции (`deps/core/docs/rules/20-agreements.md`, «Load/save агрегата»).
- Кандидатов изменяющего фонового прогона MAY выбирать `ReadRepo` —
  `deps/core/docs/rules/13-repos.md`, «Read (`<Aggregate>.ReadRepo`)».
- Кастомный `get_by_*`, объявление read-репозитория, его собственная схема и
  `shadow_copy?: false` — `deps/core/docs/rules/13-repos.md`, «Read/Write репозитории».

## Вид агрегата

Вид выбирается **на агрегат**, оба остаются в приложении. Контракты обоих write-путей —
`deps/core/docs/rules/13-repos.md`; здесь — на чём основан выбор.

| Вид | Write-путь | Когда |
|---|---|---|
| state-stored | `use Core.Repo.Pg` / `Core.Repo.Pg.StateStored` | состояние важнее пути к нему; нужны произвольные выборки и уникальные индексы по состоянию |
| event-sourced | `use Core.Es.Aggregate.Repo.Pg` | важен сам ход изменений: аудит, пересчёт read-модели, восстановление решения задним числом |

- Агрегат без событий вообще (`use Core.Repo.Pg`) заводится осознанно и с записанной причиной
  (`11-domain.md`).
- Смена вида — переписывание агрегата, а не опция репозитория: у event-sourced нет строки
  состояния, `insert` / `update` / `save` и `delete` отсутствуют, а удаление — доменное событие.

## Event-sourced агрегат

Один репозиторий в каталоге агрегата, тело команды `get_decision` → `Agg.execute/2` → `append`,
следующая команда без повторного чтения, отсутствие `:not_found` и команда на несколько агрегатов
путём usecase → repo — `deps/core/docs/rules/13-repos.md`, «Write event-sourced агрегата».

Проверять существование соседнего агрегата usecase MUST по `version: nil` его состояния, а не по
строке read-модели: её пишет проекция асинхронно.

### Повтор после отказа записи

Запись MAY получить `:version_mismatch` без конфликта версии — страж `xid` хранилища отвергает
запись, если конкурент по тому же потоку закоммитил событие транзакции с `xid` больше её
собственного (`deps/core/docs/rules/13-repos.md`, «Хранилище событий (`Core.Es.Store`)»). Это
отказ хранилища: в detail у него `source: :storage`, а у сверки ожидаемой версии —
`source: :expected`.

Повторяется отказ хранилища при **любой** ожидаемой версии, включая явную `%Version{}` из
`If-Match`: чтение по ней прошло, значит клиент видел актуальное состояние. Сверка ожидаемой
версии MUST NOT повторяться — повтор её не исправит. Ожидаемая версия в решении о повторе не
участвует.

Повтор MUST давать библиотека — `Core.Es.Transact.run/2` в теле usecase либо
`Core.Es.Aggregate.Process` («Процесс агрегата»); своя обёртка над `Transact.run` в приложении
MUST NOT. Тело команды и колбэк MUST быть идемпотентными: повтор зовёт их заново. Предел повторов
и его исчерпание — `warning`, каждый повтор — `debug`
(`deps/core/docs/rules/20-agreements.md`, «Логирование»). Правило и цена —
`deps/core/docs/rules/13-repos.md`, «Транзакция команды (`Core.Es.Transact`)».

```elixir
# плохо — своя обёртка повтора: об отказе соседнего потока она не знает
MyApp.Transact.run(version, fn -> ... end)

# хорошо
Es.Transact.run(fn -> ... end)
```

### Процесс агрегата

`use Core.Es.Aggregate.Process, repo: <Aggregate>.Repo` (`<aggregate>/process.ex`) исполняет
команду одного агрегата вместо тела usecase. Колбэк, `enabled: false` и запрет вызова внутри
`Transact.run` — `deps/core/docs/rules/13-repos.md`, «Процесс агрегата».

- Элемент `{<Aggregate>.Process, MyApp.Processes.opts(<Aggregate>.Process)}` ставит дерево
  приложения; список и опции собирает `MyApp.Processes` (`17-otp-concurrency.md`).
- Сопутствующие записи (постановка фоновой задачи, строка соседней таблицы) идут колбэком
  `fun.(events)`; что в нём допустимо — `10-architecture.md`, «Что можно внутри `Transact.run`».

### Снапшоты

`snapshot: [every: N]` включается, когда поток вырос настолько, что свёртка стала заметна в
`duration` загрузки агрегата, а не заранее: снапшот — кэш, и его цена — вторая запись после
commit.

Подъём `version:` снапшота — `deps/core/docs/rules/13-repos.md`, «Снапшоты».

### Уникальность без индекса состояния

У event-sourced агрегата уникального индекса по состоянию нет: строки пишет проекция, а её
`clear/0` очищает таблицу при пересборке. Поэтому неизменяемый естественный ключ агрегата MUST
задавать **id его потока** — идентификатор из ключа (исключение — внешний идентификатор, ниже):
Prim `use Core.Prim.UUID, version: 5` (`deps/core/docs/rules/11-domain.md`, «Типизированные
обёртки»; схема id — `deps/core/docs/adr/0017-stream-id-from-key.md`).

- Namespace UUIDv5 — один на приложение и неизменяемый: другая константа переименовала бы потоки
  всех таких агрегатов. `namespace:` MUST браться из одной публичной функции модуля приложения
  (`MyApp.StreamID.namespace()`, имя — на выбор приложения); литерал в Prim MUST NOT.
- `scope:` — область ключа — MUST быть у каждого идентификатора из ключа и неизменяема, как тип
  агрегата. Идентификатор, общий у нескольких агрегатов, — одна область.
- Конструктор MUST лежать в Prim идентификатора агрегата (`<Aggregate>.ID.from_<key>` любой
  арности, тело зовёт приватный `from_key/1`), а не в usecase: id вычисляется в нескольких местах,
  а правило одно. Части ключа в строки переводит `from_<key>`.
- Команда-создание такого агрегата идемпотентна: `decide` на `version: nil` отдаёт событие
  заведения, на непустом потоке — обновление либо прежний доменный отказ.

```elixir
# плохо — id генерируется, а уникальность держит индекс таблицы проекции: clear/0 его переживёт
id = Agg.ID.new()

# хорошо — id потока вычислим из ключа, индекс не нужен
id = Agg.ID.from_external(source.external_id)
```

```elixir
# плохо — литерал namespace в Prim: опечатка в одном из них молча переименует потоки
use Core.Prim.UUID,
  name: first_line(@moduledoc),
  version: 5,
  namespace: "1b0f8f5e-8a54-4a7c-9a2b-3f6d2c8e5a11",
  scope: "agg_member"

# хорошо — namespace из одной функции приложения, составной ключ — списком строк
use Core.Prim.UUID,
  name: first_line(@moduledoc),
  version: 5,
  namespace: MyApp.StreamID.namespace(),
  scope: "agg_member"

def from_member(%Agg.ID{} = agg_id, %Actor.ID{} = actor_id),
  do: from_key([Agg.ID.value(agg_id), Actor.ID.value(actor_id)])
```

Ключ, который сам UUID внешнего источника, уникальный на все виды агрегатов, грузящиеся из этого
источника, MAY задавать id потока как есть — внешний идентификатор: Prim
`use Core.Prim.UUID, version: :external`, `new/0` у него нет. UUID, уникальный лишь в пределах
вида, склеит потоки двух видов — ему нужен идентификатор из ключа. Решение —
`deps/core/docs/adr/0036-stream-id-external-uuid.md`.

```elixir
# плохо — UUID источника под генерирующей версией: new/0 выпустит id в обход источника
use Core.Prim.UUID,
  name: first_line(@moduledoc),
  version: 1,
  check_version: false

# хорошо — внешний идентификатор: new/0 нет, разбор принимает UUID любой версии
use Core.Prim.UUID,
  name: first_line(@moduledoc),
  version: :external
```

Изменяемый ключ (логин, название роли) id потока не задаёт: id постоянен, а ключ меняется событием.
Его уникальность MUST держать резерв ключа — модуль `<Aggregate>.<Name>Key`
(`<aggregate>/<name>_key.ex`, `use Core.Es.KeyReservation`) в `key_reservations:`
репозитория агрегата (`deps/core/docs/rules/13-repos.md`, «Резервы ключей»; решение —
`deps/core/docs/adr/0018-mutable-key-reservation.md`).

- Событие, которое занимает ключ, MUST нести ключ в нагрузке: `reservation/1` видит только
  событие. Восстановление после удаления тоже кладёт ключ в нагрузку.
- `reservation/1` MUST иметь clause на каждое событие агрегата, catch-all MUST NOT: новое событие,
  меняющее ключ, прошло бы как `:keep`.
- Каноническая форма ключа MUST задаваться только `to_key/1`: ключи сравниваются побайтно, и
  нормализация (регистр, пробелы) в usecase или в базе разойдётся с `find/2`. Правка `to_key/1`
  или `scope:` после первого релиза приложения — миграция строк `es_key_reservations`.
- Составной ключ MUST отдаваться списком строк, склейка частей MUST NOT: `["x:y", "z"]` и
  `["x", "y:z"]` склеиваются в один ключ.
- Набор ключей одной области у агрегата не выражается: у агрегата в области один ключ, и набор
  моделируется агрегатом на элемент с идентификатором из ключа.
- `code:` модуля ключа — код каталога агрегата (`12-errors.md`, «Каталоги агрегатов»).
- `key_reservations:` у агрегата с историей MUST выходить вместе с миграцией, которая заполняет
  резервы существующих потоков в форме `to_key/1`, до первой записи нового кода: без неё дубли
  прежних ключей проходят молча. До первого релиза приложения — без неё (`00-index.md`,
  «Первый релиз»).

```elixir
# плохо — catch-all: новое событие, меняющее логин, резерв не перенесёт
def reservation(%Event.Created{payload: payload}), do: {:reserve, payload.login}
def reservation(_event), do: :keep

# хорошо — clause на каждое событие, каноническая форма — в to_key/1
def reservation(%Event.Created{payload: payload}), do: {:reserve, payload.login}
def reservation(%Event.LoginChanged{payload: payload}), do: {:reserve, payload.login}
def reservation(%Event.Blocked{}), do: :keep
def reservation(%Event.Deleted{}), do: :release

def to_key(%Agg.Login{} = login), do: String.downcase(Agg.Login.value(login))
```

```elixir
# плохо — склейка частей: раздел "x:y" с кодом "z" и раздел "x" с кодом "y:z" дают один ключ
def to_key(%Agg.Code{} = code), do: "#{Agg.Code.section(code)}:#{Agg.Code.value(code)}"

# хорошо — части списком
def to_key(%Agg.Code{} = code), do: [Agg.Code.section(code), Agg.Code.value(code)]
```

```elixir
# плохо — заполнение резервов не в форме to_key/1: find/2 прежних логинов не найдёт
execute """
INSERT INTO es_key_reservations (scope, key, aggregate_id)
SELECT 'agg.login', ARRAY[login], id FROM agg_logins
"""

# хорошо — форма ключа та же, что у to_key/1
execute """
INSERT INTO es_key_reservations (scope, key, aggregate_id)
SELECT 'agg.login', ARRAY[lower(login)], id FROM agg_logins
"""
```

## Страница потока

История агрегата на экране — страница его потока (`@repo.page_stream(id, limit, offset, context)`
у репозитория агрегата), а не таблица read-модели. Читающий usecase MUST до чтения проверить права
и существование агрегата (`deps/core/docs/rules/13-repos.md`, «Страница потока»): сам
`page_stream` доступ не проверяет и на пустом потоке отдаёт страницу с `count: 0`.

Существование проверяется тем источником, который для этого агрегата авторитетен: read-модель —
если она есть и заполнена, соседний агрегат — если строка целевого заводится позже
(роли выдаются не при заведении пользователя). Выбор MUST быть записан рядом: проверка по
отстающей проекции даёт `:not_found` на только что созданный агрегат.

## Проекции read-модели

Таблицы, которые читают ReadRepo event-sourced агрегатов, пишут проекции
(`deps/core/docs/rules/22-projections.md`). Раскладка в приложении:

- проекция MUST быть одна на read-модель — `<ReadModel>.Projection` в её каталоге («Read-модель»),
  `name:` SHOULD называть read-модель. Одна проекция на контекст MUST NOT: подъём её `version:`
  пересобирал бы таблицы всех read-моделей контекста. На время перехода на новую проекцию
  (`deps/core/docs/rules/22-projections.md`, «Новая проекция») вторая проекция лежит в том же
  каталоге;
- проекция MUST писать свои таблицы сама — приватной функцией на событие под клаузой `project/1`.
  Отдельный модуль записи (`<Aggregate>.ReadRepo.Pg.Projector`) MUST NOT: у таблицы один хозяин и
  один модуль, и из `project/1` видно, какое событие что пишет;
- таблица сохраняет форму, которую читает ReadRepo: даты и авторов строка берёт из `at` / `by`
  события, `version` — из его версии;
- внешние ключи на таблицы проекций и между ними MUST NOT: их ломает `clear/0` пересборки.
  Существование цели проверяет usecase («Event-sourced агрегат»);
- проекция регистрируется в общем списке приложения (`17-otp-concurrency.md`).

Проверяется: `deps/core/scripts/boundary_lint.exs --consumer` — правило `projection-layout`: модуль
с `use Core.Es.Projection` — `MyApp.Domain.<BC>.<ReadModel>.Projection` (или
`ProjectionV<N>`) ровно в каталоге read-модели; модуль `*.Projector` под `ReadRepo` — MUST NOT
(слово `Projector` вне `ReadRepo` бывает доменным и не проверяется). Отступление — маркер и строка
`DEBT.md` (`10-architecture.md`, «Отступление»).

```elixir
# плохо — одна проекция на контекст, строки пишет проектор под ReadRepo
defmodule MyApp.Domain.<BC>.Projection do
  def project(%Agg.Event.Completed{} = event),
    do: Agg.ReadRepo.Pg.Projector.completed(event)
end

# хорошо — проекция read-модели в её каталоге пишет свою таблицу сама
defmodule MyApp.Domain.<BC>.<Aggregate>.Projection do
  use Core.Es.Projection,
    name: "<aggregate>",
    events: [Agg.Event.Opened, Agg.Event.Completed]

  @impl true
  def project(%Agg.Event.Opened{} = event), do: insert_row(event)

  def project(%Agg.Event.Completed{} = event), do: complete_row(event)

  @impl true
  def clear do
    {_count, nil} = DAO.delete_all(Agg.ReadRepo.Pg.Schema)
    :ok
  end
end
```

## View

Поля View, Prim в декларации, `version`, запрет View в write-пути и jsonb на read-пути —
`deps/core/docs/rules/13-repos.md`, «View (read-модель)».

- Секрет во View MUST NOT: значение заменяется признаком «задано» там, где собирается форма.
- Строка списка MAY отдавать сокращённое представление строки вместо полного View, если карточка
  несёт то, что строке не нужно (дочерние коллекции, тяжёлый jsonb). Поля сокращённого
  представления — подмножество полей View с теми же именами, коллекция заменяется счётчиком;
  полей, которых во View нет, MUST NOT.

## Specs

У read-репозитория **свои** `Specs` — `read_repo/pg/specs.ex`: фрагменты запросов строятся над
его собственной схемой («Read-модель»). У event-sourced агрегата write-Specs нет — строки
состояния нет, и `Specs` есть только у read-пути.

- Фрагменты, общие для write- и read-пути, MAY выноситься в одно место и композироваться
  `Specs` обоих путей, а не копироваться: копия разошлась бы с оригиналом на первой же правке
  ACL.
- ACL-фильтр актора объявляется `default/1` в `Specs` **его** подкаталога и композирует общие
  фрагменты. Локальной `default_filters/1` в самом репозитории быть не должно — иначе репозиторий
  записи и ReadRepo актора разъедутся по ACL.
- Запрос, привязанный к схеме, принимает её аргументом — тогда один фрагмент собирает и
  write-, и read-путь.
- Пустая выборка под ACL-фильтром MUST давать `:not_found`, а не отказ по правам: клиенту не
  сообщается, существует ли чужая запись (negative-тест —
  `deps/core/docs/rules/19-testing.md`, «ACL»).

## `constraint_errors`

Каждый write-репозиторий MUST декларировать `constraint_errors` на все свои ограничения:
незамапленный constraint приходит наверх как `%Error{kind: :app, ns: :repo, code:
:write_failed}` — прикладная ошибка вместо доменной, то есть 500 вместо внятного ответа.

- Соответствие поля `*_constraint` в `changeset/2` и составной unique-индекс —
  `deps/core/docs/rules/13-repos.md`, «Generic `use Core.Repo.Pg`».
- Дочерняя таблица объявляет свои ограничения внутри своей записи `children:`: имя constraint
  принадлежит той таблице, где он объявлен.
- Коды берутся из каталога агрегата (`12-errors.md`), не выдумываются на месте.

Проверяется: ратчет `constraint_errors` — `use Core.Repo.ConstraintErrorsCase` (`19-testing.md`).

## DI

Конвенция `<Behaviour>.Pg`, резолв через `Core.Config.repo!/1` с литералом модуля и ключ только
на подмену — `deps/core/docs/rules/13-repos.md`, «DI».

- Подмена, ради которой приложение заводит ключ, — кеш-фасад (`16-caching.md`) и тестовый
  дублёр внешней системы. Ключ, повторяющий конвенцию, — лишний источник истины.
- Инфраструктурный шов, который репозиторием не является (объектное хранилище, каталог
  пользователей), резолвится обычным `compile_env` и этим правилом не связан.

Проверяется: `make boundary-check`
(`elixir deps/core/scripts/boundary_lint.exs --consumer lib test`).

## Наименование

| Concern | Convention |
|---|---|
| Таблица | множественное число в snake_case: `<entities>`, `<entity>_<children>` |
| PK / FK | `:binary_id`; идентификаторы — строки UUID через `InCodec.dump/1` |
| Soft delete | `deleted_at` / `deleted_by_id` + фрагмент `not_deleted` в `Specs` |
| Схема | `<Aggregate>.Repo.Pg.Schema` (+ вложенные `Schema.<Child>`) |
| Таблицы event sourcing | `es_events`, `es_snapshots`, `es_checkpoints` — колонки задаёт `Core.Es.Migration`, `es_key_reservations` — `Core.Es.KeyReservation.Migration`; своих у приложения нет (`18-migrations.md`) |

## Связанные правила

- Архитектура и usecases — `10-architecture.md`
- Агрегаты, Prim и Codec — `11-domain.md`
- Коды ошибок репозиториев — `12-errors.md`
- Запись событий и outbox — `14-events-outbox.md`
- Представления на границе и ожидание проекции — `15-web-api.md`
- Кеш поверх read-репозитория — `16-caching.md`
- Дерево проекций и процессов агрегата — `17-otp-concurrency.md`
- Миграции таблиц — `18-migrations.md`
- Тесты репозиториев, агрегатов и проекций — `19-testing.md`
- Контракт проекций — `deps/core/docs/rules/22-projections.md`
