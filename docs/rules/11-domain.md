# Домен

- **Область.** `lib/core/prim/**`, `lib/core/enum.ex`, `lib/core/validator/**`, `lib/core/codec/**`,
  `lib/core/view.ex`, `lib/core/context*`, `lib/core/es/**`; у потребителя — агрегаты, профили Codec
  и entity-фасады.
- **Читать перед.** Новым Prim, Enum, кодеком, событием, командой или View; правкой агрегата,
  профиля Codec, `Core.View`; выбором между агрегатом и представлением.
- **Словарь.** Плейсхолдеры и модальность — `00-index.md`.

Строительные блоки:

- примитивы и множества — `core/prim`, `core/enum`, `core/validator`;
- сериализация — `core/codec` (+ `core/codec/redump`), профили
  `MyApp.Codec.Prim.{Internal,External}` и entity-фасады `MyApp.Codec.{Internal,External}`;
- модели и контекст вызова — `core/view`, `core/context`, `core/es`;
- сквозные типы — `Version`, `Pagination`, `Result` / `Option`.

## Prim (value object)

`Core.Prim` — макрос value object: `%Mod{value:}`, `new/1`, `new!/1`, `value/1`, `name/0`,
`__domain_kind__/0`, `__domain_type_opts__/0`, `__domain_sensitive__/0`; на модуле —
`prim?/1`, `composed?/1`, `unwrap/1`.

```elixir
use Core.Prim,
  cast: ...,
  name: ...,
  kind: ...,
  mutate: ...,
  validate: ...,
  custom_mutate: ...,
  custom_validate: ...,
  type_opts: ...,
  pipeline_opts: ...,
  sensitive: ...
```

`cast:`, `name:` и `kind:` обязательны (без любой из них — `CompileError`). Конвейер:
`cast → mutate → custom_mutate → validate → custom_validate`.

`type_opts:` — опции **типа** (`precision`, `tz`, границы): их отдаёт
`__domain_type_opts__/0` и получают validate-шаги. `pipeline_opts:` (default —
`type_opts`) получают cast/mutate-шаги: опциям обработки (`trim`, `sec_max_len`)
в контракте типа места нет, а шагам они нужны.

Формы шагов у mutate и validate одни и те же — `{Module, opts}`, `fun/1`, `fun/2`
или список любой из них; `cast:` — `fun/1` либо `fun/2`. Контракт модульной формы:
`Core.Mutator` (`@callback mutate/2`) и `Core.Validator` (`@callback validate/2`) —
зеркальные behaviour, мутатор меняет значение, валидатор только проверяет его.

`sensitive: true` (default `false`) — значение Prim не попадает ни в `inspect/1`, ни в
`Error.detail`:

| Эффект | Как |
|---|---|
| `inspect/1` не печатает значение | `@derive {Inspect, except: [:value]}` → `#Password<...>` |
| `Error.detail` не содержит raw | `{:redacted, byte_size}` для binary, `:redacted` для остального |
| флаг доступен коду | `__domain_sensitive__/0` |

Опция есть у всех обёрток (`Prim.String` / `Integer` / `UUID` / `Decimal` / `Date` / `DateTime` /
`Compose`). `Prim.Compose` наследует её от базового Prim, явный `sensitive: true` перебивает
наследование, а понижение (`sensitive: false` поверх чувствительной базы) — `CompileError`:
композит строит внешнюю ошибку сам, и без флага raw ушёл бы в её `detail` целым. Какие значения
MUST помечаться и чек-лист секрета — `12-errors.md`, «Чувствительные данные».

| Функция | Возврат |
|---|---|
| `new/1` | `{:ok, t()} \| {:error, Error.t()}` |
| `new!/1` | `t()`; при ошибке — `raise Exc, error` |
| `value/1` | внутреннее значение |
| `__domain_kind__/0` | атом kind для Codec |
| `__domain_type_opts__/0` | опции типа (`precision`, `tz`, границы) — их читает `Codec.coerce/2` на read-пути |
| `__domain_sensitive__/0` | Prim объявлен `sensitive: true` (наследуется `Prim.Compose`) |
| `name/0` | имя Prim из `name:` — уходит в message доменной ошибки |
| `Prim.prim?/1` | модуль объявлен через `use Prim` (`__domain_kind__/0` + `value/1`); при необходимости загружает модуль |
| `Prim.composed?/1` | Prim объявлен через `Prim.Compose` (есть `__domain_base__/0`) |
| `Prim.unwrap/1` | рекурсивно достать самое внутреннее не-Prim значение |

