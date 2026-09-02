# Репозитории

Плейсхолдеры: `MyApp`, `:my_app`, `<BC>`, `<Actor>`, `<Aggregate>` — см. `10-architecture.md`.

## Слои и пути

| Слой | Пример модуля | Роль |
|---|---|---|
| Behaviour | `<BC>.Common.Repo`, `<Actor>.<Aggregate>.Repo`, `<Aggregate>.Event.Repo` | `@callback` API; без SQL |
| Pg impl | `*.Repo.Pg`, `*.<Aggregate>.Repo.Pg`, `*.Event.Repo.Pg` | PostgreSQL-реализация |
| Schema | `*.Repo.Pg.Schema` (+ nested `Schema.<Child>`, …) | Ecto schema; write — `to_entity`/`to_model` (+ bang), read — `to_view` |
| View | `<Actor>.<Aggregate>.View` (+ вложенный `.Codec`) | read-модель: примитивные значения + dump-only кодек |
| Specs | `*.Repo.Pg.Specs` | `dynamic` / `from` query fragments |
| Core | `Core.Repo`, `Core.Repo.Pg`, `Core.Repo.Pg.Children`, `Core.Repo.Sc` | генерация behaviour; generic CRUD; синхронизация дочерних строк; shadow copy |
| Core (ES) | `Core.Repo.Pg.Es`, `Core.Repo.Pg.Schema`, `Core.Es.Event.Repo{,.Pg,.Pg.Schema}` | write-репо агрегата с событиями; производные функции схемы; event store |

Структура путей (target) — всё, что относится к сущности, лежит **внутри** её каталога;
файлов вида `<aggregate>_repo.ex` и модулей вида `<Aggregate>Repo` не бывает:

```
<role>/<aggregate>/repo.ex                   # write behaviour
<role>/<aggregate>/repo/pg.ex                # use Repo.Pg.Es (или Repo.Pg — агрегат без событий)
<role>/<aggregate>/repo/pg/schema.ex
<role>/<aggregate>/repo/pg/schema/*.ex       # дочерние таблицы
<role>/<aggregate>/repo/pg/specs.ex
<role>/<aggregate>/view.ex                   # View + вложенный View.Codec (dump-only)
<role>/<aggregate>/read_repo.ex              # read behaviour (:read + view:)
<role>/<aggregate>/read_repo/pg.ex
<role>/<aggregate>/read_repo/pg/schema.ex    # своя read-only Ecto-схема (to_view/1)
<role>/<aggregate>/read_repo/pg/specs.ex
<role>/<aggregate>/read_repo/cached.ex       # опционально: кеш-фасад
<role>/<aggregate>/read_repo/invalidator.ex  # опционально: инвалидация по событиям
<aggregate>/outbox.ex                        # use Es.Outbox
<aggregate>/event/repo.ex                    # use Es.Event.Repo
<aggregate>/event/repo/pg.ex
<aggregate>/event/repo/pg/schema.ex
```

Event store и `Outbox` — рядом с агрегатом (`common/<aggregate>/`), write-репо — в actor-срезе.
В actor-срезе каталог `<aggregate>/` — это namespace actor-domain (`<Actor>.<Aggregate>.…`,
`10-architecture.md`): репозиторий, View и роль-специфичные операции живут в нём рядом.

Schema MUST жить под `Repo.Pg.Schema`, не под `Repo.Schema`.

Следствие для алиасов: короткое имя `Repo` теперь занято `Core.Repo` почти в каждом файле,
поэтому доменный репозиторий MUST адресоваться через алиас агрегата (`alias …Common.Delivery` →
`Delivery.Repo.Pg.Schema`), а отдельный `alias …Common.Delivery.Repo` — **MUST NOT**: он перебивает
`alias Core.Repo` и ломает `use Repo.Pg` (`20-agreements.md`, «Алиасы модулей»).

## Read/Write репозитории

Наименование:

| Вид | Модуль | Файл |
|---|---|---|
| Запись | `<Aggregate>.Repo` / `Repo` (common) | `<aggregate>/repo.ex` / `repo.ex` |
| Чтение | `<Aggregate>.ReadRepo` / `ReadRepo` | `<aggregate>/read_repo.ex` / `read_repo.ex` |

