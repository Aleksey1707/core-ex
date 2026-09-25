# Репозитории приложения

- **Область.** `lib/my_app/domain/<bc>/{common,<actor>}/<aggregate>/{repo,read_repo,view}*`,
  `<aggregate>/{event,cmd}*`, `<aggregate>/<name>_key.ex`, `lib/my_app/dao.ex`, DI-ключи
  репозиториев в `config/**`.
- **Читать перед.** Новым репозиторием, Ecto-схемой, View, Specs, модулем ключа, событием или
  командой; правкой `default_filters`, `constraint_errors`, `key_reservations:` и DI.
- **Словарь.** Плейсхолдеры и модальность — `deps/core/docs/rules/00-index.md`.

Контракты `use Core.Repo{,.Pg,.Pg.StateStored,.Pg.Schema}`, `use Core.Es.Aggregate.Repo{,.Pg}`,
`Core.Repo.Sc`, `Core.View`, Specs и `Core.Es.Store` нормирует `deps/core/docs/rules/13-repos.md`,
проекции — `deps/core/docs/rules/22-projections.md`. Здесь — раскладка и решения приложения.

## Раскладка

Всё, что относится к агрегату, лежит **внутри** его каталога; файлов `<aggregate>_repo.ex` и
модулей `<Aggregate>Repo` не бывает:

```text
<bc>/common/<aggregate>/repo.ex                  # write behaviour
<bc>/common/<aggregate>/repo/pg.ex               # use Repo.Pg (без событий) / Repo.Pg.StateStored
<bc>/common/<aggregate>/repo/pg/schema.ex        # Ecto-схема write-пути
<bc>/common/<aggregate>/repo/pg/schema/*.ex      # дочерние таблицы
<bc>/common/<aggregate>/repo/pg/specs.ex         # фрагменты запросов write-пути
<bc>/common/<aggregate>/view.ex                  # View + вложенный View.Codec (dump-only)
<bc>/common/<aggregate>/read_repo.ex             # read behaviour (only: :read, view:)
<bc>/common/<aggregate>/read_repo/pg{,/schema.ex}  # своя read-only схема (to_view/1)
<bc>/common/<aggregate>/read_repo/pg/specs.ex    # фрагменты запросов read-пути («Specs»)
<bc>/common/<aggregate>/read_repo/{cached,invalidator}.ex   # опционально (16-caching.md)
<bc>/common/<aggregate>/event.ex                 # семейство событий: @moduledoc, @type t
<bc>/common/<aggregate>/event/<name>.ex          # одно событие; своя нагрузка — вложенный Payload
<bc>/common/<aggregate>/event/codec.ex           # кодек событий
<bc>/common/<aggregate>/outbox.ex                # маппинг событий в очередь
```

Event-sourced агрегат добавляет к этому свои модули и **не имеет** схемы состояния:

```text
<bc>/common/<aggregate>/cmd.ex                   # семейство команд: @moduledoc, @type t
<bc>/common/<aggregate>/cmd/<name>.ex            # одна команда: use Core.Es.Cmd
<bc>/common/<aggregate>/repo{.ex,/pg.ex}         # use Core.Es.Aggregate.Repo{,.Pg}
<bc>/common/<aggregate>/process.ex               # опционально: use Core.Es.Aggregate.Process
<bc>/common/<aggregate>/<name>_key.ex            # опционально: use Core.Es.KeyReservation
<bc>/common/projection.ex                        # проекция BC: use Core.Es.Projection
<bc>/common/<aggregate>/read_repo/pg/projector.ex  # запись строк read-модели этим агрегатом
```

- Схема write-пути MUST жить под `Repo.Pg.Schema`, схема read-модели — под
  `ReadRepo.Pg.Schema`; у event-sourced агрегата остаётся только вторая.
- Своего хранилища событий у агрегата нет — `deps/core/docs/rules/13-repos.md`,
  «Хранилище событий (`Core.Es.Store`)».