В function heads: обязательный Prim — `%Mod{}` (default); композиция в `when` — `Core.Guard.is/2` /
`is_opt/2` (`import`, не guards на самом Prim).

Ошибки валидации: `{:error, {code, detail}}` →
`Error.domain(module, code: code, ns: :prim, message: "#{name}: #{detail}", detail: raw)` (в
`Error.detail` — исходный raw; `detail` в кортеже — текст валидации).

### Типизированные обёртки

`Prim.String` / `Integer` / `Decimal` / `UUID` / `DateTime` / `Date` / `Compose` +
`Core.Validator.*` (sibling, не под Prim).

Порядок проверок у всех обёрток один — `Core.Prim.Opts.prepare!/2` (набор ключей →
`kind:` → значения опций); метаданные билдера объявляет `use Core.Prim.Wrapper`.

**Значения** опций обёрток проверяются на компиляции (`Core.Prim.Opts`, `CompileError`):
границы и их порядок, `%Regex{}`, `%Date{}` / `%DateTime{}`, IANA-зона `tz:`, версия UUID,
boolean-опции. Проверять их в рантайме нельзя: там ошибка конфигурации приходит доменной
ошибкой первого `new/1` и неотличима от невалидного ввода пользователя.

Строковый ввод MUST быть ограничен по байтам **до разбора**: разбор (`String.valid?/1`,
`Integer.parse/1`, `Decimal.new/1`) обходит ввод целиком, а `min:` / `max:` / `min_len:`
проверяются уже после него и от стоимости разбора не защищают. У `Prim.Integer` на ~2 млн
цифр разбор к тому же поднимает `SystemLimitError` мимо контракта `new/1`.

| Обёртка | `sec_max_len` по умолчанию | Без границ |
|---|---|---|
| `Prim.String` | `max_len * 4 + 50` | `CompileError` — примитив без границы принимает ввод любого размера |
| `Prim.Integer` | десятичная запись `max:` + 4 | 40 байт |
| `Prim.Decimal` | запись `max:` + `scale:` + 8 | 64 байта |

Явный `sec_max_len:`, в который не влезает собственный `max:`, — `CompileError`.
Ввод, уже разобранный вызывающим (`integer()`, `%Decimal{}`), границей не ограничен.

`Prim.UUID` дополнительно: `new/0` (генерация в версии `version:` — 1 / 4 / 7, default 4),
`format/2` (`:full` / `:hex` / `:urn` — для логов и ключей, wire-форму задаёт профиль кодека);
`check_version: false` снимает проверку версии на разборе, оставляя генерацию.

`Prim.DateTime` дополнительно: `now/0` / `now!/0`, `from/1` / `from!/1` — конверсия **из другого
datetime-Prim** (явный API; `new/1` принимает только raw `%DateTime{}` / ISO8601, не другой Prim).

`Prim.Date` — дата без времени: `today/0` / `today!/0` (в `tz:` модуля или `Core.Config.tz/0`),
`from/1` / `from!/1` — конверсия **из другого date- или datetime-Prim** (datetime приводится к дате
в том же tz). `new/1` принимает только raw `%Date{}` / ISO8601 — ни `%DateTime{}`, ни другой Prim.
Опции: `after:` / `before:` (`%Date{}`), `tz:`; `precision:` нет.

`Prim.Compose` — обёртка над другим Prim (`of:`): `%Mod{value: %Base{}}`. Kind по умолчанию
`:composite` (`Prim.reserved_kinds/0`). Дополнительно: `__domain_base__/0`, `raw/1` (через
`Prim.unwrap/1`). `new/1` принимает raw базы, `%Base{}` или `%Mod{}` (идемпотентно). Вложенная
композиция допустима (`of:` может быть Compose).