### Write (`<Aggregate>.Repo`)

Содержит то, что нужно **command-flow**:

- `get` / `get!` — load одного агрегата перед mutate (`shadow_copy?: true` при необходимости).
- `insert` / `update` / `save` / `delete`.
- Опционально `list` / `find_many` / `get_many`, если команда мутирует **множество** агрегатов сразу (bulk: загрузить пачку → замутировать каждый → сохранить). Критерий: метод — источник данных для `mutate`, а не отдача наружу (HTTP/презентер). Загрузка пачки и её сохранение — в теле одной функции (см. «Load/save агрегата — в одной функции» в `20-agreements.md`).

- Кастомный `get_by_*` (резолв alternate key — `owner_id`, `login`, `external_id`) MUST принимать `version` (`%Version{} | :current`) и проверять её сам. Иначе call site вынужден делать второй `get(id, version)` — два SELECT ради одной проверки. Тело — один вызов `Repo.Pg.get_by/6` (`read_scope` + фильтр → `not_found` → `version_error` → capture):

  ```elixir
  @impl true
  def get_by_name(%Agg.Name{} = name, version, %Context{} = context, opts \\ [])
      when is_version(version) and is_list(opts) do
    Repo.Pg.get_by(@pg, Specs.by_name(InCodec.dump(name)), name, version, context, opts)
  end
  ```

Обычно **не** входят: `count` / `page` / `exists?` / `exists_all?` — это отдача наружу, место в ReadRepo.

### Read (`<Aggregate>.ReadRepo`)

- `use Core.Repo, only: :read, view: <Aggregate>.View` — read-репо отдаёт **представление**, не агрегат.
- `shadow_copy?: false` в `Repo.Pg` (не участвует в optimistic-lock цепочке команд).
- Декодер строки — `to_view: &Schema.to_view/1`; `to_model:` read-репо не нужен.
- Собственная Ecto-схема `<Aggregate>.ReadRepo.Pg.Schema` (MUST, см. «Generic `use Core.Repo.Pg`») и свои `Specs`.
- Usecases запросов (`get`/`list`/`page`, HTTP GET) вызывают **ReadRepo**.
- Usecases команд вызывают **Repo** (в т.ч. internal `get` перед мутацией — это часть команды, не query).

Кеш — только на ReadRepo; см. `16-caching.md` свода приложения.

## View (read-модель)

Write-репозиторий работает с **агрегатом** на доменных Prim, read-репозиторий — с
**представлением** (View): структурой из примитивных значений.

View объявляется билдером `Core.View`: одна декларация полей порождает и структуру, и её
dump-only кодек.

```elixir
defmodule MyApp.Domain.<BC>.<Actor>.<Aggregate>.View do
  @moduledoc """
  Представление <Aggregate> для query-пути
  """

  alias MyApp.Domain.<BC>.Common.<Aggregate>

  use Core.View,
    fields: [
      id: [prim: <Aggregate>.ID],
      name: [prim: <Aggregate>.Name],
      status: [enum: <Aggregate>.Status],
      version: [type: :pos_integer],
      snapshot: [jsonb: {<Other>.Codec, :snapshot_redump_spec}],
      stages: [list: [form: :stage]],
      created_at: [prim: <Aggregate>.CreatedAt],
      closed_at: [prim: <Aggregate>.ClosedAt, optional: true]
    ],
    forms: [
      stage: [
        code: [prim: Process.Stage.Code],
        started_at: [prim: <Aggregate>.Stage.StartedAt, optional: true]
      ]
    ]
end
```

Виды полей: `prim:` (Prim-модуль), `enum:`, `type:` (`:string` / `:boolean` / `:integer` /
`:pos_integer` / `:non_neg_integer`), `view:` (вложенный View), `form:` (именованная map-форма
из `forms:`), `list:`, `jsonb:` (`{Модуль, :функция}` спеки `Core.Codec.Redump`);
`optional: true` выводит поле из `@enforce_keys` и добавляет `| nil` в тип.

Правила:

