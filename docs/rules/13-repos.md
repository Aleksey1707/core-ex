# Репозитории

- **Область.** `lib/core/repo/**`, `lib/core/es/**`; у потребителя — `<aggregate>/repo*`,
  `read_repo*`, `view.ex`, Ecto-схемы и Specs.
- **Читать перед.** Новым репозиторием, Ecto-схемой или View; правкой `use Repo.Pg` /
  `Repo.Pg.StateStored` / `Es.Aggregate.Repo.Pg`, `constraint_errors`, `default_filters`;
  разделением read- и write-пути.
- **Словарь.** Плейсхолдеры и модальность — `00-index.md`.

## Слои и пути

| Слой | Пример модуля | Роль |
|---|---|---|
| Behaviour | `<BC>.Common.Repo`, `<Actor>.<Aggregate>.Repo` | `@callback` API; без SQL |
| Pg impl | `*.Repo.Pg`, `*.<Aggregate>.Repo.Pg` | PostgreSQL-реализация |
| Schema | `*.Repo.Pg.Schema` (+ nested `Schema.<Child>`, …) | Ecto schema; write — `to_entity`/`to_model` (+ bang), read — `to_view` |
| View | `<Aggregate>.View` (+ вложенный `.Codec`) | read-модель: примитивные значения + dump-only кодек |
| Specs | `*.Repo.Pg.Specs` | `dynamic` / `from` query fragments |
| Core | `Core.Repo`, `Core.Repo.Pg`, `Core.Repo.Pg.Children`, `Core.Repo.Sc` | генерация behaviour; generic CRUD; синхронизация дочерних строк; shadow copy |
| Core (ES) | `Core.Repo.Pg.StateStored`, `Core.Es.Aggregate.Repo`, `Core.Es.Aggregate.Repo.Pg`, `Core.Es.Aggregate.Process`, `Core.Repo.Pg.Schema`, `Core.Es.Store`, `Core.Es.Projection` | write-репо state-stored агрегата; behaviour и write-репо event-sourced агрегата; команда event-sourced агрегата; производные функции схемы; хранилище событий; проекция read-модели |

Раскладка этих модулей у потребителя — где лежат репозиторий, схема, Specs, View, `Outbox`,
процесс агрегата и проекция, — `deps/core/docs/rules/app/13-repos.md`, «Раскладка»; алиас
репозитория агрегата — `deps/core/docs/rules/app/20-agreements.md`, «Алиасы приложения».

## Read/Write репозитории

Наименование:

| Вид | Модуль | Файл |
|---|---|---|
| Запись | `<Aggregate>.Repo` / `Repo` (common) | `<aggregate>/repo.ex` / `repo.ex` |
| Чтение | `<Aggregate>.ReadRepo` / `ReadRepo` | `<aggregate>/read_repo.ex` / `read_repo.ex` |

### Write (`<Aggregate>.Repo`)

Содержит то, что нужно **изменяющему usecase**:

- `get` / `get!` — load одного агрегата перед mutate (`shadow_copy?: true` при необходимости).
- `insert` / `update` / `save` / `delete`.
- Опционально `list` / `find_many` / `get_many`, если изменяющий usecase мутирует **множество**
  агрегатов сразу (bulk: загрузить пачку → замутировать каждый → сохранить). Критерий: метод —
  источник данных для `mutate`, а не отдача наружу (HTTP/презентер). Загрузка пачки и её
  сохранение — в теле одной функции (см. «Load/save агрегата — в одной функции» в
  `20-agreements.md`).

- Кастомный `get_by_*` (резолв alternate key — `owner_id`, `login`, `external_id`) MUST принимать
  `version` (`%Version{} | :current`) и проверять её сам. Иначе call site вынужден делать второй
  `get(id, version)` — два SELECT ради одной проверки. Тело — один вызов `Repo.Pg.get_by/6`
  (`read_scope` + фильтр → `not_found` → `version_error` → capture):

  ```elixir
  @impl true
  def get_by_name(%Agg.Name{} = name, version, %Context{} = context, opts \\ [])
      when is_version(version) and is_list(opts) do
    Repo.Pg.get_by(@pg, Specs.by_name(InCodec.dump(name)), name, version, context, opts)
  end
  ```

Обычно **не** входят: `count` / `page` / `exists?` / `exists_all?` — это отдача наружу, место в
ReadRepo.

### Read (`<Aggregate>.ReadRepo`)

- `use Core.Repo, only: :read, view: <Aggregate>.View` — read-репо отдаёт **представление**, не
  агрегат.
- `shadow_copy?: false` в `Repo.Pg` (не участвует в optimistic-lock цепочке изменяющих usecases);
  `to_view:` вместе с `shadow_copy?: true` — `CompileError`: эталон в `Repo.Sc` — механизм
  write-пути, а `Repo.Sc.put/2` требует `id`, которого у представления может не быть.
- Декодер строки — `to_view: &Schema.to_view/1`; `to_model:` read-репо не нужен.
- Собственная Ecto-схема `<Aggregate>.ReadRepo.Pg.Schema` (MUST, см. «Generic `use Core.Repo.Pg`») и
  свои `Specs`.
- Читающие usecases (`get`/`list`/`page`, HTTP GET) вызывают **ReadRepo**.
- Изменяющие usecases вызывают **Repo** (в т.ч. internal `get` перед мутацией — это часть
  изменяющего usecase, а не чтение через ReadRepo).

