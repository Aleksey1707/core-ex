# Домен

Плейсхолдеры: `MyApp`, `<BC>`, `<Aggregate>` — см. `10-architecture.md`.

Строительные блоки: `core/prim`, `core/enum`, `core/validator`, `core/codec` (+ `core/codec/redump`), `core/view`, `core/context`, `core/es`, `Version`, `Pagination`, `Result`/`Option`, `MyApp.Codec.Prim.{Internal,External}`, `MyApp.Codec.{Internal,External}` (entity-фасады).

## Prim (value object)

`Core.Prim` — макрос value object: `%Mod{value:}`, `new/1`, `new!/1`, `value/1`, `__domain_kind__/0`, `__domain_type_opts__/0`, `prim?/1` (модуль).

```elixir
use Core.Prim,
  cast: ...,
  name: ...,
  kind: ...,
  mutate: ...,
  validate: ...,
  custom_mutate: ...,
  custom_validate: ...,
  sensitive: ...
```

`kind` обязателен. Конвейер: `cast → mutate → custom_mutate → validate → custom_validate`.

`sensitive: true` (default `false`) — значение Prim скрыто от `inspect/1`, а в `Error.detail`
вместо raw уходит `{:redacted, byte_size}`. Обязательна для паролей, токенов, ключей, ПДн;
`Prim.Compose` наследует её от базового Prim. Детали и чек-лист — `12-errors.md`.

| Функция | Возврат |
|---|---|
| `new/1` | `{:ok, t()} \| {:error, Error.t()}` |
| `new!/1` | `t()`; при ошибке — `raise Exc, error` |
| `value/1` | внутреннее значение |
| `__domain_kind__/0` | атом kind для Codec |
| `__domain_type_opts__/0` | опции типа (`precision`, `tz`, границы) — их читает `Codec.dump_raw_as/2` на read-пути |
| `Prim.prim?/1` | модуль объявлен через `use Prim` (`__domain_kind__/0` + `value/1`); при необходимости загружает модуль |

В function heads: обязательный Prim — `%Mod{}` (default); композиция в `when` — `Core.Guard.is/2` / `is_opt/2` (`import`, не guards на самом Prim).

Ошибки валидации: `{:error, {code, detail}}` → `Error.domain(module, code: code, ns: :prim, message: "#{name}: #{detail}", detail: raw)` (в `Error.detail` — исходный raw; `detail` в кортеже — текст валидации).

### Типизированные обёртки

`Prim.String` / `Integer` / `Decimal` / `UUID` / `DateTime` / `Date` / `Compose` + `Core.Validator.*` (sibling, не под Prim).

`Prim.DateTime` дополнительно: `now/0` / `now!/0`, `from/1` / `from!/1` — конверсия **из другого datetime-Prim** (явный API; `new/1` принимает только raw `%DateTime{}` / ISO8601, не другой Prim).

`Prim.Date` — дата без времени: `today/0` / `today!/0` (в `tz:` модуля или `Core.Config.tz/0`), `from/1` / `from!/1` — конверсия **из другого date- или datetime-Prim** (datetime приводится к дате в том же tz). `new/1` принимает только raw `%Date{}` / ISO8601 — ни `%DateTime{}`, ни другой Prim. Опции: `after:` / `before:` (`%Date{}`), `tz:`; `precision:` нет.

`Prim.Compose` — обёртка над другим Prim (`of:`): `%Mod{value: %Base{}}`. Kind по умолчанию `:composite` (`Prim.reserved_kinds/0`). Дополнительно: `__domain_base__/0`, `raw/1` (через `Prim.unwrap/1`). `new/1` принимает raw базы, `%Base{}` или `%Mod{}` (идемпотентно). Вложенная композиция допустима (`of:` может быть Compose).

Native kinds: `:string`, `:integer`, `:decimal`, `:uuid`, `:datetime`, `:date` (`Prim.native_kinds/0`). Reserved: native + `:composite`. Опциональный `kind:` — свой атом (не чужой reserved; проверка `Prim.validate_kind!/2`); тогда в профилях Codec нужны `dump(%Mod{})` и/или `dump_kind(prim, kind)`.