- Поле объявляется **тем Prim, которым оно живёт в домене**. Prim задаёт тип поля и его
  wire-формат (`Codec.dump_raw_as/2`: kind плюс tz и precision этого Prim) — но в структуру
  не попадает. Поэтому read-путь не может разойтись с агрегатным, а поле, добавленное в
  структуру, не может остаться недампленным: и то и другое порождает одна строка декларации.
- Поля — **только** примитивные значения и атомы `Core.Enum`. Prim во View — **MUST NOT**:
  read-путь не валидирует, а `Prim.new/1` на строке из БД поднял бы доменную ошибку там,
  где обработать её нечем (страница списка не должна падать из-за одной строки).
- Sensitive Prim в декларации — `CompileError`: чувствительному значению не место в
  read-модели. Prim с кастомным kind — тоже (типизировать нечем; поле объявляется `type:`).
- `version` — голое `pos_integer()` (у версионируемой таблицы). `%Version{}` живёт на **входе**
  (`If-Match` → `Version.parse/1` → `get(id, version, context)`), а не в результате.
- View **MUST NOT** попадать в write-путь: `insert` / `update` / `save` принимают агрегат.
  Собирать агрегат из View запрещено — он не проходил доменной валидации и не знает инвариантов.
- Наименование: `<Actor>.<Aggregate>.View`, файл `<role>/<aggregate>/view.ex`. View принадлежит
  actor-срезу, а не репозиторию: его видят behaviour, usecase, презентер и кеш. Форма View
  роле-специфична — набор полей у разных акторов разный.
- Генерируются `@enforce_keys`, `defstruct`, `@type t` (точный: `String.t()`, `DateTime.t()`,
  `Decimal.t()`, `pos_integer()`, `<Enum>.t()`), именованные `@type` форм, `new/1` (keyword)
  и вложенный `<Aggregate>.View.Codec` — dump-only плагин (`loadable: false`), который
  регистрируется в `Codec.plugins()`. Презентер зовёт `OutCodec.dump(view)` (`15-web-api.md` свода приложения).
- Enum-поля кодек не сериализует (атомы как есть) — как и в `<Aggregate>.Codec`.
- Дополнительные конструкторы (`empty/2` и т.п.) пишутся руками после `use` и зовут `new/1`.

### jsonb-нагрузка на read-пути

Полиморфная нагрузка (снимки, состояния шагов) в домен на read-пути **не разбирается**, но и
«как записана» наружу не отдаётся: она лежит в форме внутреннего профиля, а уйти обязана во
внешнем. Перевод делает `Core.Codec.Redump` по спеке формы
(`{:prim, Mod} | {:map, %{ключ => спека}} | {:list, спека} | {:tagged, %{тег => спека}}`).

- Спеку объявляет **тот кодек, который эту wire-форму пишет** (`<X>.Codec.<форма>_redump_spec/0`),
  а не View: кто задал формат, тот его и описывает.
- Спека полиморфной нагрузки собирается из деклараций её источников, а не выписывается списком
  (у шагов процесса — `wire_prims:` в `use Process.Step` → `Step.Codec.redump_specs/0`): иначе
  новый вариант нагрузки молча останется в старом формате.
- Ссылка из View — `jsonb: {Модуль, :функция}`, вызов идёт в рантайме: compile-зависимости
  View на кодеки не появляется.
- Redump тотален по значению (неизвестный тег, отсутствующий ключ, неприводимое значение —
  как есть) и строг по спеке: нераспознанная спека — ошибка программиста.
- Обязателен контрактный тест «read-wire == агрегатный wire» (`19-testing.md`).

## Behaviour (`use Core.Repo`)

```elixir
use Core.Repo, only: :full | :read | :permanent | [atoms]
```

Генерирует `@callback` для выбранных методов.

| `only` | Методы |
|---|---|
| `:full` | `get get! list page find_many get_many insert update save delete exists? exists_all? count` |
| `:permanent` | как `:full`, без `delete` |
| `:read` | только чтение |
| list | явный список |

Тип элемента — `item` в таблице ниже — задаёт опция: `entity:` (агрегат) или `view:` (представление).