Native kinds: `:string`, `:integer`, `:decimal`, `:uuid`, `:datetime`, `:date`
(`Prim.native_kinds/0`). Reserved: native + `:composite`. Опциональный `kind:` — свой атом (не чужой
reserved; проверка `Prim.validate_kind!/2`); тогда в профилях Codec нужны `dump(%Mod{})` и/или
`dump_kind(prim, kind)`.

Правило `name:`: брать из первой строки `@moduledoc` через `Helper.String.first_line/1`.
Импорт `import Core.Helper.String, only: [first_line: 1]` пишет сам модуль: ни `use Core.Prim`
с обёртками, ни `use Core.Enum` его не делают.

Примитивы объявлять **вложенными модулями** внутри агрегата:

```elixir
defmodule MyApp.Domain.<BC>.Common.<Aggregate> do
  import Core.Helper.String, only: [first_line: 1]

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

`Core.Enum` — макрос enum: значение — **голый атом** (не `%Mod{value:}`), SSOT для Dialyzer
(`@type t`) и runtime.

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

  import Core.Helper.String, only: [first_line: 1]

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

`is_enum/2` / `in_enum/3` — макросы (compile-time `mod.values()` / проверка subset ⊆ values). Guard
форсирует `Code.ensure_compiled/1` для enum-модуля (чистая сборка). Опечатка или дубль в subset →
`CompileError`.

Значения инлайнятся в guard литералом, а компилятор этой связи не видит: `Code.ensure_compiled/1`
даёт максимум export-ребро, и правка `values:` не пересобрала бы каллер (guard остался бы на старом
множестве). Поэтому `Core.Guard` регистрирует исходник enum-модуля как `@external_resource`
каллера. Следствие для потребителя: enum, используемый в guard, MUST компилироваться на той же
машине, что и каллер (сборка с `+deterministic` теряет `:source` — тогда инкрементальная пересборка
каллера не гарантирована).

Wire: atom или binary (`Atom.to_string/1`). Schema: `Ecto.Enum, values: Status.values()`. Агрегат:
`status: Status.t()`.

## Codec (Prim и Entity)

Модули библиотеки (Core **не** ссылается на домен приложения, приложение ссылается на Core):

| Модуль | Роль |
|---|---|
| `Core.Codec` | билдер Prim-профиля: `dump` / `load` / `load!` |
| `Core.Codec.Plugin` | behaviour entity-плагина (`@callback` + `use`) |
| `Core.Codec.Helper` | хелперы load/dump для потребителей фасада |
| `Core.Codec.Facade` | билдер entity-фасада (`prim:` + `plugins:`) |
| `Core.Es.Event.Codec` | билдер `<Aggregate>.Event.Codec`: `dump` отдаёт конверт, `load` восстанавливает событие по тегу внутри него |
| `Core.View` | генерирует `<Aggregate>.View.Codec` — кодек представления read-пути (dump-only, `loadable: false`) |

Профили, фасады и реестр плагинов приложения, значения опций профилей —
`deps/core/docs/rules/app/11-domain.md`, «Профили Codec» и «Фасады и реестр плагинов».

Опции Prim-профиля (`use Core.Codec`):

| Опция | Обязательна | Значения |
|---|---|---|
| `uuid:` | да | `:full`, `:hex`, `:urn` |
| `datetime:` | да | `:datetime`, `:iso8601` |
| `datetime_tz:` | да | `:keep`, `:app`, строка IANA-зоны |
| `decimal:` | да | `:decimal`, `:string` |
| `date:` | нет, default `:date` | `:date`, `:iso8601` |

Неизвестная или пропущенная обязательная опция — `CompileError`, значение вне списка —
`ArgumentError` при сборке профиля.

Оси datetime: `datetime:` — форма (`:datetime` → `%DateTime{}`, `:iso8601` → строка); `datetime_tz:`
— `:keep`, `:app` (tz приложения из `Core.Config.tz/0`, резолв в рантайме) или IANA binary
(`DateTime.shift_zone!/2` на dump); точность — `precision: :second | :millisecond | :microsecond`
(default `:second`) в `use Prim.DateTime` (как у `DateTime.truncate/2`), не кодек.

`date:` — форма даты без времени (`:date` → `%Date{}`, `:iso8601` → строка). Единственная
**необязательная** опция профиля: профили, объявленные без неё, продолжают работать.

Приоритет Prim dump: `dump(%Mod{})` → `dump_kind(prim, kind)` → builtin. Приоритет Prim load:
`load(mod, raw)` → `load_kind` → builtin → `mod.new/1`. Kind `:composite` (`Prim.Compose`): dump →
`dump(value)` (рекурсия до leaf); load → `load(base, raw)` + `mod.new(inner)`. Wire-формат композита
= формат базового Prim. Профиль влияет только на dump; load формат-агностичен (приведение — `cast`
примитива).

Entity-фасад (`alias Codec.Internal, as: InCodec`):

```elixir
use Core.Codec.Facade,
  prim: MyApp.Codec.Prim.Internal,
  plugins: [MyApp.Domain.<BC>.Common.<Aggregate>.Codec]