Кеш — только на ReadRepo; см. `deps/core/docs/rules/app/16-caching.md`.

## View (read-модель)

Write-репозиторий работает с **агрегатом** на доменных Prim, read-репозиторий — с
**представлением** (View): структурой из примитивных значений.

View объявляется билдером `Core.View`: одна декларация полей порождает и структуру, и её
dump-only кодек.

```elixir
defmodule MyApp.Domain.<BC>.<Actor>.<Aggregate>.View do
  @moduledoc """
  Представление <Aggregate> для read-пути
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
        code: [prim: <Aggregate>.Stage.Code],
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

- Поле объявляется **тем Prim, которым оно живёт в домене**. Prim задаёт тип поля и его wire-формат
  (`Codec.Helper.dump_raw/3`: значение приводится к этому Prim с его kind, tz и precision, и
  дампится как обычный Prim) — но в структуру не попадает. Поэтому read-путь не может разойтись с
  агрегатным, а поле, добавленное в структуру, не может остаться недампленным: и то и другое
  порождает одна строка декларации.
- Поля — **только** примитивные значения и атомы `Core.Enum`. Prim во View — **MUST NOT**:
  read-путь не валидирует, а `Prim.new/1` на строке из БД поднял бы доменную ошибку там,
  где обработать её нечем (страница списка не должна падать из-за одной строки).
- Sensitive Prim в декларации — `CompileError`: чувствительному значению не место в
  read-модели. Prim с кастомным kind — тоже (типизировать нечем; поле объявляется `type:`).
- `version` — голое `pos_integer()` (у версионируемой таблицы). `%Version{}` живёт на **входе**
  (`If-Match` → `Version.parse/1` → `get(id, version, context)`), а не в результате.
- View **MUST NOT** попадать в write-путь: `insert` / `update` / `save` принимают агрегат.
  Собирать агрегат из View запрещено — он не проходил доменной валидации и не знает инвариантов.
- Имя модуля View и его файл — `deps/core/docs/rules/app/13-repos.md`, «Раскладка».
- Генерируются `@enforce_keys`, `defstruct`, `@type t` (точный: `String.t()`, `DateTime.t()`,
  `Decimal.t()`, `pos_integer()`, `<Enum>.t()`), именованные `@type` форм, `new/1` (keyword),
  маркер `__view__/0` и вложенный `<Aggregate>.View.Codec` — dump-only плагин (`loadable: false`),
  который регистрируется в реестре плагинов фасада. Презентер зовёт `OutCodec.dump(view)`
  (`deps/core/docs/rules/app/15-web-api.md`).
- `to_view/1` SHOULD собирать представление литералом `%View{...}` — неизвестный ключ там ловит
  компилятор. `new/1` — для динамической сборки; он отвергает ключ, не объявленный в `fields:`
  (`KeyError`, как и пропуск обязательного поля), иначе опечатка в имени необязательного поля
  ушла бы в API как `nil`.
- По `__view__/0` компилятор отличает представление от любой другой struct: его требуют
  `view:` в `use Core.Repo`, в `use Repo.Pg.Schema` и вложенное `view:` самого `Core.View`.
- Enum-поля кодек не сериализует (атомы как есть) — как и в `<Aggregate>.Codec`.
- Дамп тотален по значению на всю глубину: поле формы читается по atom- **или** одноимённому
  строковому ключу (`Helper.Map.field/2`), непустой не-map на месте формы и не-список на месте
  `list:` проходят как есть. Источник формы — jsonb-колонка, а после round-trip через Postgres
  её ключи строковые; падать на этом read-путь не имеет права. Обязательность поля формы держит
  `@type`, не рантайм.
- Дополнительные конструкторы (`empty/2` и т.п.) пишутся руками после `use` и зовут `new/1`.

### jsonb-нагрузка на read-пути

Полиморфная нагрузка (снимки, состояния шагов) в домен на read-пути **не разбирается**, но и
«как записана» наружу не отдаётся: она лежит в форме внутреннего профиля, а уйти обязана во
внешнем. Перевод делает `Core.Codec.Redump` по спеке формы
(`{:prim, Mod} | {:map, %{ключ => спека}} | {:list, спека} | {:tagged, %{тег => спека}}`).

- Спеку объявляет **тот кодек, который эту wire-форму пишет** (его функция
  `<форма>_redump_spec/0`), а не View: кто задал формат, тот его и описывает. Дублировать форму
  во View MUST NOT.
- Спека полиморфной нагрузки собирается из деклараций её источников, а не выписывается списком:
  иначе новый вариант нагрузки молча останется в старом формате.
- Ссылка из View — `jsonb: {Модуль, :функция}`, вызов идёт в рантайме: compile-зависимости
  View на кодеки не появляется.
- `jsonb:` типизируется `map()`. Массив нагрузок объявляется `list: [jsonb: {Мод, :спека}]` —
  тогда точен и тип (`[map()]`), и пере-дамп идёт поэлементно; спека в этом случае описывает
  **элемент**, а не список.
- Redump тотален по значению (неизвестный тег, отсутствующий ключ, неприводимое значение —
  как есть) и строг по спеке: нераспознанная спека — ошибка программиста.
- Форма MUST быть закрыта контрактным тестом «read-wire == агрегатный wire» (`19-testing.md`),
  а не описана комментарием.

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

Тип элемента — `item` в таблице ниже — задаёт опция: `entity:` (агрегат) или `view:`
(представление).

| Метод | Возврат |
|---|---|
| `get` | `{:ok, item} \| {:error, Error.t()}` |
| `get!` | `item`; ошибка → `raise Exc` |
| `list` / `count` | `[item]` / `non_neg_integer()` |
| `page` | `Pagination.Result.t(item)` |
| `insert` / `update` / `save` | `{:ok, entity} \| {:error, Error.t()}` |
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

Для агрегатов **без событий**, read-репо и role-reads. State-stored агрегат с событиями —
`Repo.Pg.StateStored` (см. ниже), он же пробрасывает все перечисленные опции внутрь.

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

`errors:` — модуль через родителя агрегата (`<Aggregate>.Errors`), не leaf-alias `Errors`.
Role `*.Repo.Pg` MUST NOT дублировать тексты ошибок.

`constraint_errors:` — опционально; keyword `[constraint_type: [field: error_code]]`. Типы: `unique`
/ `foreign_key` / `check` / `exclusion`. Коды проверяются compile-time через `errors.domain/3`.

Поле MUST соответствовать `*_constraint` в `changeset/2`: сверка идёт с `error_type` ошибки
changeset, а не с типом ограничения (`foreign_key_constraint/3` пишет `:foreign`) — перевод
делает макрос. Незаявленный в `changeset/2` маппинг молча не сработает, поэтому соответствие
деклараций — и у агрегата, и у `children:` — проверяется тестом (`19-testing.md`,
«`constraint_errors`»).

Составной unique-индекс Ecto регистрирует на **первое** поле списка `unique_constraint/3` (если
не задан `error_key:`), а сверка идёт по полю ошибки changeset: маппинг на остальные поля мёртв и
MUST NOT объявляться.

```elixir
# changeset/2: unique_constraint(changeset, [:owner_id, :name])