| Метод | Возврат |
|---|---|
| `get` | `{:ok, item} \| {:error, Error.t()}` |
| `get!` | `item`; ошибка → `raise Exc` |
| `list` / `count` | `[item]` / `non_neg_integer()` |
| `page` | `Pagination.Result.t(item)` |
| `insert` / `update` / `save` | `{:ok, entity} \| {:error, Error.t()} \| {:error, Ecto.Changeset.t()}` |
| `delete` | `:ok \| {:error, Error.t()}` |
| `exists?` / `exists_all?` | `{:ok, boolean()} \| {:error, Error.t()}` |

Опции типов (MUST для новых behaviour — иначе `item` вырождается в `struct()`, а id в `term()`):

| Опция | Значение | Где |
|---|---|---|
| `entity:` | модуль агрегата | write-репо |
| `view:` | модуль представления | read-репо |
| `id:` | Prim идентификатора | обе |

`entity:` и `view:` взаимоисключающие, `view:` вместе с `insert` / `update` / `save` / `delete`
— `CompileError`: инвариант «write — агрегат, read — View» проверяет компилятор, а не ревью.

Version-аргумент: `%Version{} | :current`.

## Generic `use Core.Repo.Pg`

Для агрегатов **без событий**, read-репо и role-reads. Агрегат с событиями — `Repo.Pg.Es`
(см. ниже), он же пробрасывает все перечисленные опции внутрь.

```elixir
use Repo.Pg,
  behaviour: MyApp.Domain.<BC>.<Actor>.<Aggregate>.Repo,
  schema: Schema,
  to_entity: &Schema.to_entity!/1,
  to_model: &Schema.to_model!/1,
  to_id: &Schema.dump_id/1,
  query: Specs.base_query(),
  default_filters: &Specs.default/1,
  shadow_copy?: true,
  id: Agg.ID,
  entity: Agg,
  errors: Agg.Errors,
  constraint_errors: [
    unique: [name: :already_exists]
  ]
```

`errors:` — модуль через родителя агрегата (`Draft.Errors`, `Product.Errors`, `User.Errors`), не leaf-alias `Errors`. Role `*.Repo.Pg` MUST NOT дублировать тексты ошибок.

`constraint_errors:` — опционально; keyword `[constraint_type: [field: error_code]]`. Типы: `unique` / `foreign_key` / `check` / `exclusion`. Коды проверяются compile-time через `errors.domain/3`.

Поле MUST соответствовать `*_constraint` в `changeset/2`: сверка идёт с `error_type` ошибки
changeset, а не с типом ограничения (`foreign_key_constraint/3` пишет `:foreign`) — перевод
делает макрос. Незаявленный в `changeset/2` маппинг молча не сработает, поэтому соответствие
деклараций — и у агрегата, и у `children:` — проверяется тестом
`test/<app>/repo/constraint_errors_test.exs` (`19-testing.md`).

Read-репозиторий — тот же макрос, другой декодер строки:

```elixir
use Repo.Pg,
  behaviour: MyApp.Domain.<BC>.<Actor>.<Aggregate>.ReadRepo,
  schema: Schema,
  to_view: &Schema.to_view/1,
  to_id: &Schema.dump_id/1,
  query: Specs.base_query(),
  default_filters: &Specs.default/1,
  id: Agg.ID,
  errors: Agg.Errors
```

| Опция | write-репо | read-репо |
|---|---|---|
| `to_entity:` | обязателен | — (запрещён вместе с `to_view:`) |
| `to_view:` | `CompileError` | обязателен |
| `to_model:` | обязателен | не нужен |
| `shadow_copy?:` | `true` при load → mutate → save | `false` (дефолт) |
| `entity:` | guard `insert` / `update` / `save` | — |

Guard по типу результата у read-методов не заводится: представление никогда не приходит
аргументом — на вход идут id, пагинация и `%Context{}`.

Read-репозиторий MUST иметь **собственную** Ecto-схему `<Aggregate>.ReadRepo.Pg.Schema` на той же
таблице: только нужные колонки, без `changeset/2` и без аудит-`belongs_to`. Схема write-репо не
переиспользуется — иначе read-срез становится зависим от формы записи, а запись оказывается
в одном шаге от query-пути. Цена — продублированный список полей; расхождение с миграцией
всплывает на тесте `to_view/1`.