- Кодек событий и `Outbox` лежат в `common/<aggregate>/`: их видят оба среза.
- Репозиторий, схема и View лежат в `Common`, пока агрегат читают и пишут несколько акторов.
  Переезд в срез (`<bc>/<actor>/<aggregate>/`) — вместе с расхождением формы, а не заранее.
- В actor-срезе каталог `<aggregate>/` — namespace actor-domain (`<Actor>.<Aggregate>.…`,
  `10-architecture.md`): репозиторий, View и роль-специфичные операции среза лежат в нём рядом.
- View лежит в каталоге агрегата, а не под репозиторием: его видят behaviour, usecase,
  презентер и кеш.
- Алиас доменного репозитория — `20-agreements.md`, «Алиасы приложения».

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

```elixir
# плохо — <aggregate>/event.ex: события вложены в семейство
defmodule MyApp.Domain.<BC>.Common.<Aggregate>.Event do
  defmodule Opened do
    defmodule Payload do ... end

    use Es.Event,
      aggregate_id: <Aggregate>.ID,
      by: MyApp.Domain.Users.Common.User.ID,
      payload: Payload
  end

  @type t :: Opened.t() | Closed.t()
end

# хорошо — <aggregate>/event/opened.ex
defmodule MyApp.Domain.<BC>.Common.<Aggregate>.Event.Opened do
  alias MyApp.Domain.<BC>.Common.<Aggregate>

  defmodule Payload do ... end

  use Es.Event,
    aggregate_id: <Aggregate>.ID,
    by: MyApp.Domain.Users.Common.User.ID,
    payload: Payload
end

# хорошо — <aggregate>/event.ex
defmodule MyApp.Domain.<BC>.Common.<Aggregate>.Event do
  @moduledoc "События агрегата."

  alias MyApp.Domain.<BC>.Common.<Aggregate>.Event.Closed
  alias MyApp.Domain.<BC>.Common.<Aggregate>.Event.Opened

  @type t :: Opened.t() | Closed.t()
end
```

### Actor-репозиторий

Actor-репозиторий заводится под свой ACL-фильтр среза (`10-architecture.md`); без него срез
читает и пишет репозиторий из `Common`.

- Чтения идут через `use Core.Repo.Pg` со своими `default_filters` среза, запись делегируется
  в `Repo.Pg` из `Common`. Узкий срез MAY не иметь `insert` — только `update` / `save`.
- State-stored агрегат с событиями пишет `use Core.Repo.Pg.StateStored` из `Common`; у
  event-sourced агрегата actor-репозиториев нет («Event-sourced агрегат»).

```elixir
alias MyApp.Domain.<BC>.Common.<Aggregate>

def insert(%<Aggregate>{} = agg, %Context{} = context, opts \\ []),
  do: <Aggregate>.Repo.Pg.insert(agg, context, opts)
```

## Write и read

| Путь | Что отдаёт | Кто зовёт |
|---|---|---|
| `<Aggregate>.Repo` | агрегат на доменных Prim | usecases команд, включая внутренний `get` перед мутацией |
| `<Aggregate>.ReadRepo` | `<Aggregate>.View` из примитивных значений | usecases запросов: HTTP GET, списки, страницы |

- Write-репозиторий содержит то, что нужно command-flow: `get` / `get!`, `insert` / `update` /
  `save` / `delete`, у event-sourced агрегата — `append`. `count` / `page` / `exists?` в него
  не входят: это отдача наружу.
- `list` / `find_many` / `get_many` в write-репозитории MAY — только когда команда мутирует
  множество агрегатов и метод служит **источником для mutate**. Загрузка пачки и её сохранение
  живут в теле одной функции (`deps/core/docs/rules/20-agreements.md`, «Load/save агрегата»).
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

Один репозиторий в `Common`, тело команды `get_decision` → `Agg.execute/2` → `append`, следующая
команда без повторного чтения, отсутствие `:not_found` и команда на несколько агрегатов путём
usecase → repo — `deps/core/docs/rules/13-repos.md`, «Write event-sourced агрегата».

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