# плохо — ошибка changeset лежит на :owner_id, маппинг по :name не сработает никогда
constraint_errors: [unique: [name: :already_exists]]

# хорошо
constraint_errors: [unique: [owner_id: :already_exists]]
```

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
в одном шаге от read-пути. Цена — продублированный список полей; расхождение с миграцией
всплывает на тесте `to_view/1`.

Семантики:

- Чтение → domain через bang `to_entity` (опция `use Repo.Pg` — bang-mapper); при
  `shadow_copy?: true` — `Repo.Sc.put`.
- Чтение read-репо → View через тотальный `to_view` (`Repo.Sc` не участвует).
- Эталон Sc ключуется парой `{модуль сущности, id}` (`Repo.Sc.find(context, Entity, id)`): разные
  агрегаты могут делить идентификатор (агрегат, чей id — id другого агрегата).
- `Repo.Sc.init/1` / `clear/1` / `delete/1` возвращают контекст, и дальше работать нужно с
  возвращённым: контекст неизменяем, а старая копия держит уже удалённую ETS-таблицу (`put` / `find`
  по ней — no-op).
- `not_found` / `version_mismatch` / `incomplete_result` / `no_ids` →
  `errors.domain(behaviour, code, detail)`.
- `insert`/`update`/`save`: замапленный DB-constraint → `{:error, Error.t()}` через
  `errors.domain(behaviour, code, detail)`; незамапленный (и любой провал `changeset/2`) →
  `%Error{kind: :app, ns: :repo, code: :write_failed}`, который строит сам `Repo.Pg`:
  в `detail` — `%{schema:, errors: %{поле => [текст]}}` (`Repo.Pg.changeset_errors/1`).
  `Ecto.Changeset` наружу не выходит — контракт репозитория не знает про Ecto.
- `delete` — hard `delete_all` по scope; soft-delete — через update entity.
- Scope: `read_scope` = query + `default_filters`; `write_scope` = без order/preload/select.
- `insert`/`update`/`save` возвращают **входной** агрегат, а не декодированную строку: сразу
  после записи у строки не прогружены `has_many`, и её decode потерял бы детей. Он же уходит
  эталоном в `Repo.Sc` — регистрацией после commit (`Helper.AfterCommit.register/1`).
- Возврат — состояние, от которого мутируют дальше. Call site связывает его, если после записи
  продолжает работу с агрегатом (`save` → mutate → `save`); игнорирует, если на записи
  заканчивает — обычный случай по «Load/save агрегата — в одной функции» (`20-agreements.md`).
  Продолжать от **входного** значения MUST NOT: у агрегата с событиями они там не вычищены, и
  второй flush упрётся в занятую версию потока хранилища событий (`:version_mismatch`).

## Schema (`repo/pg/schema.ex`)

Обязательные конвенции:

- `@primary_key {:id, :binary_id, autogenerate: false}`
- `@foreign_key_type :binary_id`
- Явные `field :created_at/:updated_at/:deleted_at, :utc_datetime` — **не** `timestamps()`
- Optimistic lock: integer `version`

Только у схемы write-пути state-stored агрегата:

- Аудит FK: `created_by_id` / `updated_by_id` / `deleted_by_id` → `belongs_to` UserSchema
- Дочерние сущности — **отдельные таблицы** + `has_many`, **не** `embeds_*`

Таблицы read-модели проекций им не подчиняются — jsonb на read-пути легален
(`deps/core/docs/rules/app/13-repos.md`, «Проекции read-модели»).

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
schema "<entities>" do
  # ...
end

use Repo.Pg.Schema,
  entity: Agg,
  id: Agg.ID
```