Семантики:

- Чтение → domain через bang `to_entity` (опция `use Repo.Pg` — bang-mapper); при `shadow_copy?: true` — `Repo.Sc.put`.
- Чтение read-репо → View через тотальный `to_view` (`Repo.Sc` не участвует).
- Эталон Sc ключуется парой `{модуль сущности, id}` (`Repo.Sc.fetch(context, Entity, id)`): разные агрегаты могут делить идентификатор (`User` и `UserRoles`).
- `not_found` / `version_mismatch` / `incomplete_result` / `no_ids` → `errors.domain(behaviour, code, detail)`.
- `insert`/`update`/`save`: замапленный DB-constraint → `{:error, Error.t()}` через `errors.domain(behaviour, code, detail)`; незамапленный → `{:error, Ecto.Changeset.t()}`.
- `delete` — hard `delete_all` по scope; soft-delete — через update entity.
- Scope: `read_scope` = query + `default_filters`; `write_scope` = без order/preload/select.
- `write_insert/4` / `write_update/4` — те же записи, но без decode строки обратно в domain
  (`:ok | {:error, _}`). Для call site, который результат всё равно отбрасывает: `Repo.Pg.Es`
  (см. ниже). В обычном коде — `insert`/`update`/`save`.

## Schema (`repo/pg/schema.ex`)

Обязательные конвенции:

- `@primary_key {:id, :binary_id, autogenerate: false}`
- `@foreign_key_type :binary_id`
- Явные `field :created_at/:updated_at/:deleted_at, :utc_datetime` — **не** `timestamps()`
- Аудит FK: `created_by_id` / `updated_by_id` / `deleted_by_id` → `belongs_to` UserSchema
- Optimistic lock: integer `version`
- Дочерние сущности — **отдельные таблицы** + `has_many`, **не** `embeds_*`

Обязательный API:

| Функция | Направление | Возврат | Кто пишет |
|---|---|---|---|
| `to_entity/1` | DB row → domain | `{:ok, entity} \| {:error, Error.t()}` | руками |
| `to_entity!/1` | DB row → domain | `entity`; ошибка → `raise Exc` | `use Repo.Pg.Schema` |
| `to_model/1` (или `/2` для children) | domain → map | `{:ok, map()} \| {:error, Error.t()}` | руками |
| `to_model!/1` (или `/2`) | domain → map | `map()`; ошибка → `raise Exc` | `use Repo.Pg.Schema` |
| `dump_id/1` | domain ID → binary_id string | `InCodec.dump(id)` | `use Repo.Pg.Schema` |
| `changeset/2` | schema + attrs | `Ecto.Changeset.t()` | руками |

Bang-обёртки и `@type t` не пишутся руками — их даёт `Core.Repo.Pg.Schema`, поставленный **после**
блока `schema/2` (нужен `defstruct`):

```elixir
schema "roles" do
  # ...
end

use Repo.Pg.Schema,
  entity: Agg,
  id: Agg.ID
```

`id:` — отдельная опция, не обязательно `<entity>.ID`: у `UserRoles` идентификатор агрегата — `User.ID`.

Режим `view:` — схема read-репозитория (`entity:` и `view:` взаимоисключающие):

```elixir
schema "roles" do
  # ...
end

use Repo.Pg.Schema,
  view: <Aggregate>.View,
  id: Agg.ID
```

| Функция | Направление | Возврат | Кто пишет |
|---|---|---|---|
| `to_view/1` | DB row → View | `View.t()` | руками |
| `dump_id/1` | domain ID → binary_id string | `InCodec.dump(id)` | `use Repo.Pg.Schema` |

`to_view/1` **тотален**: значения строки переносятся во View как есть — без `InCodec.load`,
без `Prim.new`, без ручной сборки Prim. Валидации на read-пути нет, значит нет и `{:error, _}`,
который разворачивала бы bang-обёртка. Отсутствие `to_view/1` — `CompileError` (проверка после
компиляции схемы). `changeset/2` в read-схеме не объявляется: писать через неё нечего.