Правило `name:`: брать из первой строки `@moduledoc` через `Helper.String.first_line/1`.

Примитивы объявлять **вложенными модулями** внутри агрегата:

```elixir
defmodule MyApp.Domain.<BC>.Common.<Aggregate> do
  defmodule Name do
    @moduledoc """
    Название сущности
    """

    use Core.Prim.String,
      name: first_line(@moduledoc),
      min_len: 5,
      max_len: 50
  end
end
```

## Enum (закрытое множество атомов)

`Core.Enum` — макрос enum: значение — **голый атом** (не `%Mod{value:}`), SSOT для Dialyzer (`@type t`) и runtime.

```elixir
defmodule Status do
  @moduledoc """
  Статус черновика

  | Значение | Описание |
  |---|---|
  | `:new` | создан, на согласование не отправлен |
  | `:in_approving` | отправлен на согласование, решения ещё нет |
  | `:approved` | согласован |
  | `:rejected` | отклонён согласующим |
  | `:failed` | согласование сорвалось по технической причине |
  | `:done` | работа по черновику завершена |
  """

  use Core.Enum,
    name: first_line(@moduledoc),
    values: ~w(new in_approving approved rejected failed done)a
end
```

Обязателен `name:` и ровно один источник значений: `values:` либо `codes:`
(см. «Внешние коды»). Задать оба — `CompileError`.

| Функция | Возврат |
|---|---|
| `values/0` | список атомов |
| `member?/1` | `boolean()` |
| `cast/1` | `{:ok, t()} \| {:error, Error.t()}` (`ns: :enum`, `:invalid_value`) |
| `cast!/1` | `t()`; при ошибке — `raise Exc` |
| `cast_optional/1` | как `cast/1`; `nil` → `{:ok, nil}` |
| `cast_optional!/1` | как `cast_optional/1`; при ошибке — `raise Exc` |
| `dump/1` | wire-строка (`Atom.to_string/1`); `nil` → `nil` |
| `name/0` | строка для message |

### Описание значений в `@moduledoc`

Каждое значение MUST быть описано строкой таблицы в `@moduledoc` своего модуля.
Имя атома — это ярлык, а не объяснение: `:failed` не говорит, чем отличается от
`:rejected`, а `:railcar` — чем от `:truck`. Читателю, который видит enum впервые,
разбираться неоткуда: закрытое множество на то и закрытое, что смысл значений
задан только договорённостью.

- формат — `| Значение | Описание |`; у enum с `codes:` добавляется колонка `Код`;
- описание — строчными, без точки в конце, одна строка на значение;
- значение, выведенное из обращения внешним источником, MUST быть помечено
  («выведен из обращения в 2015 году») — иначе читатель примет его за действующее;
- первая строка `@moduledoc` остаётся именем enum: из неё `first_line/1` берёт
  `name:`, который уходит в тексты доменных ошибок. Таблица идёт **после** неё.

Проверяется тестом `test/my_app/enum_docs_test.exs`: не описанное значение и
описанное несуществующее валят сборку (см. `19-testing.md`).

### Внешние коды (`codes:`)

Если значения нумерует или именует внешний источник, маппинг задаётся опцией `codes:` —
картой `%{atom => code}`, а не отдельной функцией рядом с модулем.

```elixir
# целочисленные коды
use Core.Enum,
  name: first_line(@moduledoc),
  codes: %{human: 1, car: 2}

# строковые коды справочника внешнего источника
use Core.Enum,
  name: first_line(@moduledoc),
  codes: %{human: "HUMAN", car: "CAR"}
```

`values:` при этом **не задаётся**: карта уже перечисляет все значения, и второй
список тех же атомов пришлось бы держать в синхронности с ней. `values/0` выводится
из ключей и упорядочивается **по коду** — так список читается рядом с выгрузкой
источника, а порядок не зависит от внутреннего устройства map.

Добавляет `@type code`, `codes/0` (карта `значение => код`), `to_code/1`, `from_code/1`
(`{:ok, t()} | {:error, Error.t()}`) и `from_code!/1`.