`id:` — отдельная опция, не обязательно `<entity>.ID`: у агрегата, чей id — id другого
агрегата, это Prim того агрегата (`<Other>.ID`).

Режим `view:` — схема read-репозитория (`entity:` и `view:` взаимоисключающие):

```elixir
schema "<entities>" do
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

Safe — источник истины: при наличии entity-codec (`<Aggregate>.Codec` / `Outbox.Codec`) — **MUST**
`InCodec.load(Entity, attrs)` / `InCodec.dump(entity)`; Schema только remap колонок ↔ wire-ключи (+
DB-only FK / JSON string-keys). Без `Prim.new` / ручной сборки struct. Bang —
`Result.unwrap!(to_entity/to_model(...))` (`%Error{}` → `Exc`).

Когда какой вызов:

- Свои строки / persist валидного domain (`use Repo.Pg`, write-путь агрегата, …) → bang
  (`to_entity!` / `to_model!`).
- Dirty/infra (например Outbox `reserve_rows`) → safe (`to_entity` / `to_model`).

Опции `use Repo.Pg` `to_entity:` / `to_model:` — **bang-функции** (возврат entity/map):
`&Schema.to_entity!/1`, `&Schema.to_model!/1`.

В `to_entity`/`to_model` — `alias MyApp.Codec.Internal, as: InCodec` → полный
`InCodec.load(Entity, map)` / `InCodec.dump(entity)` через entity-codec; Schema remaps root-поля под
колонки БД (`created_by_id` ↔ `created_by`, …).

Changeset: `@required` / `@optional` через `~w(...)a` → `cast` → `validate_required` →
`foreign_key_constraint` (и `unique_constraint` при необходимости).

В `to_entity` поле `events: []` — события лежат в хранилище событий, не в строке агрегата.

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

## Write state-stored агрегата (`use Core.Repo.Pg.StateStored`)

State-stored агрегат с событиями и outbox (с дочерними таблицами или без) MUST использовать
`Repo.Pg.StateStored` — надстройку над `Repo.Pg`. Руками `insert`/`update`/`save` не писать.

```elixir
use Repo.Pg.StateStored,
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
  event_codec: Agg.Event.Codec,
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
| `event_codec:` | да | `<Aggregate>.Event.Codec`; его `type:` — тип агрегата в потоке хранилища событий |
| `outbox:` | да | `<Aggregate>.Outbox`; `event:` сверяется на компиляции с семейством кодека |
| `children:` | нет | `[[schema:, fk:, key:, constraint_errors:], …]`; строки — из `Schema.Child.to_models/1` |
| `entity:` | да | в `Repo.Pg` опциональна, здесь обязательна (по ней строятся заголовки) |
| `id:` | да | в `Repo.Pg` опциональна, здесь обязательна: сверяется на компиляции с Prim агрегата кодека |

Что макрос генерирует (одна транзакция на запись):

0. `written` — входной агрегат с очищенными `events`
1. `Repo.Pg.insert`/`update` — строка агрегата (эталоном в `Repo.Sc` уходит `written`)
2. дочерние строки через `Repo.Pg.Children` — точечно, а не перезаписью коллекции
3. flush: `<Aggregate>.Outbox.from_events` → `Core.Es.Store.append` → `Outbox.Repo.append`
4. возврат `written`

Очистка событий идёт **до** записи, а не после: эталоном `Repo.Pg.insert/4` кладёт то, что ему
передали, и очистка после записи разошлась бы с эталоном. В шаги 1 и 2 идёт `written`, в шаг 3 —
исходный агрегат: события нужны там непустыми.

`update` перед шагом 0 сверяет агрегат с эталоном `Repo.Sc`: состояние изменено, а событий нет —
`ArgumentError`. Версию проверяет только `append` хранилища событий (`optimistic_lock` на строке
агрегата нет), и мутация без события обошла бы эту проверку молча.

Непрерывность потока при записи не проверяется: поток state-stored агрегата MAY начинаться не с 1
(агрегат создан без события) и иметь разрывы — мутация без события, но только без эталона
(`shadow_copy?: false` или агрегат в этом контексте не читался). Отказ `append` —
`errors.domain(behaviour, :version_mismatch, %{aggregate_id, expected, actual})`, транзакция
откатывается целиком («Хранилище событий»).

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

- `to_models/1` возвращает **все** колонки таблицы — пропущенную обнулит
  `on_conflict: {:replace, …}`;
- ключ уникален внутри набора: дубль — `ArgumentError` (при upsert он был бы тихим затиранием);
- `query:` агрегата прогружает дочерние ассоциации целиком и без фильтров — эталон в `Repo.Sc`
  это прочитанный агрегат, и неполный эталон даст diff с пропущенными удалениями.

`save/3` генерируется всегда: `Repo.Pg.save/4` зовёт `Repo.Pg.insert/update`, а не переопределённые
в модуле, то есть записал бы строку без детей и без событий.

По `event_codec:` макрос генерирует и страницу потока агрегата `page_stream/4` («Страница потока»):
колбэка в `use Core.Repo` у неё нет, usecase зовёт её у реализации из `Core.Config.repo!/1`.

## Write event-sourced агрегата (`use Core.Es.Aggregate.Repo.Pg`)