Safe — источник истины: при наличии entity-codec (`<Aggregate>.Codec` / `Outbox.Codec`) — **MUST** `InCodec.load(Entity, attrs)` / `InCodec.dump(entity)`; Schema только remap колонок ↔ wire-ключи (+ DB-only FK / JSON string-keys). Без `Prim.new` / ручной сборки struct. Bang — `Result.unwrap!(to_entity/to_model(...))` (`%Error{}` → `Exc`).

Когда какой вызов:

- Свои строки / persist валидного domain (`use Repo.Pg`, Event.Repo, Draft write, …) → bang (`to_entity!` / `to_model!`).
- Dirty/infra (например Outbox `reserve_rows`) → safe (`to_entity` / `to_model`).

Опции `use Repo.Pg` `to_entity:` / `to_model:` — **bang-функции** (возврат entity/map): `&Schema.to_entity!/1`, `&Schema.to_model!/1`.

В `to_entity`/`to_model` — `alias MyApp.Codec.Internal, as: InCodec` → полный `InCodec.load(Entity, map)` / `InCodec.dump(entity)` через entity-codec; Schema remaps root-поля под колонки БД (`created_by_id` ↔ `created_by`, …).

Changeset: `@required` / `@optional` через `~w(...)a` → `cast` → `validate_required` → `foreign_key_constraint` (и `unique_constraint` при необходимости).

В `to_entity` поле `events: []` — события читаются из Event.Repo, не из строки агрегата.

## Specs

Именованные `Ecto.Query.dynamic_expr()` + `base_query/0`.

```elixir
def not_deleted(_context), do: dynamic([e], is_nil(e.deleted_at))

def only_own(%Context{} = context) do
  user_id = CurrentUser.get!(context) |> InCodec.dump()
  dynamic([e], e.created_by_id == ^user_id)
end

def base_query do
  from(e in Schema, preload: [:children], order_by: [asc: e.created_at])
end
```

Композиция: `dynamic(^a() and ^b())`. Подключаются через `default_filters:` в `use Repo.Pg`.

## Write агрегата с событиями (`use Core.Repo.Pg.Es`)

Агрегат с событиями и outbox (с дочерними таблицами или без) MUST использовать `Repo.Pg.Es` —
надстройку над `Repo.Pg`. Руками `insert`/`update`/`save` не писать.

```elixir
use Repo.Pg.Es,
  behaviour: MyApp.Domain.<BC>.Common.<Aggregate>.Repo,
  schema: Schema,
  to_entity: &Schema.to_entity!/1,
  to_model: &Schema.to_model!/1,
  to_id: &Schema.dump_id/1,
  query: Specs.base_query(),
  default_filters: &Specs.default/1,
  shadow_copy?: true,
  id: Agg.ID,
  entity: Agg,
  errors: Agg.Errors,
  constraint_errors: [unique: [name: :already_exists]],
  event_repo: Agg.Event.Repo,
  outbox: Agg.Outbox,
  children: [
    [
      schema: Schema.Child,
      fk: :agg_id,
      constraint_errors: [agg_children_other_id_fkey: :unknown_other]
    ]
  ]
```

Свои опции (сверх опций `Repo.Pg`):

| Опция | Обяз. | Значение |
|---|---|---|
| `event_repo:` | да | модуль **behaviour** Event.Repo; реализацию макрос резолвит через `compile_env!` |
| `outbox:` | да | `<Aggregate>.Outbox` |
| `children:` | нет | `[[schema:, fk:, key:, constraint_errors:], …]`; строки — из `Schema.Child.to_models/1` |
| `entity:` | да | в `Repo.Pg` опциональна, здесь обязательна (по ней строятся заголовки) |

Что макрос генерирует (одна транзакция на запись):

1. `Repo.Pg.write_insert`/`write_update` — строка агрегата
2. дочерние строки через `Repo.Pg.Children` — точечно, а не перезаписью коллекции
3. flush: `<Aggregate>.Outbox.from_events` → `Event.Repo.append` → `Outbox.Repo.append`
4. возврат **входного** domain struct с очищенными `events`; он же кладётся эталоном в `Repo.Sc`
   (`Repo.Pg.put_baseline/3`)