| Тип кодов | `from_code/1` принимает | Не принимает |
|---|---|---|
| целые | целое и его строковую запись (`20` и `"20"`) | прочее → `FunctionClauseError` |
| строки | строку, совпадающую **точно** | целое → `FunctionClauseError` |

Коды в карте MUST быть одного типа: смешанная карта делает `from_code/1` неоднозначным
(`"5"` пришлось бы искать и как строку, и как число) — `CompileError`. По той же причине
у строковых кодов нет приведения из числа и нормализации регистра: `"WEIGHT"` и `"weight"` —
разные коды, а строковый код `"5"` не то же самое, что целочисленный `5`. Нормализация
внешнего ввода — задача границы, а не enum.

Карта не должна содержать повторов кодов и пустых строк — иначе `CompileError`.
Пропуски в нумерации источника (изъятые из обращения значения) воспроизводятся
как есть: `from_code/1` на них отдаёт доменную ошибку.

Коды MUST сверяться с выгрузкой источника, а не выписываться по памяти, и MUST быть
покрыты round-trip-тестом по всем `values/0` (`19-testing.md`).

В function heads для enum использовать `Core.Guard` (через `import`):

```elixir
import Core.Guard

when is_enum(status, Status)
when in_enum(status, Status, ~w(new failed)a)
```

`is_enum/2` / `in_enum/3` — макросы (compile-time `mod.values()` / проверка subset ⊆ values). Guard форсирует `Code.ensure_compiled/1` для enum-модуля (чистая сборка). Опечатка в subset → `CompileError`.

Wire: atom или binary (`Atom.to_string/1`). Schema: `Ecto.Enum, values: Status.values()`. Агрегат: `status: Status.t()`.

### Codec (Prim и Entity)

Слои (Core **не** ссылается на Domain; Domain/app ссылаются на Core):

| Слой | Модуль | Роль |
|---|---|---|
| Core | `Core.Codec` | билдер Prim-профиля: `dump` / `load` / `load!` |
| Core | `Core.Codec.Plugin` | behaviour entity-плагина (`@callback` + `use`) |
| Core | `Core.Codec.Helper` | хелперы load/dump для потребителей фасада |
| Core | `Core.Codec.Facade` | билдер entity-фасада (`prim:` + `plugins:`) |
| App Prim | `Codec.Prim.{Internal,External}` | профили примитивов |
| App Facade | `Codec.{Internal,External}` | единая точка вызова (Prim + entity) |
| Domain | `<Aggregate>.Codec` | кодек агрегата и вложенных сущностей (`dump`/`load`) |
| Domain | `<Aggregate>.Event.Codec` | кодек событий (dump в фасаде; load_event с envelope) |
| Domain | `<Aggregate>.Cmd.Codec` | кодек команд (`tagged: true`) |
| Domain | `<Aggregate>.View.Codec` | кодек представления read-пути (dump-only, `loadable: false`) |

Prim-профили:

| Профиль | uuid | datetime | datetime_tz | date | decimal |
|---|---|---|---|---|---|
| `Codec.Prim.Internal` | `:full` | `:datetime` | `"Etc/UTC"` | `:date` | `:decimal` |
| `Codec.Prim.External` | `:hex` | `:iso8601` | `:app` | `:iso8601` | `:string` |

Оси datetime: `datetime:` — форма (`:datetime` → `%DateTime{}`, `:iso8601` → строка); `datetime_tz:` — `:keep`, `:app` (tz приложения из `Core.Config.tz/0`, резолв в рантайме) или IANA binary (`DateTime.shift_zone!/2` на dump); точность — `precision: :second | :millisecond | :microsecond` (default `:second`) в `use Prim.DateTime` (как у `DateTime.truncate/2`), не кодек.

`date:` — форма даты без времени (`:date` → `%Date{}`, `:iso8601` → строка). Единственная **необязательная** опция профиля (default `:date`): профили, объявленные без неё, продолжают работать.