```

**Весь интерфейс фасада — `dump/1`, `load/2`, `load!/2`.** Единственная ось диспетчеризации —
модуль: `dump/1` выбирает плагин по `__struct__`, `load/2` — по первому аргументу. Функций «на
случай» (raw-путь, теги) у фасада нет — то, что раньше жило в нём частностями View и событий, ушло в
`Core.Codec.Helper` и в сам плагин.

- `dump/1` / `load/2` / `load!/2` — plugin clauses, иначе делегат в `prim`. Фолбэк `dump/1`
  принимает только struct с полем `value` (`is_prim/1`): struct без плагина и без `value`
  (команда, View) — предупреждение при сборке и `FunctionClauseError`, с `value`, но не Prim, —
  `ArgumentError`
- Результат plugin clause сужен по типам плагина: `load(Mod, data)` —
  `{:ok, %Mod{}} | {:error, _}`, `load(<Aggregate>.Event, data)` — объединение событий кодека,
  событие — ещё и по нагрузке; `load!/2` — само значение или `raise Core.Exc`. Опечатка в поле
  загруженного значения и невозможная clause по результату ловятся при сборке
  (`make consumer-check`). Фолбэк `load/2` по атому не сужен: модуль без плагина компилятор
  не ловит, при исполнении — `ArgumentError`
- Полиморфный wire (тег внутри данных) грузится через **модуль-семейство**:
  `InCodec.load(<Aggregate>.Event, data)`. Семейство объявляет плагин опцией `union:`, конкретный
  тип выбирает он же — фасад про теги не знает
- Модули типов и семейств уникальны между плагинами (`CompileError` на компиляции фасада); теги
  уникальны **внутри своего плагина**, а не приложения
- Plugin: `use Core.Codec.Plugin, types: [...]`; `loadable: true|false`; `union: Мод` (требует
  `loadable: true`); `dump/2` обязателен всегда, `loadable: true` требует ещё `load/3`
  (`CompileError`)
- Генерируются `__codec_types__/0`, `__codec_union__/0`, `__codec_loadable__/0`
- `loadable: false` — dump-only (как `<Aggregate>.View.Codec`: у read-модели обратного пути нет)
- Хелперы плагина (импорт при `use`): `field/2` — из `Core.Helper.Map` (generic-аксессор map по
  atom-или-string ключу, доступен любому коду); `dump_optional/2` / `dump_many/2` / `dump_raw/3` /
  `load_optional/3` / `load_many/3` — из `Core.Codec.Helper`. У load-хелперов и `dump_raw/3`
  Prim-модуль идёт первым аргументом — как у `codec.load/2`. В Ecto-схемах `field/2` **не**
  импортировать (конфликт с `Ecto.Schema`) — звать `Helper.Map.field/2`
- `Codec.Helper.dump_raw(Prim, raw, codec)` — дамп значения **без** Prim-обёртки (read-модели):
  значение приводится к своему Prim (`Core.Codec.coerce/2` — kind плюс его `__domain_type_opts__/0`:
  tz и precision) и уходит в обычный `codec.dump/1`. Отдельного raw-формата, который мог бы
  разойтись с агрегатным, больше нет — переопределение `dump/1` в профиле действует и здесь,
  включая plain-kind (`:string`, `:integer`): значение такого Prim не приводится, но обёртка
  строится, иначе wire-формы путей разошлись бы. Тотальна по значению: `nil`, неприводимое
  значение и Prim вне `Core.Codec.coercible_kinds/0` (кастомный kind) проходят как есть.
  На неё опираются `Core.View` и `Core.Codec.Redump`
- Enum-поля кодек не сериализует (атомы как есть)
- `<Aggregate>.Codec` MUST предоставлять `dump`/`load` для самого агрегата и его вложенных сущностей
  (если есть). Поле `events` в dump/load агрегата **не** участвует (события — только через
  `<Aggregate>.Event.Codec`). `Repo.Pg.Schema` **обязан** вызывать фасад (`InCodec.load` /
  `InCodec.dump`) сущности; Presenter может мапить поля вручную под shape API. Реестр плагинов
  приложения, включая кодеки `Core.*` (`Core.Outbox.Codec`), —
  `deps/core/docs/rules/app/11-domain.md`, «Фасады и реестр плагинов».

Кастом Prim в профиле: `@impl true def dump(%Agg.ID{})`, optional `dump_kind` / `load_kind` +
`super`. Для plain-kind (`:string`, `:integer`) такое переопределение MUST быть идемпотентным:
на read-пути (`dump_raw/3`) оно ложится на значение, уже прошедшее dump профиля записи, а
нормализовать его нечем — у форматируемых kind эту роль играет `cast` в `Codec.coerce/2`.

### Dump/load только через фасад

Вложенные сущности и соседние типы — **только** через фасад, не через модуль чужого плагина:
фасад знает только зарегистрированные плагины (`deps/core/docs/rules/app/11-domain.md`, «Фасады и
реестр плагинов»).

Внутри плагина — аргумент `codec` (`dump/2`, `load/3`) и хелперы `load_optional/3`,
`load_many/3`. Снаружи плагина — `InCodec` / `OutCodec`.

```elixir
# плохо
Item.Codec.dump(item, codec)
Attachment.Codec.load(Attachment.File, raw, codec)
Item.Codec.dump(item, InCodec)