`use Core.Es.Aggregate.Process, repo: <Aggregate>.Repo` (`common/<aggregate>/process.ex`) исполняет
команду одного агрегата вместо тела usecase. Колбэк, `enabled: false` и запрет вызова внутри
`Transact.run` — `deps/core/docs/rules/13-repos.md`, «Процесс агрегата».

- Элемент `{<Aggregate>.Process, enabled: …}` ставит дерево приложения (`17-otp-concurrency.md`).
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
задавать **id его потока** — идентификатор из ключа: Prim `use Core.Prim.UUID, version: 5`
(`deps/core/docs/rules/11-domain.md`, «Типизированные обёртки»; схема id —
`deps/core/docs/adr/0017-stream-id-from-key.md`).

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

Изменяемый ключ (логин, название роли) id потока не задаёт: id постоянен, а ключ меняется событием.
Его уникальность MUST держать резерв ключа — модуль `<Aggregate>.<Name>Key`
(`common/<aggregate>/<name>_key.ex`, `use Core.Es.KeyReservation`) в `key_reservations:`
репозитория агрегата (`deps/core/docs/rules/13-repos.md`, «Резервы ключей»; решение —
`deps/core/docs/adr/0018-mutable-key-reservation.md`).

- Событие, которое занимает ключ, MUST нести ключ в нагрузке: `reservation/1` видит только
  событие. Восстановление после удаления тоже кладёт ключ в нагрузку.
- `reservation/1` MUST иметь clause на каждое событие агрегата, catch-all MUST NOT: новое событие,
  меняющее ключ, прошло бы как `:keep`.
- Каноническая форма ключа MUST задаваться только `to_key/1`: ключи сравниваются побайтно, и
  нормализация (регистр, пробелы) в usecase или в базе разойдётся с `find/2`. Правка `to_key/1`
  или `scope:` после первых данных — миграция строк `es_key_reservations`.
- Составной ключ MUST отдаваться списком строк, склейка частей MUST NOT: `["x:y", "z"]` и
  `["x", "y:z"]` склеиваются в один ключ.
- Набор ключей одной области у агрегата не выражается: у агрегата в области один ключ, и набор
  моделируется агрегатом на элемент с идентификатором из ключа.
- `code:` модуля ключа — код каталога агрегата (`12-errors.md`, «Каталоги агрегатов»).
- `key_reservations:` у агрегата с историей MUST выходить вместе с миграцией, которая заполняет
  резервы существующих потоков в форме `to_key/1`, до первой записи нового кода: без неё дубли
  прежних ключей проходят молча.

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

- модуль проекции — один на BC, в `common/projection.ex`: `project/1` только разбирает события
  клаузами, а строки конкретного агрегата пишет `<Aggregate>.ReadRepo.Pg.Projector` рядом со
  схемой, которую этот ReadRepo читает, функцией на событие;
- таблица сохраняет форму, которую читает ReadRepo: даты и авторов строка берёт из `at` / `by`
  события, `version` — из его версии;
- внешние ключи на таблицы проекций и между ними MUST NOT: их ломает `clear/0` пересборки.
  Существование цели проверяет usecase («Event-sourced агрегат»);
- проекция регистрируется в общем списке приложения (`17-otp-concurrency.md`).

```elixir
# плохо — делегирование события целиком: из `project/1` не видно, какое событие чем пишется
def project(%mod{} = event) when mod in @agg_events, do: Projector.project(event)

# хорошо — клауза на модуль события
def project(%Agg.Event.Completed{} = event),
  do: Agg.ReadRepo.Pg.Projector.completed(event)
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
его собственной схемой («Раскладка»). У event-sourced агрегата write-Specs нет — строки
состояния нет, и `Specs` есть только у read-пути.

- Фрагменты, общие для write- и read-пути, MAY выноситься в одно место и композироваться
  `Specs` обоих путей, а не копироваться: копия разошлась бы с оригиналом на первой же правке
  ACL.
- ACL-фильтр среза объявляется `default/1` в `Specs` **своего** среза и композирует общие
  фрагменты. Локальной `default_filters/1` в самом репозитории быть не должно — иначе write- и
  read-репозиторий среза разъедутся по ACL.
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