Приоритет Prim dump: `dump(%Mod{})` → `dump_kind(prim, kind)` → builtin.
Приоритет Prim load: `load(mod, raw)` → `load_kind` → builtin → `mod.new/1`.
Kind `:composite` (`Prim.Compose`): dump → `dump(value)` (рекурсия до leaf); load → `load(base, raw)` + `mod.new(inner)`. Wire-формат композита = формат базового Prim.
Профиль влияет только на dump; load формат-агностичен (приведение — `cast` примитива).

Entity-фасад (`alias Codec.Internal, as: InCodec`):

```elixir
use Core.Codec.Facade,
  prim: MyApp.Codec.Prim.Internal,
  plugins: [MyApp.Domain.<BC>.Common.<Aggregate>.Codec]
```

- `dump/1` / `load/2` / `load!/2` — plugin clauses, иначе делегат в `prim` (только `struct()`; не-Prim без плагина → `ArgumentError`)
- `dump_raw/2` — делегат в `prim.dump_raw(kind, raw)`: тот же wire-формат для значения **без** Prim-обёртки (`:uuid` / `:datetime` / `:date` / `:decimal`). Для read-моделей (`<Aggregate>.View.Codec`); внутри плагина — `dump_raw_optional/3`
- `dump_raw_as/2` — то же, но формат берётся у **конкретного Prim**: kind плюс его `__domain_type_opts__/0` (tz и precision). Одного kind мало — значение из колонки `utc_datetime_usec` отдало бы дробные секунды там, где Prim с `precision: :second` их обрезает. Тотальна: `nil` и неприводимое значение проходят как есть. На неё опираются `Core.View` и `Core.Codec.Redump`
- `load_tagged/2` есть у фасада всегда; lookup по `tags:` map tagged-плагинов; неизвестный тег → `:unknown_tagged_type`, некорректный вход → `:invalid_tagged_input`; коллизии тегов/types между плагинами — `CompileError`
- Plugin: `use Core.Codec.Plugin, types: [...]` **или** `tags: %{Mod => "tag"}` (XOR); `loadable: true|false`; `tagged: true` требует `tags:` map + `load_tagged/3`; `loadable: true` требует `load/3` (compile-time)
- Из `tags:` map генерируются `__codec_types__/0`, `__codec_tags__/0`, `type/1`, `types/0`, `mod_by_tag/1`
- `loadable: false` — dump-only (как `<Aggregate>.Event.Codec`: load через `load_event!/8`)
- Хелперы плагина (импорт при `use`): `field/2` — из `Core.Helper.Map` (generic-аксессор map по atom-или-string ключу, доступен любому коду); `dump_optional/2` / `load_optional/3` / `load_many/3` — из `Core.Codec.Helper`. В Ecto-схемах `field/2` **не** импортировать (конфликт с `Ecto.Schema`) — звать `Helper.Map.field/2`
- Enum-поля кодек не сериализует (атомы как есть)
- `<Aggregate>.Codec` MUST предоставлять `dump`/`load` для самого агрегата и его вложенных сущностей (если есть). Поле `events` в dump/load агрегата **не** участвует (события — только через `<Aggregate>.Event.Codec`). `Repo.Pg.Schema` **обязан** вызывать фасад (`InCodec.load` / `InCodec.dump`) сущности; Presenter может мапить поля вручную под shape API. Core entity-codecs (например `Outbox.Codec`) регистрируются в app `Codec.plugins()` наравне с Domain.

Кастом Prim в профиле: `@impl true def dump(%Agg.ID{})`, optional `dump_kind` / `load_kind` + `super`.

## Aggregates

Правила:

- Версионируются через `Version` (optimistic lock).
- Soft-delete: `deleted_at` / `deleted_by`.
- При мутациях копят uncommitted `events: []` (prepend / append — единообразно в агрегате; flush делает `Enum.reverse` при необходимости).
- Мутации возвращают `{:ok, %Agg{}} | {:error, Error.t()}`.
- Domain MUST NOT писать в БД / MQ / outbox — только менять struct и копить события. Persist — задача Repo.

Аудит-поля (`created_at`, `created_by`, `updated_at`, `updated_by`, `deleted_at`, `deleted_by`) — порядок как в `20-agreements.md`.

### Агрегат vs View