Event-sourced агрегат (`11-domain.md`, «Event-sourced») хранится только событиями: строки
состояния нет, и репозиторий строится не на `Repo.Pg`. Behaviour — `use Core.Es.Aggregate.Repo`,
реализация — `use Core.Es.Aggregate.Repo.Pg`; `insert` / `update` / `save` у агрегата нет.

```elixir
defmodule MyApp.Domain.<BC>.Common.Account.Repo do
  use Core.Es.Aggregate.Repo,
    aggregate: MyApp.Domain.<BC>.Common.Account,
    id: MyApp.Domain.<BC>.Common.Account.ID
end

defmodule MyApp.Domain.<BC>.Common.Account.Repo.Pg do
  alias MyApp.Domain.<BC>.Common.Account

  use Core.Es.Aggregate.Repo.Pg,
    behaviour: MyApp.Domain.<BC>.Common.Account.Repo,
    aggregate: Account,
    id: Account.ID,
    errors: Account.Errors,
    outbox: Account.Outbox
end
```

Кодек событий берётся из `event_codec:` агрегата, отдельной опции нет; `repo:` и `codec:` —
опциональны, по умолчанию `Core.Config`; `snapshot:` — «Снапшоты» ниже. Реализация резолвится по
конвенции `<Behaviour>.Pg` («DI»).

Проверяется: `CompileError` в `use Core.Es.Aggregate.Repo.Pg` — нет `outbox:`, в `errors:` нет
clause `:version_mismatch`, Prim агрегата кодека не равен `id:`, событие `outbox:` не из
семейства кодека.

| Функция | Возврат | Исходы |
|---|---|---|
| `get(id, version, context)` | `{:ok, state} \| {:error, Error.t()}` | пустой поток при `:current` — `%Agg{id: id, version: nil}`; `%Version{}` мимо головы потока — `:version_mismatch`, у пустого `actual: nil` |
| `get_many(pairs, context)` | `{:ok, [state]} \| {:error, Error.t()}` | один запрос, состояния в порядке пар; все расхождения — одна `:version_mismatch`; повтор id — `ArgumentError` |
| `append(events, context)` | `:ok \| {:error, Error.t()}` | `[]` — без запросов; пачка потоков одного типа атомарна; событие не из `tags:` кодека — `FunctionClauseError` |
| `refresh(state, version, context)` | `{:ok, state} \| {:error, Error.t()}` | хвост потока после `state.version` → `fold/2` → сверка `version` |
| `page_stream(id, limit, offset, context)` | `{:ok, Pagination.Result.t(Es.Event)} \| {:error, Error.t()}` | «Страница потока» |

- `get` / `get_many` / `refresh` / `page_stream` — читающие, `append` — изменяющая: изменяющий
  usecase держит
  `get` → `Agg.execute/2` → `append` в теле одной функции под одним `Transact.run`
  (`20-agreements.md`, «Load/save агрегата — в одной функции»).
- `:not_found` репозиторий не отдаёт: существование агрегата решает `decide` по `version: nil`.
- Следующая команда той же функции MAY идти от состояния из `Agg.execute/2` без повторного `get`:
  оно уже учитывает записываемые события.
- `append` сам открывает `Transact.run(dao)`: `<Aggregate>.Outbox.from_events` →
  `Core.Es.Store.append` с непрерывностью потока → `Outbox.Repo.append`. Отказ —
  `errors.domain(behaviour, :version_mismatch, %{aggregate_id, expected, actual})`; у `get` /
  `refresh` detail той же формы, у `get_many` — их список в порядке пар. Реакция одна — повтор
  usecase.
- Нечитаемый поток (неизвестный тег, разрыв версий, чужой `aggregate_id`) у `get` / `get_many` /
  `refresh` — исключение, а не `{:error, _}`; `page_stream` отдаёт ошибку загрузки `{:error, _}`
  на всю страницу («Страница потока»).
- Форму результата вызывающему знает компилятор: головы — `%Agg.ID{}` / `%Agg{}`, `get` /
  `refresh` сужены до `{:ok, %Agg{}}`, `get_many` — до `{:ok, list}`, `append` — до `:ok`,
  `page_stream` — до `{:ok, %Pagination.Result{}}`. Чужой ID, опечатка в поле прочитанного
  состояния или страницы и невозможная clause — предупреждение при сборке; элементы списков
  `get_many`, `append` и страницы компилятор не сверяет. Переопределение функции
  (`defoverridable`) MUST сохранять закрытую голову и сужение (`20-agreements.md`, «Генерируемые
  функции»).

Репозиторий event-sourced агрегата MUST быть один — в common-слое (`common/<aggregate>/repo*`),
без `default_filters`, role-обёрток и `Repo.Sc`; доступ решают usecase (роли из `Context`) и
`decide` (владение по состоянию и `by` команды). Удаление агрегата — доменное событие, `delete`
нет.

```elixir
# плохо — role-обёртка фильтрует восстановленное состояние: доступ ушёл из usecase и decide
defmodule MyApp.Domain.<BC>.<Actor>.Account.Repo.Pg do
  def get(id, version, context, opts \\ []) do
    with {:ok, account} <- Common.Account.Repo.Pg.get(id, version, context, opts),
         :ok <- only_own(account, context),
         do: {:ok, account}
  end
end

# хорошо — один common-репозиторий; роль проверяет usecase, владение — decide по by команды
Transact.run(DAO, fn ->
  with {:ok, account} <- @repo.get(id, version, context),
       {:ok, {events, _account}} <- Account.execute(account, command) do
    @repo.append(events, context)
  end
end)
```