Возвращается именно входной агрегат, не строка из БД: после `insert` у неё не прогружены `has_many`,
и возврат «перечитанного» потерял бы детей.

Поэтому шаг 1 идёт через `write_insert/4` / `write_update/4` (`:ok | {:error, _}`), а не через
`insert/4` / `update/4`: те декодируют строку обратно в domain через `to_entity`, а строка сразу
после `insert` содержит непрогруженные `has_many` — decode упал бы на доменной валидации
(«список шагов не может быть пустым»), хотя запись прошла успешно. Результат шага 1 всё равно
отбрасывается, так что decode здесь — лишняя работа с побочным эффектом.

Стратегия записи детей (`Core.Repo.Pg.Children`):

| Путь | Запросов на дочернюю таблицу |
|---|---|
| `insert/3` — родитель только что создан | `insert_all` (без `on_conflict`) |
| `update/3` с эталоном (`Repo.Sc`) | 0..2: `delete_all` исчезнувших ключей + upsert новых и изменившихся |
| `update/3` без эталона (`shadow_copy?: false` / агрегат не читался) | 2: `delete_all` всего, чего нет в наборе, + upsert набора |

Diff считается по обеим сторонам от одной и той же `to_models/1` (эталон-агрегат vs текущий), не по
строке из БД: jsonb после round-trip через Postgres получает строковые ключи, и diff был бы вечным.

Опции внутри `children:`:

| Опция | Обяз. | Значение |
|---|---|---|
| `schema:` | да | Ecto-схема с `to_models/1` |
| `fk:` | да | колонка внешнего ключа на агрегат (проверяется по схеме) |
| `key:` | нет | колонки, уникальные внутри агрегата; default — составной PK схемы без `fk` |
| `constraint_errors:` | нет | `[<имя constraint'а в БД>: <код>]`; у детей нет `changeset/2`, маппинг — по имени constraint'а. Коды проверяются compile-time по `errors:`, имена — тестом. FK на сам агрегат (колонка `fk:`) не мапится: строка родителя пишется той же транзакцией раньше |

Требования к дочерней схеме:

- `to_models/1` возвращает **все** колонки таблицы — пропущенную обнулит `on_conflict: {:replace, …}`;
- ключ уникален внутри набора: дубль — `ArgumentError` (при upsert он был бы тихим затиранием);
- `query:` агрегата прогружает дочерние ассоциации целиком и без фильтров — эталон в `Repo.Sc`
  это прочитанный агрегат, и неполный эталон даст diff с пропущенными удалениями.

`save/3` генерируется всегда: `Repo.Pg.save/4` зовёт `Repo.Pg.insert/update`, а не переопределённые
в модуле, то есть записал бы строку без детей и без событий.

## Role Repo vs common Repo.Pg vs Event.Repo

| Kind | Location | Purpose |
|---|---|---|
| Common `*.Repo.Pg` | `<bc>/common/<aggregate>/repo/pg.ex` | Shared **write** (row + children + events). Не role-scoped |
| Role `<Aggregate>.Repo` | `<actor>/<aggregate>/repo.ex`, … | Behaviour + ACL filters + CRUD reads via `use Repo.Pg` |
| Event.Repo | `*/event/repo` | Event store append/query; вызывается из write-path |

Правила:

- Role Repo **делегирует write** в common `Repo.Pg`, но имеет свои `default_filters` под ACL.
- Узкий actor-repo может не иметь `insert` (только update/save).
- Плоский агрегат с событиями: common write-репо — `use Core.Repo.Pg.Es` (отдельный ручной модуль не нужен).
- Identity/simple BC: часто один `Common.Repo` без role wrapper.
- Event.Repo API: `append/2`, `list_by_aggregate/2`, `page_by_aggregate/4`.

| Метод | Возврат |
|---|---|
| `append` | `:ok \| {:error, Error.t()}` |
| `list_by_aggregate` | `{:ok, [event]} \| {:error, Error.t()}` |
| `page_by_aggregate` | `{:ok, Pagination.Result.t(event)} \| {:error, Error.t()}` |