Агрегат — write-модель: доменные Prim, инварианты, мутации, события. Read-путь работает не с
ним, а с **представлением** (`<Actor>.<Aggregate>.View`) — структурой из примитивных значений
(`String.t()`, `DateTime.t()`, `Decimal.t()`, `pos_integer()`, атомы `Core.Enum`).

- View — не домен: инвариантов не держит, мутаций не имеет, Prim в нём **MUST NOT**.
- Prim на read-пути был бы вредом, а не пользой: `Prim.new/1` на строке из БД поднимает
  доменную ошибку там, где её обработать нечем — валидировать значение, уже прошедшее
  запись, поздно и незачем.
- При этом **формат** значения задаёт именно Prim: поля View объявляются Prim-модулями
  (`use Core.View`), и по ним `Codec.dump_raw_as/2` берёт kind, tz и precision. Prim
  участвует в декларации, но в структуру не попадает.
- Обратного пути нет: собрать агрегат из View запрещено (`13-repos.md`).

Полные правила View, его кодека и read-схемы — «View (read-модель)» в `13-repos.md`.

## Context

`%Context{data: map}` + `find` / `get` / `get!` / `put` / `delete`.

`Context.Accessor` — типизированный доступ к ключу (пример: `Domain.Auth.CurrentUser` → `:current_user_id`).

Последний аргумент публичных usecase/repo-функций — `%Context{}`.

App-код собирает context через `MyApp.ContextFactory`: `sc/0`, `as_user/1`, `anonymous/0`, `system/0` (в т.ч. фоновые воркеры — один раз в `init`), `empty/0`. `Context.new` — низкоуровнево / default в Core.

## Es.Event

`use Es.Event, aggregate_id:, by:, payload:` — builder события версионированного агрегата.

Сгенерированные поля: `id`, `payload`, `aggregate_id`, `aggregate_version`, `at`, `by`.

Wire-имя события (**единственный источник**) — в `<Aggregate>.Event.Codec` (`type/1`, `types/0`, `@tag_by_mod`).

`payload:` — модуль `Payload` или `nil` (событие без нагрузки).

```elixir
defmodule Created do
  defmodule Payload do
    defstruct [:name]
    def new(%Agg.Name{} = name), do: %__MODULE__{name: name}
  end

  use Es.Event,
    aggregate_id: Agg.ID,
    by: User.ID,
    payload: Payload
end
```

Объединяющий модуль событий агрегата (`<Aggregate>.Event`) обязан предоставлять:

| Функция | Назначение |
|---|---|
| `name/1` | wire-type через `Event.Codec.type/1` |
| `names/0` | множество через `Event.Codec.types/0` |

Dump/load событий — только через `InCodec`/`OutCodec.dump(event)` и `<Aggregate>.Event.Codec.load_event/8` (bang-вариант — только write-path; не обёртки на `<Aggregate>.Event`).

Wire-формат события неизменяем: переименование тега или поля payload ломает чтение истории. Правила и golden-фикстуры — «Совместимость событий» в `14-events-outbox.md`.

Детали flush / outbox — `14-events-outbox.md`.

## Version

- `%Version{}` — целое ≥ 1; `next/1`.
- В repo/API также допустим `:current` («последняя версия»).
- `parse("*")` → `:current` (для `If-Match`).

## Pagination

`Pagination.Limit` / `Pagination.Offset` + `Pagination.Result.t(entity)`.

У `Limit` MUST быть `max:` — иначе клиент запросит страницу произвольного размера.
У `Offset` верхней границы нет намеренно: любой предел произволен, а от deep pagination
защищает переход на курсорную пагинацию, а не отказ на большом смещении.

Repo-методы `page/4` возвращают `Pagination.Result`.

## Result / Option

Combinators под CQS (`Result.and_then/2`, `Option.map/2` и т.п.). Использовать на границах (web → Prim, nullable FK → Prim).

## Связанные правила

- Архитектура / usecases — `10-architecture.md`
- Ошибки / `Exc` — `12-errors.md`
- Persist агрегатов — `13-repos.md`
- События и outbox — `14-events-outbox.md`