### Снапшоты

Длинный поток MAY читаться от снапшота: `snapshot: [every: N, version: V]` в
`use Core.Es.Aggregate.Repo.Pg`. `every:` обязателен и без значения по умолчанию, `version:` —
целое, по умолчанию 1; без опции снапшоты выключены.

```elixir
use Core.Es.Aggregate.Repo.Pg,
  behaviour: MyApp.Domain.<BC>.Common.Account.Repo,
  aggregate: Account,
  id: Account.ID,
  errors: Account.Errors,
  outbox: Account.Outbox,
  snapshot: [every: 100]
```

- Снапшот — кэш свёртки в `es_snapshots`, а не источник истины: удаление строк корректность не
  меняет, версию проверяет `append`. Инструмента очистки нет — подъём `version:` или `DELETE`.
- `get` / `get_many` / `refresh` читают снапшот и хвост потока после него тем же одним запросом.
  Свернули у потока не меньше `every` событий — upsert после commit, вне транзакции — сразу;
  `append` снапшоты не пишет. Эта запись — наполнение кэша, наблюдаемого результата она не
  меняет: `get` остаётся читающей (`20-agreements.md`, «Разделение изменения и чтения»).
- Отказ снапшота (не читается, ключи struct не совпали, `fold/2` от него упал) — `warning` и
  полная свёртка, а не ошибка.
- Маркер снапшота — md5 модуля агрегата, кодека событий и модулей событий плюс `version:`: правка
  этих модулей сбрасывает снапшоты сама. Если `evolve` зависит от кода вне них, правка такого кода
  MUST поднимать `version:` — иначе свёртка продолжится от состояния, собранного старым кодом.

```elixir
# evolve считает лимит модулем вне агрегата, кодека и событий
def evolve(state, %Event.Deposited{payload: payload}),
  do: %{state | limit: Account.Limits.after_deposit(state.limit, payload.amount)}

# плохо — логика Account.Limits поменялась, а version: прежний: снапшоты старой логики живут дальше
snapshot: [every: 100]

# хорошо — правка Account.Limits ушла вместе с подъёмом version:
snapshot: [every: 100, version: 2]
```

Проверяется: `CompileError` в `use Core.Es.Aggregate.Repo.Pg` — `snapshot:` без `every:`, с
неизвестной опцией, `every:` не целое больше нуля или `version:` не целое.

### Процесс агрегата

Команду одного event-sourced агрегата MAY исполнять `Agg.Process.execute` вместо тела usecase
`get` → `Agg.execute/2` → `append`. Модуль `use Core.Es.Aggregate.Process, repo: Agg.Repo` лежит
рядом с репозиторием (`common/<aggregate>/process.ex`), реализация `repo:` резолвится по конвенции
(«DI»), элемент `{Agg.Process, enabled: …}` ставит дерево потребителя. Опции, исходы и
наблюдаемость — moduledoc `Core.Es.Aggregate.Process`.

```elixir
defmodule MyApp.Domain.<BC>.Common.Account.Process do
  use Core.Es.Aggregate.Process,
    repo: MyApp.Domain.<BC>.Common.Account.Repo
end

# usecase — транзакцию открывает execute
Account.Process.execute(id, version, command, context, fn events ->
  Notifications.enqueue(events, context)
end)
```

- `execute` — изменяющая, `:ok | {:error, Error.t()}`: `get(id, version, context)` →
  `Agg.execute/2` → `append` → `fun.(events)` одной транзакцией `Core.Config.dao/0`; процесс на id
  (`enabled: true`) после первой команды вместо `get` дочитывает хвост `refresh(state, version,
  context)` от состояния последнего commit. При `enabled: false` команда идёт тем же путём в
  вызывающем процессе, без процесса на id.
- Колбэк `fun.(events)` → `:ok | {:error, _}` — сопутствующие записи (Oban, `DAO`) в транзакции
  команды, под ограничениями `Transact.run` (`20-agreements.md`, «Разделение изменения и
  чтения»): отказ колбэка откатывает и события, при повторе колбэк зовётся заново.
- `:version_mismatch` из `append` при `:current` повторяется новой транзакцией до `retries:`;
  `%Version{}` мимо головы потока — `:version_mismatch` без повтора: клиент видел устаревшее
  состояние, и повтор его не исправит.
- Внутри `Transact.run` MUST NOT вызываться: транзакцию открывает сам `execute`, и откат его
  попытки отменил бы внешнюю (`ArgumentError`; `20-agreements.md`, «Разделение изменения и
  чтения (CQS)»).
- Команда на несколько агрегатов MUST идти путём usecase → repo: процесс исполняет команду одного
  агрегата, а атомарность нескольких `append` даёт только одна транзакция usecase
  («Load/save агрегата — в одной функции», `20-agreements.md`).