Чтение истории — **safe** (`Schema.to_entity/1` + `Result.traverse/2`), не `to_entity!`:
событие с неизвестным кодеку типом обязано стать доменным `:unknown_event_type`
(HTTP 400), а не уронить весь GET истории в 500. Bang-реконструкция остаётся на
write-path (`append`, восстановление агрегата).

## Event store (`use Core.Es.Event.Repo{,.Pg,.Pg.Schema}`)

Триплет event store целиком генерируется; руками — только `@moduledoc` и опции.

```elixir
defmodule …<Aggregate>.Event.Repo do
  use Es.Event.Repo,
    event: Agg.Event,
    aggregate_id: Agg.ID
end

defmodule …<Aggregate>.Event.Repo.Pg do
  use Es.Event.Repo.Pg,
    behaviour: Agg.Event.Repo,
    schema: Agg.Event.Repo.Pg.Schema,
    aggregate_id: Agg.ID,
    errors: Agg.Errors
end

defmodule …<Aggregate>.Event.Repo.Pg.Schema do
  use Es.Event.Repo.Pg.Schema,
    table: "<aggregate>_events",
    event: Agg.Event,
    aggregate_id: Agg.ID,
    by: User.ID,
    by_schema: User.Repo.Pg.Schema,
    payload_type: Types.JSON
end
```

- Колонки таблицы фиксированы: `id`, `type`, `payload`, `aggregate_id`, `aggregate_version`, `at`,
  `by_id`; индексы — `unique_index(aggregate_id, aggregate_version)` и индекс по `aggregate_id`.
- `changeset/2` у event-схемы **не** нужен: запись идёт только через `insert_all` + `to_model!`.
- `append/2` возвращает `:ok | {:error, Error.t()}`: конфликт по `(aggregate_id, aggregate_version)`
  (конкурентная запись) отдаётся доменным `:version_mismatch` из `<Aggregate>.Errors`, а не
  `Postgrex.Error`. Это единственная реальная защита от lost update — на строке агрегата
  `optimistic_lock` не используется.

Делегирование:

```elixir
def insert(%Agg{} = agg, %Context{} = context, opts \\ []),
  do: AggRepo.Pg.insert(agg, context, opts)
```

## Наименование

| Concern | Convention |
|---|---|
| Schema module | `…Repo.Pg.Schema` (+ nested leaf) |
| Table | plural snake: `<entities>`, `<entity>_<children>`, `outbox` |
| PK / FK | `:binary_id`; ids — UUID strings через `InCodec.dump/1` |
| Soft delete | `deleted_at` / `deleted_by_id` + Specs `not_deleted` |
| Events table | `<aggregate>_events`; колонки задаёт `Core.Es.Event.Repo.Pg.Schema` |

## DI

Доменные behaviour → реализация живут в app-env **потребителя**; `use Core.Repo.Pg.Es`
резолвит `event_repo:` там же, беря имя приложения из `config :core, otp_app:`
(`10-architecture.md`). Инфраструктурные реализации самой библиотеки — под `:core`.

```elixir
# config/config.exs потребителя
config :my_app, BehaviourModule, ImplModule
config :core, Core.Outbox.Repo, Core.Outbox.Repo.Pg

# потребитель
@repo Application.compile_env!(:my_app, BehaviourModule)
```

## Тесты

- `use Core.DataCase, async: true` (в приложении — его `MyApp.DataCase`)
- Sandbox: `Ecto.Adapters.SQL.Sandbox.start_owner!(repo, ...)` (в DataCase)
- `@repo Application.compile_env!(app, Behaviour)` — тестировать через behaviour env
- При `shadow_copy?: true`: `Context.new() |> Repo.Sc.init()`
- Доменные фабрики (`<Actor>.User.new`, `<Aggregate>.new`, …), не Ecto fixtures
- Outbox/процессы: при необходимости `Sandbox.allow(repo, self(), pid)`

## Связанные правила

- Архитектура / usecases — `10-architecture.md`
- Ошибки — `12-errors.md`
- События и outbox flush — `14-events-outbox.md`
- Кеш ReadRepo — `16-caching.md` свода приложения
- Миграции таблиц — `18-migrations.md` свода приложения
- Тесты репозиториев — `19-testing.md`
- Load/save в одной функции — `20-agreements.md`