# хорошо
codec.dump(item)
codec.load(Item, raw)
load_many(Item, list, codec)
InCodec.dump(item)
```

События исключением не являются: `InCodec.dump(event)` отдаёт конверт целиком,
`InCodec.load(<Aggregate>.Event, data)` восстанавливает событие по тегу — модуль событий агрегата
объявлен семейством (`union:`), и конкретный тип кодек выбирает сам; `InCodec.load(Mod, data)` —
когда тип известен. Обёрток на `<Aggregate>.Event` и обходных `load_for_channel`, которые зовут
соседний `*.Codec` в обход фасада, не заводить.

Алиасы профилей — `deps/core/docs/rules/app/20-agreements.md`, «Алиасы приложения»; коллизии
коротких имён — `20-agreements.md`, «Алиасы модулей».

## Aggregates

Агрегат бывает state-stored и event-sourced (термины — `CONTEXT.md`): вид выбирается на агрегат,
оба вида остаются. Оба версионируются через `Version` (optimistic lock).

Слой домена без persist, мутации state-stored агрегата, soft-delete и поля аудита —
`deps/core/docs/rules/app/11-domain.md`, «Агрегаты».

### State-stored

- `version` поднимает домен, репозиторий её только проверяет.
- При мутациях копят uncommitted `events: []` (prepend / append — единообразно в агрегате; flush
  делает `Enum.reverse` при необходимости).

### Event-sourced

`use Core.Es.Aggregate, event_codec:` — автор пишет `decide/2` и `evolve/2`, библиотека
генерирует свёртку `fold/2` / `fold/3` и чистый шаг `execute/2` (исходы — moduledoc
`Core.Es.Aggregate`).

- `id` и `version` состояния ведёт только библиотека: домен MUST NOT ставить их ни в `decide`,
  ни в `evolve`. Начальное состояние — `%Agg{id: id}`, «не создан» — `version: nil`.
- `decide(команда, состояние)` → `{:ok, [черновик]} | {:error, _}`: `id` события,
  `aggregate_id`, версию, `by` и `at` проставляет библиотека. Команда без изменений —
  `{:ok, []}`.
- Элемент результата — черновик события (`CONTEXT.md`, «Черновик события»); он MUST строиться
  только самим событием: `Event.Mod.draft(payload)` у события с нагрузкой, `Event.Mod.draft()` —
  без неё. Кортеж `{Event.Mod, payload}`, собранный вручную, библиотека примет, но нагрузку в нём
  сборка не сверяет. Модуль события в переменной (`event.draft(payload)`, `&event.draft(&1)`) —
  MUST NOT: вызов через модуль-переменную сборка не проверяет вовсе. Список черновиков строит
  захват `&Event.Mod.draft/1` — арность он сверяет, нагрузку элементов списка не видит ни одна
  форма.
- `not_found` / `already_exists` — доменные ошибки `decide` по `version: nil`: существование
  агрегата решает домен, а не репозиторий.
- Несколько событий одной команды — `with` и `fold/3`: следующее решение видит состояние после
  предыдущего события.
- `evolve(состояние, событие)` → голое состояние: чистый, без проверки инвариантов и без
  catch-all. Голова `evolve` MUST матчить только событие, не значения состояния: событие — уже
  случившийся факт, и отказаться от него свёртка не вправе. Инвариант, который захотелось
  проверить в `evolve`, принадлежит `decide`.
- Полноту `evolve` проверяет сборка репозитория агрегата (`use Core.Es.Aggregate.Repo`,
  `13-repos.md`, «Write event-sourced агрегата»): у агрегата без репозитория clause, пропущенная
  для события кодека, найдётся только при свёртке.
- Удалённый тип события (тег остаётся в `tags:`) — клауза `evolve`, возвращающая состояние
  как есть: строки в хранилище живут дольше кода.

Проверяется: `CompileError` в `use Core.Es.Aggregate` без `id` / `version` в `defstruct`;
предупреждение при сборке — у `draft` нагрузка другого события, `draft()` у события с нагрузкой
или `draft(payload)` у события без неё; на строке `use Core.Es.Aggregate.Repo` — у `evolve/2` нет
clause события кодека, опечатка в ключе `%{state | …}` или в поле нагрузки без паттерна
`%Payload{}` (`make consumer-check`); `FunctionClauseError` при исполнении команды — черновик
события не из кодека агрегата.

```elixir
# плохо — голова evolve проверяет статус: инвариант ушёл из decide, а событие при другом
# статусе роняет свёртку — проверка полноты при сборке этого не видит
def evolve(%__MODULE__{status: :open} = state, %Event.Frozen{}), do: %{state | status: :frozen}