```elixir
# плохо — две команды процессов в транзакции usecase: ArgumentError, а атомарности нет и так
Transact.run(DAO, fn ->
  with :ok <- Account.Process.execute(from, :current, withdraw, context),
       do: Account.Process.execute(to, :current, deposit, context)
end)

# хорошо — команда на два агрегата: usecase → repo одной транзакцией
Transact.run(DAO, fn ->
  pairs = [{from, :current}, {to, :current}]

  with {:ok, [source, target]} <- @repo.get_many(pairs, context),
       {:ok, {withdrawn, _source}} <- Account.execute(source, withdraw),
       {:ok, {deposited, _target}} <- Account.execute(target, deposit) do
    @repo.append(withdrawn ++ deposited, context)
  end
end)
```

## Хранилище событий (`Core.Es.Store`)

Хранилище событий одно на приложение — таблица `es_events`, DDL — `Core.Es.Migration`; общее для
event-sourced и state-stored агрегатов. Поток — тип агрегата (`type:` кодека событий) и
`aggregate_id`, таблицы потоков нет; своей таблицы событий (`<aggregate>_events`) и модуля
`<Aggregate>.Event.Repo` у агрегата MUST NOT. Глобальная позиция — пара `(xid, number)`:
сортировать события по одному `number` MUST NOT, номер выдаётся до commit. Решение и цена —
`docs/adr/0008-shared-event-table-xid8-position.md`.

`Core.Es.Store.append(event_codec, events, context, mismatch, opts)` пишет пачку событий нескольких
потоков одного типа агрегата в транзакции `DAO` вызывающего. Пачка отвергается, если хоть одно
событие не прошло проверку:

| Проверка | Отказ |
|---|---|
| unique `(aggregate_type, aggregate_id, aggregate_version)` | версия занята конкурентной записью |
| страж `xid` | в потоке есть событие транзакции с `xid` больше текущей — иначе выдача по позиции переставила бы версии потока |
| `continuous?: true` (`Es.Aggregate.Repo.Pg`) | первая версия потока в пачке не равна наибольшей версии потока + 1 (у пустого — не 1) |

- `Core.Es.Store.append` MUST NOT вызываться вне write-builder'ов библиотеки
  (`use Core.Repo.Pg.StateStored`, `use Core.Es.Aggregate.Repo.Pg`) и тестов самого
  `Core.Es.Store`; MAY — тестовые дублёры в `test/support`. Usecase читает поток только через
  `page_stream/4` репозитория агрегата («Страница потока»).
- Любой отказ — `{:error, mismatch.(detail)}` с detail `%{aggregate_id, expected, actual}`: ns и
  код ошибки задаёт вызывающий write-репозиторий (`errors.domain(behaviour, :version_mismatch, _)`),
  а не хранилище.
- Отказ не переводит транзакцию в aborted, но события, прошедшие проверки, к нему уже записаны:
  write-builder MUST возвращать `{:error, _}` от `append` из `Transact.run`, откатывая транзакцию.
- Версии потока в пачке не по возрастанию (с `continuous?: true` — не подряд) и событие не из
  `tags:` кодека — исключение, а не `:version_mismatch`: это ошибка программиста.
- Схема `es_events` в `Core.Es.Migration` меняется только аддитивно — новая nullable-колонка,
  новый индекс `concurrently`; переименование и удаление колонок, изменение семантики нагрузки
  MUST NOT: таблица append-only с исторической нагрузкой, а у потребителя её DDL накатывает его
  собственная миграция (`deps/core/docs/rules/app/18-migrations.md`, «Таблицы библиотеки»).

```elixir
# плохо — отказ проглочен: транзакция закоммитит строку агрегата и часть пачки
with {:ok, _} <- Repo.Pg.update(@pg, written, context, opts) do
  _ = Store.append(@event_codec, events, context, &version_mismatch/1)
  Config.outbox_repo().append(records, context, opts)
end

# хорошо — `{:error, _}` выходит из `Transact.run` и откатывает транзакцию
with {:ok, _} <- Repo.Pg.update(@pg, written, context, opts),
     :ok <- Store.append(@event_codec, events, context, &version_mismatch/1) do
  Config.outbox_repo().append(records, context, opts)
end
```

## Страница потока

`@repo.page_stream(id, limit, offset, context)` →
`{:ok, Pagination.Result.t(Es.Event)} | {:error, Error.t()}` — страница потока одного агрегата: по
возрастанию `aggregate_version`, `count` — весь поток. Её генерирует write-репозиторий агрегата
любого вида: `use Core.Es.Aggregate.Repo.Pg` (колбэк `use Core.Es.Aggregate.Repo`) и
`use Core.Repo.Pg.StateStored` (по `event_codec:`). Тип агрегата и семейство событий — из кодека
агрегата, `context` не используется. Читающий usecase зовёт её у репозитория, мимо ReadRepo. В
именах и текстах библиотеки — «страница потока» / «чтение потока»; называть поток «историей»
MUST NOT: «история» — имя экрана у потребителя (`CONTEXT.md`, «Поток событий»).

- Голова принимает только `%Agg.ID{}`, результат сужен до `{:ok, %Pagination.Result{}}`: ID другого
  агрегата, опечатка в поле страницы и невозможная clause — предупреждение при сборке. Реализацию
  `Core.Es.Store.read_stream/5` (`@doc false`) звать из usecase MUST NOT: кодек и ID в ней —
  параметры, сборка их не сверяет, и ID другого агрегата молча даёт пустую страницу.
- `page_stream` доступ не проверяет и `:not_found` не отдаёт: пустой поток — страница с
  `count: 0`. Читающий usecase MUST до чтения проверить права по `Context`, а существование
  агрегата — авторитетным для этого агрегата источником
  (`deps/core/docs/rules/app/13-repos.md`, «Страница потока»).