# плохо — decide собирает событие и нумерует версию сам
def decide(%Cmd.Freeze{} = cmd, state),
  do: {:ok, [Event.Frozen.new(state.id, Version.next(state.version), cmd.by, cmd.at)]}

# плохо — кортеж вручную: нагрузку другого события сборка не заметит
def decide(%Cmd.Rename{name: name}, %__MODULE__{status: :open}),
  do: {:ok, [{Event.Renamed, Event.Opened.Payload.new(name)}]}

# плохо — модуль события в переменной: сборка не проверяет ни арность, ни нагрузку
Enum.map(role_ids, &event.draft(&1))

# хорошо — решение в decide, черновик от события, evolve только применяет событие
def decide(%Cmd.Freeze{}, %__MODULE__{version: nil}),
  do: {:error, Errors.domain(__MODULE__, :not_found, nil)}

def decide(%Cmd.Freeze{}, %__MODULE__{status: :open}), do: {:ok, [Event.Frozen.draft()]}

def decide(%Cmd.Rename{name: name}, %__MODULE__{status: :open}),
  do: {:ok, [Event.Renamed.draft(Event.Renamed.Payload.new(name))]}

# список черновиков — захват у литерала события: неверную арность сборка ловит
Enum.map(role_ids, &Event.RoleGranted.draft/1)

def evolve(state, %Event.Frozen{}), do: %{state | status: :frozen}
```

### Команда

Команда event-sourced агрегата — `<Aggregate>.Cmd.<Name>` с `use Core.Es.Cmd`: struct из Prim
без логики. `by` (Prim автора событий агрегата) и `at` (`%Es.Event.At{}`) MUST быть в
`@enforce_keys`: автор и момент события — данные команды, а не `Context` и не часы библиотеки.
Сборка команды в usecase — `deps/core/docs/rules/app/11-domain.md`, «Агрегаты».

Проверяется: `CompileError` в `use Core.Es.Cmd` — `by` или `at` не в `@enforce_keys`.

```elixir
defmodule MyApp.Domain.<BC>.Common.Account.Cmd.Rename do
  use Core.Es.Cmd

  @enforce_keys ~w(name by at)a
  defstruct @enforce_keys
end
```

### Агрегат vs View

Агрегат — write-модель: доменные Prim, инварианты, мутации, события. Read-путь работает не с
ним, а с **представлением** (`<Actor>.<Aggregate>.View`) — структурой из примитивных значений
(`String.t()`, `DateTime.t()`, `Decimal.t()`, `pos_integer()`, атомы `Core.Enum`).

- View — не домен: инвариантов не держит, мутаций не имеет, Prim в нём **MUST NOT**.
- Prim на read-пути был бы вредом, а не пользой: `Prim.new/1` на строке из БД поднимает
  доменную ошибку там, где её обработать нечем — валидировать значение, уже прошедшее
  запись, поздно и незачем.
- При этом **формат** значения задаёт именно Prim: поля View объявляются Prim-модулями
  (`use Core.View`), и по ним `Codec.Helper.dump_raw/3` приводит значение к Prim с его
  kind, tz и precision. Prim участвует в декларации, но в структуру не попадает.
- Обратного пути нет: собрать агрегат из View запрещено (`13-repos.md`).

Полные правила View, его кодека и read-схемы — «View (read-модель)» в `13-repos.md`.

## Context

`%Context{data: map}` + `find` / `get` / `get!` / `put` / `delete`. Ключ — атом: словарь ключей
закрыт кодом, а не приходит извне. `inspect/1` печатает только список ключей — контекст целиком
уходит в crash-репорты OTP-процессов, а его значения чувствительны (`12-errors.md`).

`Context.Accessor` — типизированный доступ к ключу (пример: `MyApp.Domain.<BC>.CurrentUser` с
`use Core.Context.Accessor` → `:current_user_id`):

- `key:` (обязательна) — атом ключа;
- `type:` — модуль значения; спеки сужаются до `<Mod>.t()`, а `put/2` принимает только
  `%<Mod>{}`. Без `type:` значение остаётся `term()`;
- сгенерированные `exists?/1`, `find/1`, `get/1`, `get!/1`, `put/2`, `delete/1` —
  `defoverridable`; макрос инжектирует `alias Core.Context` и `alias Core.Error`.

Позиция `%Context{}` в сигнатуре публичных usecase/repo-функций — `20-agreements.md`.

`Context.new` — низкоуровневая сборка и default в Core. Как приложение собирает контекст и сколько
он живёт — `deps/core/docs/rules/app/11-domain.md`, «Context».

## Es.Event

`use Es.Event, aggregate_id:, by:, payload:` — builder события версионированного агрегата.

Сгенерированные поля: `id`, `payload`, `aggregate_id`, `aggregate_version`, `at`, `by`.

Wire-имя события (**единственный источник**) — в `<Aggregate>.Event.Codec` (`type/1`, `types/0`,
`@tag_by_mod`).

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

`use Es.Event` дополнительно генерирует интроспекцию (`__es_payload__/0`, `__es_aggregate_id__/0`,
`__es_by__/0`) — по ней `<Aggregate>.Event.Codec` выводит Prim агрегата и автора и обслуживает
события без нагрузки сам. Черновик события для `decide/2` агрегата — тоже `use Es.Event`:
`draft/1` у события с нагрузкой, `draft/0` без неё («Event-sourced»).

Dump/load событий — только через фасад («Dump/load только через фасад»).

Уникальность и квалификация wire-тега — `14-events-outbox.md`, «Domain events».

Записанное событие неизменяемо: несовместимая правка тега или нагрузки — новый тег плюс апкаст
(`14-events-outbox.md`, «Совместимость событий»; там же golden-фикстуры).

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

Combinators под CQS (`Result.and_then/2`, `Option.map/2` и т.п.). Использовать на границах (web →
Prim, nullable FK → Prim).

## Связанные правила

- Архитектура / usecases — `10-architecture.md`
- Ошибки / `Exc` — `12-errors.md`
- Persist агрегатов — `13-repos.md`
- События и outbox — `14-events-outbox.md`