- Элемент страницы — `Es.Event`, а не View (отступление от «Read (`<Aggregate>.ReadRepo`)»): Prim
  события не ужесточается, и проверенное на записи событие грузится —
  `docs/adr/0010-event-evolution-tag-upcast.md`. Наружу событие отдаёт презентер:
  `OutCodec.dump` → `Es.Event.Codec.to_fields/1`.
- Строки грузятся фасадом с апкастом; первая ошибка `load` (`:unknown_event_type`,
  `:invalid_envelope`) — `{:error, _}` на всю страницу. Событие не пропускается: иначе `count`
  разойдётся со страницей.
- Поток нескольких агрегатов или типов на одном экране хранилище не даёт: это проекция потребителя
  и ReadRepo над её read-моделью, фильтры и построчный ACL — там же.

```elixir
# плохо — чтение по голому id: наружу уходит страница чужого или удалённого агрегата
def history(%Agg.ID{} = id, limit, offset, %Context{} = context),
  do: @repo.page_stream(id, limit, offset, context)

# хорошо — права и существование агрегата (здесь авторитетна строка ReadRepo) проверены до чтения
def history(%Agg.ID{} = id, limit, offset, %Context{} = context) do
  with {:ok, _view} <- @read_repo.get(id, :current, context) do
    @repo.page_stream(id, limit, offset, context)
  end
end

# плохо — реализация хранилища: ID другого агрегата собирается и молча даёт пустую страницу
Core.Es.Store.read_stream(Agg.Event.Codec, other_id, limit, offset, context)

# хорошо — репозиторий агрегата: на ID другого агрегата сборка даёт
# warning: incompatible types given to MyApp.Domain.<BC>.Common.<Aggregate>.Repo.Pg.page_stream/4
@repo.page_stream(id, limit, offset, context)
```

Проверяется: предупреждение при сборке вызывающего — ID другого агрегата, опечатка в поле страницы,
невозможная clause по результату `page_stream/4` репозитория event-sourced агрегата
(`make consumer-check`).

## Наименование

Имена схем и таблиц, ключи и soft delete — `deps/core/docs/rules/app/13-repos.md`,
«Наименование»; таблицы библиотеки — `es_events` и `es_snapshots` («Хранилище событий»,
«Снапшоты»), колонки задаёт `Core.Es.Migration`.

## DI

Реализация репозитория выводится из имени behaviour по конвенции **`<Behaviour>.Pg`**.
Ключ в конфигурации нужен только тому, кто подменяет реализацию. Мотивация и цена —
ADR-0006.

Call site MUST резолвить реализацию через `Core.Config.repo!/1`; прямой
`Application.compile_env!/2` на доменный behaviour — MUST NOT (две легальные формы
возвращают тот же разнобой, только в коде вместо конфига):

```elixir
alias Core.Config

require Config

@repo Config.repo!(MyApp.Domain.Orders.Order.Repo)
```

Реализация репозитория MUST лежать в `<Behaviour>.Pg` — та же раскладка, что задаёт
`deps/core/docs/rules/app/13-repos.md`, «Раскладка». Нестандартная реализация объявляется в
app-env **потребителя**, под именем приложения из `config :core, otp_app:`
(`10-architecture.md`):

```elixir
# config/config.exs потребителя — только при подмене
config :my_app, MyApp.Domain.Orders.Order.Repo, MyApp.Domain.Orders.Order.Repo.Memory
```

Модуль-реализация проверяется на компиляции call site — и выведенный по конвенции, и
заданный ключом: отсутствие даёт `CompileError`, а не `UndefinedFunctionError` на первом
вызове. Цена — ребро в графе компиляции call site → реализация.

Аргумент `repo!/1` MUST быть литералом модуля: имя реализации вычисляется на компиляции, и
переменная (например, цикла) ему не годится — таблица реализаций выписывается поимённо.

```elixir
# плохо — переменная цикла: имя `<Behaviour>.Pg` на компиляции не вычислить
for behaviour <- [Order.Repo, Invoice.Repo], do: Config.repo!(behaviour)

# хорошо
@order_repo Config.repo!(MyApp.Domain.Orders.Order.Repo)
@invoice_repo Config.repo!(MyApp.Domain.Orders.Invoice.Repo)
```

Инфраструктурный репозиторий самой библиотеки живёт по той же конвенции:
`Core.Config.outbox_repo/0` (`config :core, Core.Outbox.Repo` — только при подмене).

Норму проверяет линтер библиотеки в режиме потребителя — ключ `<...>.Repo` в `compile_env`
и есть связывание руками (прочие ключи-модули — обычная конфигурация, линтер их не трогает):

```bash
elixir deps/core/scripts/boundary_lint.exs --consumer lib test
```

## Тесты

Тесты репозиториев — `19-testing.md`.

## Связанные правила

- Архитектура / usecases — `10-architecture.md`
- Ошибки — `12-errors.md`
- События и outbox flush — `14-events-outbox.md`
- Кеш ReadRepo — `deps/core/docs/rules/app/16-caching.md`
- Миграции таблиц — `deps/core/docs/rules/app/18-migrations.md`
- Тесты репозиториев — `19-testing.md`
- Load/save в одной функции — `20-agreements.md`
