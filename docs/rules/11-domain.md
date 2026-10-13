# Домен

- **Область.** `lib/core/prim/**`, `lib/core/enum.ex`, `lib/core/validator/**`, `lib/core/codec/**`,
  `lib/core/view.ex`, `lib/core/context*`, `lib/core/result.ex`, `lib/core/option.ex`,
  `lib/core/es/**`, `lib/core/labels/**`; у потребителя — агрегаты, профили Codec и entity-фасады.
- **Читать перед.** Новым Prim, Enum, кодеком, событием, командой или View; правкой агрегата,
  профиля Codec, `Core.View`, подписей событий; выбором между агрегатом и представлением.
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
`namespace:` / `scope:` UUID, boolean-опции. Проверять их в рантайме нельзя: там ошибка
конфигурации приходит доменной ошибкой первого `new/1` и неотличима от невалидного ввода
пользователя.

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

`Prim.UUID` дополнительно: `new/0` (генерация в версии `version:` — 1 / 4 / 7, default 4; у
версии 5 и `:external` `new/0` нет), `format/2` (`:full` / `:hex` / `:urn` — для логов и ключей,
wire-форму задаёт профиль кодека); `check_version: false` снимает проверку версии на разборе,
генерацию не трогает.

`Prim.UUID` с `version: 5` — идентификатор из ключа (ADR-0017): конструктор — приватный
`from_key/1` от строки или непустого списка строк, его зовёт `from_<key>` модуля.
`namespace:` (UUID-строка) и `scope:` (область ключа, непустая строка) при `version: 5`
обязательны, при других версиях — `CompileError`; `check_version: false` допустим. Нормы
приложения — `deps/core/docs/rules/app/13-repos.md`, «Уникальность без индекса состояния».

`Prim.UUID` с `version: :external` — внешний идентификатор (ADR-0036): UUID источника как есть.
Ни `new/0`, ни `from_key/1` нет — id не выпускается в обход источника, и вызов `new/0` ловится на
сборке; разбор принимает UUID любой версии. `check_version:`, `namespace:` и `scope:` при нём —
`CompileError`. Когда так задаётся id потока — `deps/core/docs/rules/app/13-repos.md`,
«Уникальность без индекса состояния».

`:external` описывает происхождение значения, а не роль: им MAY объявляться и ссылка агрегата на
объект источника, которая id потока не является. Тест выпускает такой id «как источник» —
`Ecto.UUID.generate() |> Agg.ID.new!()` в фикстуре; функции генерации в самом Prim MUST NOT.

Проверяется: `test/core/prim/uuid_test.exs`, describe «идентификатор из ключа (version: 5)» и
«внешний идентификатор (version: :external)».

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

Prim вложен в агрегат-владелец **по имени** (`<Aggregate>.Name`); где лежат его файл и значение
без владельца — `deps/core/docs/rules/app/11-domain.md`, «Prim и Enum». В файле агрегата:

```elixir
defmodule MyApp.Domain.<BC>.<Aggregate> do
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
- первая ячейка строки — значение в форме `inspect/1` в обратных кавычках (`` `:in_work` ``):
  по ней проверка сопоставляет строку со значением, и ячейка `| in_work |` не описывает ничего;
- описание — строчными, без точки в конце, одна строка на значение;
- значение, выведенное из обращения внешним источником, MUST быть помечено
  («выведен из обращения в 2015 году») — иначе читатель примет его за действующее;
- первая строка `@moduledoc` остаётся именем enum: из неё `first_line/1` берёт
  `name:`, который уходит в тексты доменных ошибок. Таблица идёт **после** неё.

Проверяется: тест-модуль `use Core.Enum.DocsCase` (`19-testing.md`, «Enum: описания и внешние
коды»); в библиотеке — `test/core/enum_docs_test.exs`.

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
  plugins: [MyApp.Domain.<BC>.<Aggregate>.Codec]
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
  тип выбирает он же — фасад про теги не знает. Варианты семейства с адресом в данных — «Варианты
  семейства (`variants:`)»
- Модули типов и семейств уникальны между плагинами (`CompileError` на компиляции фасада); теги
  уникальны **внутри своего плагина**, а не приложения
- Plugin: `use Core.Codec.Plugin, types: [...]` — ручные типы; `fields:` — типы по полям;
  `variants:` — варианты семейства; тип — ровно в одной из трёх, хотя бы одна обязательна
  (`CompileError`); `loadable: true|false`; `union: Мод` (требует `loadable: true`); у ручного типа
  `dump/2` обязателен всегда, `loadable: true` требует ещё `load/3` (`CompileError`)
- Генерируются `__codec_types__/0` (объединение трёх опций), `__codec_union__/0`,
  `__codec_loadable__/0`, `__codec_variants__/0`, `__codec_redump__/1` (спека пере-дампа типа —
  `13-repos.md`, «jsonb-нагрузка на read-пути»; только на типы со спекой, у плагина без них её
  нет), `__codec_redump_missing__/0` (типы без спеки — отказ по ним бросает фасад)
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
- Wire-ключи дампа плагина SHOULD быть строками: так пишут плагин по полям и конверт события, и
  такую же форму jsonb отдаёт при чтении. Многотиповый плагин с атомарными ключами у ручных типов
  отдаёт фасаду две формы, и вызывающий не знает, по какому ключу читать. Загрузка читает ключ
  через `field/2` — и строковый, и атомарный; запись по ключу — `13-repos.md`, «Schema»
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

### Плагин по полям (`fields:`)

Тип, чья wire-форма повторяет поля один к одному, объявляется спекой полей, а `dump/2` / `load/3`
генерирует `use Core.Codec.Plugin` (решение — ADR-0056):

```elixir
use Core.Codec.Plugin,
  fields: [
    {Item,
     id: [prim: Item.ID],
     name: [prim: Item.Name, wire: "title"],
     note: [prim: Item.Note, optional: true],
     status: [enum: Item.Status, default: "new"],
     tags: [list: [entity: Item.Tag]]}
  ]
```

- `fields:` — список пар `{Type, spec}`; повтор типа или тип, названный ещё и в `types:` /
  `variants:`, — `CompileError`. Struct типа остаётся ручным
- Поле спеки — ровно один вид:

  | Вид | Значение поля | Дамп | Загрузка | Голова `dump/2` |
  |---|---|---|---|---|
  | `prim: Prim` | Prim-структура; любой Prim, включая композит, кастомный kind и sensitive | `codec.dump/1` | `codec.load(Prim, raw)` | `%Prim{}` |
  | `enum: Enum` | атом `Core.Enum` | как есть | `cast/1`, при `optional:` — `cast_optional/1`; отказ — ошибка загрузки | `is_atom`, `nil` — только при `optional:` |
  | `entity: Mod` | struct, обслуживаемый фасадом | `codec.dump/1` | `codec.load(Mod, raw)` | `%Mod{}` |
  | `union: Family` | вариант семейства (`union:` у его плагина) | `codec.dump/1` — форма адреса варианта | `codec.load(Family, raw)` | `is_struct` |
  | `list: спека` | список значений вида из спеки элемента | поэлементно | поэлементно; не список — `%Error{ns: :codec, code: :invalid_value}` | `is_list` |
  | `type: скаляр` | скаляр или `:map` — как `type:` у `Core.View` | как есть | как есть | по скаляру |

- `optional: true` — `nil` в обе стороны, отсутствующий ключ даёт `nil`; у `list:` задаётся у
  самого поля, не у элемента. `wire: "ключ"` — строка, по умолчанию имя поля строкой; загрузка
  читает ключ через `field/2` — и строковый, и атомарный. Не Prim в `prim:`, не `Core.Enum` в
  `enum:`, не struct в `entity:`, в `union:` — не модуль, struct (текст подсказывает `entity:` или
  `prim:`) или `Core.Enum` (подсказывает `enum:`), неизвестный `type:`, `optional:` внутри
  `list:`, неизвестный ключ и повтор wire-ключа — `CompileError` с именем плагина, типа и поля
- `default:` — wire-литерал, который загрузка подставляет, если ключа нет или он `nil`, и грузит как
  записанный (через Prim, `cast` enum); дамп поля обычный. Так развивается строка jsonb
  state-stored агрегата: поле, добавленное в struct, читается из строк, записанных до него.
  `default:` есть только в плагине — нагрузка события («Нагрузка по полям») развивается новым тегом
  и апкастом (`14-events-outbox.md`). `default:` с `optional: true` (два ответа на один `nil`), при
  `loadable: false` (загрузки нет) и у `enum:` вне значений enum (`cast` отказал) — `CompileError`;
  `default:` прочих видов сборка не грузит — у неё нет фасада
- Ключи спеки MUST совпадать с полями struct без `__struct__` и `events` — расхождение в любую
  сторону `CompileError` со списком лишних и недостающих: поле, добавленное в struct, не теряется в
  wire молча
- Голова `dump/2` закрывает struct и Prim каждого поля: значение не того Prim — предупреждение при
  прямом вызове плагина, через фасад — `FunctionClauseError` при исполнении
- Поле `union:` голова проверяет только `is_struct` (при `optional:` — и `nil`), тип поля в
  `@type` — `struct()`: варианты семейства знает его плагин, а не плагин родителя (решение и цена —
  ADR-0058). Struct другого плагина фасада ловит только чтение (`:unknown_tag`) — round-trip поля,
  `19-testing.md`, «Codec: round-trip». Регистрацию семейства в фасаде сборка не проверяет, как и у
  `entity:`
- `load/3` собирает struct литералом, а не через `new`: загрузка восстанавливает записанное, и
  межполевые инварианты конструктора не выполняются — типу, которому они нужны на чтении, —
  ручной плагин. Первая ошибка поля — итог, лишние ключи wire игнорируются, результат сужен до
  `{:ok, %Type{}} | {:error, _}`
- Плагин, все типы которого объявлены по полям, ручных `dump/2` / `load/3` не пишет. Многотиповый
  плагин MAY смешивать: типы, повторяющие wire, — в `fields:`, нетривиальный — ручными клаузами
  `dump/2` / `load/3` в том же плагине. Сгенерированные клаузы стоят первыми, ручные — одна с ними
  функция, `@impl true` на ручной клаузе допустим. Ручная клауза на тип из `fields:` —
  `CompileError` «never match» со списком таких клауз: валидное значение до неё не доходит, и она
  молча ловила бы только невалидное; у одного типа один источник wire. Тип задаёт литерал в
  голове (`%Type{}`, у `load/3` — `Type`) или guard переменной первого аргумента
  (`when mod in [...]`)
- `@spec` у `dump/2` / `load/3` плагина с `fields:` или `variants:` — `CompileError`: спека —
  контракт всей функции, включая сгенерированные клаузы, и спека ручного типа сузила бы их без
  сигнала сборки, только ошибкой Dialyzer у вызывающего. Контракт задаёт `@callback`
  `Core.Codec.Plugin` (`20-agreements.md`, «Спецификации типов»)
- Тип из `types:` без спеки и без ручной клаузы `dump/2` (при `loadable: true` — и `load/3`) —
  `CompileError`. Клаузой типа считается та, чей первый аргумент — `%Type{}` (у `load/3` — `Type`),
  переменная с guard `var in [...]` — для модулей списка, или не литерал типа вовсе (переменная,
  `%mod{}`); проверка действует и на плагин без `fields:`
- `loadable: false` — генерируется только `dump/2`
- `union:` без `variants:` с `fields:` совместим: варианты объявляются по полям, клауза
  `load(Family, wire, codec)` пишется руками — без неё `CompileError`. Семейство, чей вариант
  узнаётся по адресу в данных, объявляется `variants:` (ниже)
- Спеку пере-дампа (`Core.Codec.Redump`) типа плагин выводит из спеки полей — `{:map, %{wire-ключ =>
  спека}}` (решение — ADR-0059):

  | Вид поля | В спеке |
  |---|---|
  | `prim:` с приводимым kind, включая plain-kind (`:string`, `:integer`) | `{:prim, P}` |
  | `prim:` с кастомным kind, `enum:`, `type:` | нет |
  | `prim:` sensitive (и элементом `list:`) | `:sensitive` — ключ удаляется на read-пути |
  | `entity: M`, `union: F` | `{:codec, M}` / `{:codec, F}` |
  | `list: спека` | `{:list, спека элемента}`; нет, если у элемента её нет |

- Ручной плагин объявляет спеку ручного типа колбэком `redump_spec/1` (optional `@callback`
  `Core.Codec.Plugin`, `@impl true`); тип без клаузы колбэка — `ArgumentError` при первом
  пере-дампе с именами типа и плагина. Клауза `redump_spec/1` на тип из `fields:` — `CompileError`
  «never match», как ручная клауза `dump/2`

### Варианты семейства (`variants:`)

Вариант семейства (термины — `CONTEXT.md`) объявляется адресом и спекой полей, а дамп в форме
адреса, загрузку варианта и семейства и ошибки разбора генерирует `use Core.Codec.Plugin`
(решение — ADR-0057):

```elixir
use Core.Codec.Plugin,
  union: Shape,
  variants: [
    {Shape.Circle, "circle", radius: [type: :pos_integer]},
    {Shape.Rect, {"polygon", kind: :rect}, width: [type: :pos_integer], height: [type: :pos_integer]},
    {Shape.Triangle, {"polygon", kind: :triangle}, sides: [list: [type: :pos_integer]]},
    {Shape.Blob, "blob"}
  ]

@impl true
def dump_variant(%Shape.Blob{} = blob, codec), do: %{"points" => dump_many(blob.points, codec)}

@impl true
def load_variant(Shape.Blob, fields, codec) when is_map(fields) do
  with {:ok, points} <- load_many(Shape.Point, field(fields, :points), codec),
       do: {:ok, %Shape.Blob{points: points}}
end
```

- `variants:` — `{Type, адрес, spec}` (поля по спеке, как у `fields:`) или `{Type, адрес}` (ручной
  вариант); требует `union:`, иначе `CompileError`
- Адрес — одна из форм, одна на плагин:

  | Адрес | Wire |
  |---|---|
  | `"tag"` | `%{"type" => "tag", "fields" => поля}` — тегированная форма |
  | `{"tag", key: value}` | тегированная форма, `"key" => value` внутри `fields` |
  | `[key: value]` | поля и `"key" => value` без обёртки |

- Дискриминатор — одна пара `key: value`, значение атомом или строкой; дамп пишет его как объявлено
  (атом — атомом, как `enum:`), загрузка сравнивает по строке. Поле struct с именем
  дискриминатора в спеку не входит: загрузка оставляет его значение по умолчанию, и оно MUST
  равняться `value`
- `CompileError`: две формы адреса в плагине, повтор адреса, общий тег у вариантов без
  дискриминатора у каждого, разные ключи дискриминатора у одного тега (у формы без обёртки — во
  всём плагине), wire-ключ поля спеки, равный ключу дискриминатора, значение поля дискриминатора по
  умолчанию, не равное `value`
- Ручной вариант пишет только поля — колбэками `dump_variant/2` / `load_variant/3` (optional
  `@callback` `Core.Codec.Plugin`, `@impl true`); адрес, обёртку и выбор варианта пишет плагин.
  Ручной вариант без клаузы колбэка — `CompileError`
- Генерируются `dump/2` варианта в форме адреса, `load(Type, wire, codec)` — сверяет адрес и грузит
  поля, так что `load(Type, dump(x)) == {:ok, x}`, `load(Family, wire, codec)` — на любой term,
  `type/1` (тег; у формы без обёртки — значение дискриминатора строкой) и `types/0`. Ручная клауза
  `dump/2` / `load/3` на вариант или семейство — `CompileError` «never match», `@spec` у `dump/2` /
  `load/3` — `CompileError`, как у `fields:`
- Ошибки разбора — `%Error{kind: :domain, ns: :codec}`: повреждённая форма (не map, нет тега-строки,
  `fields` не map, нет дискриминатора) — `:invalid_value`; адрес вне семейства или, у
  `load(Type, …)`, не этого варианта — `:unknown_tag` с `detail: %{tag:, discriminator:}`
- Ключи тегированной формы общие с `Core.Codec.Redump` (`{:tagged, _}`). Адрес — wire-контракт:
  переименование ломает чтение записанного, ловят его golden-фикстуры
- Спека пере-дампа варианта — форма его дампа: тегированный — `{:tagged, %{тег => {:map, поля}}}`,
  без обёртки — `{:map, поля}`; дискриминатор в неё не входит. Семейство с тегированной формой даёт
  `{:tagged, %{тег => {:map, …}}}`, где спеки вариантов одного тега слиты в одну map; форма без
  обёртки — `{:map, слияние спек всех вариантов}`. Одноимённый wire-ключ с разной спекой у сливаемых
  вариантов — `CompileError` с именами плагина, вариантов и ключа: пока нет узла дискриминатора,
  слитые варианты делят спеку ключа (ADR-0059)
- Ручной вариант объявляет спеку **своих полей** (`{:map, _}`) клаузой `redump_spec/1`: обёртку и
  слияние делает плагин, конфликт с ручным вариантом — `ArgumentError` при запросе спеки семейства.
  Ручной вариант без клаузы — `ArgumentError` и у варианта, и у семейства. Клауза `redump_spec/1`
  на вариант по спеке или на семейство с `variants:` — `CompileError` «never match»; семейство
  `union:` без `variants:` объявляет спеку клаузой колбэка

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
defmodule MyApp.Domain.<BC>.Account.Cmd.Rename do
  use Core.Es.Cmd

  @enforce_keys ~w(name by at)a
  defstruct @enforce_keys
end
```

### Агрегат vs View

Агрегат — write-модель: доменные Prim, инварианты, мутации, события. Read-путь работает не с
ним (read-модель без таблицы сворачивает агрегаты внутри своего `ReadRepo` и наружу их не отдаёт;
если её не отдаёт граница, она MAY вернуть неизменяемое доменное значение —
`deps/core/docs/rules/app/13-repos.md`, «Read-модель»), а с **представлением**
(`<BC>.<ReadModel>.View`, в подкаталог актора — вместе со своей формой) — структурой из примитивных
значений (`String.t()`, `DateTime.t()`, `Decimal.t()`, `pos_integer()`, атомы `Core.Enum`).

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

`Context.Accessor` — типизированный доступ к ключу (пример:
`MyApp.Domain.<BC>.<Aggregate>.CurrentUser` с `use Core.Context.Accessor` → `:current_user_id`):

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

### Нагрузка по полям (`Core.Es.Event.Payload`)

Нагрузка, чья wire-форма повторяет поля один к одному, объявляется спекой полей — той же, что у
плагина («Плагин по полям»), без `default:` (решение — ADR-0056):

```elixir
defmodule Renamed do
  defmodule Payload do
    use Core.Es.Event.Payload,
      fields: [name: [prim: Agg.Name], note: [prim: Agg.Note, optional: true]]
  end

  use Es.Event,
    aggregate_id: Agg.ID,
    by: User.ID,
    payload: Payload
end
```

- Порождаются `@enforce_keys` (все поля, кроме `optional: true`), `defstruct`, `@type t` по видам
  полей и позиционный `new/N` в порядке объявления. Голова `new` закрывает вид каждого поля, как
  голова `dump/2` плагина (у `union:` — `is_struct`): нагрузка не того Prim в
  `Event.X.draft(Event.X.Payload.new(...))` — предупреждение при сборке вызывающего
  (`make consumer-check`)
- `<Aggregate>.Event.Codec` сам выводит клаузы нагрузки такого события тем же генератором, что у
  плагина; конверт тот же, что у плагина по полям с теми же ключами
- `default:` — `CompileError`: событие развивается новым тегом и апкастом
  (`14-events-outbox.md`, «Совместимость событий»), а не дефолтом
- В фасаде нагрузка не регистрируется — её кодирует кодек события. Нагрузка-value object со
  своим плагином и нестандартная wire-форма — «Нагрузка-сущность» ниже

### Нагрузка-Prim и `Es.ValueChanged`

Клаузы нагрузки `<Aggregate>.Event.Codec` выводит сам ещё для двух видов нагрузки — так же, как для
нагрузки по полям.

- Нагрузка-Prim (`payload: Agg.RoleID`) — `codec.dump(payload)` / `codec.load(Prim, wire)`: в
  конверте голое значение
- `use Core.Es.ValueChanged, type:, nilable:` — map `%{"old_value" => …, "new_value" => …}` по
  спеке полей из `type:`: Prim → `prim:`, `Core.Enum` → `enum:` (атом в wire, `cast` при загрузке),
  иначе `entity:`; `nilable: true` → `optional: true`. Голова `new/2` закрывает тот же вид
  значения (`%Type{}`, атом у enum, `nil` при `nilable: true`)

### Нагрузка-сущность

Нагрузку любого другого вида — struct сущности или value object — `<Aggregate>.Event.Codec`
передаёт фасаду целиком: `codec.dump(payload)` / `codec.load(Payload, wire)`. Её wire-форму задаёт
плагин её типа — по полям или ручной (ADR-0060).

- Событие объявляет тип value object нагрузкой прямо: `payload: Address`, а не модуль `Payload`,
  повторяющий его поля
- Нестандартная wire-форма нагрузки — ручной плагин её типа, а не код в кодеке событий:
  `dump_payload/2` или `load_payload/3` в модуле `use Core.Es.Event.Codec` — `CompileError`, у
  нагрузки один источник wire
- Тип нагрузки MUST обслуживать плагин того же фасада, что и кодек событий. Проверяется:
  `CompileError` сборки фасада с типом нагрузки и кодеком событий

Уникальность и квалификация wire-тега — `14-events-outbox.md`, «Domain events».

Записанное событие неизменяемо: несовместимая правка тега или нагрузки — новый тег плюс апкаст
(`14-events-outbox.md`, «Совместимость событий»; там же golden-фикстуры).

Детали flush / outbox — `14-events-outbox.md`.

## Подписи

Подписи событий для человека объявляются отдельными `use Core.Labels.*` после основного `use`
модуля, а не опциями `Core.Es.Event` и `Core.Es.Event.Payload` (ADR-0063). Модуль без них
собирается как прежде. Термины — `CONTEXT.md`, «Подписи».

```elixir
defmodule Renamed do
  defmodule Payload do
    use Core.Es.Event.Payload,
      fields: [name: [prim: Agg.Name], source: [type: :string]]

    use Core.Labels.Fields,
      labels: [name: "Название", source: :hidden]
  end

  use Es.Event,
    aggregate_id: Agg.ID,
    by: User.ID,
    payload: Payload

  use Core.Labels.Event, title: "Запись переименована"
end
```

Ошибки сборки объявлений — `CompileError`; опции `use` проверяет `Core.Helper.Opts.validate!/4`,
текст подписи и keyword-список решений без повторов — `Core.Labels.Check`. Своя проверка текста
или опций в модуле объявления MUST NOT.

### Название события (`Core.Labels.Event`)

- `title:` обязательна — непустая строка
- `payload:` — подпись нагрузки-Prim: у неё обязательна, у нагрузки-struct'а и у события без
  нагрузки — `CompileError`; нагрузку-struct подписывает `Core.Labels.Fields`
- нагрузка-struct без `use Core.Labels.Fields` — `CompileError`
- `use` вне модуля `use Core.Es.Event` — `CompileError`: хост проверяется по интроспекции события

Проверяется: `test/core/labels/event_test.exs`.

### Подписи полей (`Core.Labels.Fields`)

`labels:` — решение по каждому полю struct'а: подпись или `:hidden`. У нагрузки
`Core.Es.Event.Payload` вид поля в сведениях берётся из её спеки, в объявлении подписей его нет.

- Полнота — на `@after_compile`: поле без решения и подпись поля вне struct'а — `CompileError`
- Повтор поля, пустая или не строковая подпись — `CompileError`
- Свободная map (`type: :map`) с id в ключах выходит подписями поля, ключа и значения —
  `[label:, key:, value:]`, иначе `:hidden`; подпись строкой у map'ы, подписи map'ы у поля, которое
  не map'а, ключ вне `label:` / `key:` / `value:` и пустая подпись в них — `CompileError`
- Вложенный struct (`entity:`) без `use Core.Labels.Fields` — `CompileError`
- `use` не после `use Core.Es.Event.Payload` и без `fields:` — `CompileError`

Struct без спеки полей — нагрузка с ручным плагином кодека, вложенный struct сведений, вариант
семейства — объявляет спеку **видимых** полей `fields:` на языке плагина по полям («Плагин по полям
(`fields:`)»). Её разбирает нормализатор `Core.Codec.Plugin.Fields`; копия разбора в подсистеме
MUST NOT: язык спеки один, и новый вид плагина иначе разошёлся бы с подписями. Сверх языка плагина —
вид `text:`: захват функции арности 1, значение выходит текстом её результата; так подписывается
значение без собственного модуля — поле с одним из двух struct'ов, список открытых атомов.

```elixir
defmodule Address do
  defstruct [:city, :origin, :tags, :checksum]

  use Core.Labels.Fields,
    fields: [
      city: [prim: Agg.City],
      origin: [text: &__MODULE__.origin_text/1],
      tags: [list: [text: &Atom.to_string/1]]
    ],
    labels: [city: "Город", origin: "Источник", tags: "Метки", checksum: :hidden]
end
```

- Спека поля и у нагрузки события, и в `fields:` — `CompileError`: у вида поля один источник
- Видимое поле без спеки, спека скрытого поля или поля вне struct'а — `CompileError`
- `text:` не захватом функции арности 1, `text:` / `list: [text: …]` с другими ключами —
  `CompileError`
- Без `labels:` и `change:`, модуль без struct'а — `CompileError`

Нагрузка «было → стало» объявляет вместо `labels:` одну подпись изменения `change:` — ровно одна из
двух опций: изменение выходит в сведения одним сведением, а не двумя полями. Вид значения у
`Core.Es.ValueChanged` берётся из его `type:`; у ручного struct'а с полями `old_value` / `new_value`
его задаёт `value:` — спека одного значения на языке `fields:`, вместе с `text:`.

```elixir
defmodule Payload do
  use Core.Es.ValueChanged,
    type: Agg.Name

  use Core.Labels.Fields, change: "Название"
end

defmodule Payload do
  defstruct [:old_value, :new_value]

  use Core.Labels.Fields,
    change: "Метки",
    value: [list: [text: &Atom.to_string/1]]
end
```

- `labels:` вместе с `change:`, `fields:` вместе с `change:` — `CompileError`
- Ручной struct изменения без `value:`, `value:` у `Core.Es.ValueChanged` (у вида значения один
  источник — `type:`), `value:` без `change:` — `CompileError`
- Struct без `old_value` / `new_value` под `change:`, пустая подпись изменения — `CompileError`
- `use` под `change:` не после `use Core.Es.ValueChanged` или `defstruct` — `CompileError`: иначе
  `Core.Es.ValueChanged` ниже сошёл бы за ручной struct
- Свободная map и вложенный struct без `use Core.Labels.Fields` в виде значения — `CompileError`,
  как у поля

Интроспекция:

- `specs/1` — спека видимых полей в порядке объявления: спеки нагрузки или `fields:`; у изменения —
  пусто
- `change/1` — подпись и вид значения изменения или `nil` у struct'а с подписями полей
- `paths/1` — подписи видимых полей типа по пути поля (`[:address, :city]`), без значения: поля
  вложенного struct'а — под путём своего поля, поля элемента списка struct'ов — под путём списка;
  `union:` даёт только свою подпись — варианты по типу не известны; map'а с id в ключах — подпись
  поля `label:`

Проверяется: `test/core/labels/fields_test.exs`.

### Подписи значений (`Core.Labels.Values`)

`use Core.Labels.Values, labels:` в Enum после `use Core.Enum` — подпись каждого значения. Порождает
`label/1` — подпись значения — и `labels/0` — пары «значение — подпись» в порядке `values/0`, а не
`labels:`.

```elixir
use Core.Enum,
  name: first_line(@moduledoc),
  values: ~w(active closed)a

use Core.Labels.Values,
  labels: [active: "Активна", closed: "Закрыта"]
```

- `label/1` принимает только значения Enum: голова закрывает домен, иное — `FunctionClauseError`, а
  при известном значении — предупреждение компилятора
- Значение без подписи и подпись вне Enum — `CompileError`
- Повтор значения, пустая или не строковая подпись, `labels:` не keyword-списком — `CompileError`
- `use` не после `use Core.Enum` — `CompileError`

Поле нагрузки вида `enum:` выходит в сведения текстом — подписью значения.

Проверяется: `test/core/labels/values_test.exs`; вывод типов — `make consumer-check`.

### Вид id (`Core.Labels.ID`)

`use Core.Labels.ID` в Prim-идентификаторе после `use Core.Prim.*` — как id выходит в сведения:

| `kind:` | В сведениях | Опции |
|---|---|---|
| `:ref` | ссылка на запись `%{kind: :ref, entity: вид записи, value: id}` | `entity:` — атом, `resolver:` |
| `:user` | ссылка на учётную запись `%{kind: :user, value: id}` | `resolver:` |
| `:id` | только id — `%{kind: :text, value: id}`, без похода в резолвер | — |

```elixir
use Core.Prim.UUID,
  name: "Счёт",
  version: 7

use Core.Labels.ID,
  kind: :ref,
  entity: :account,
  resolver: Agg.Query
```

Вид записи — атом, не wire-строка: camelCase на wire делает wire. Резолвер — модуль, который отдаёт
текущее имя записи по id.

- `kind:` вне `~w(ref user id)a`, отсутствие `kind:` — `CompileError`
- `entity:` — атом, обязателен у `:ref`, у `:user` и `:id` — `CompileError`
- `resolver:` — модуль, обязателен у `:ref` и `:user`, у `:id` — `CompileError`
- `use` не после `use Core.Prim.*` и вместе с `use Core.Labels.Text` — `CompileError`: у значения
  один способ выйти в сведения

`Core.Labels.ID.find/1` — объявление по модулю или `nil`.

Проверяется: `test/core/labels/id_test.exs`.

### Prim текстом (`Core.Labels.Text`)

`use Core.Labels.Text, with:` в Prim после `use Core.Prim.*` — функция текста: Prim, значение
которого — машинный код, выходит в сведения видом `:text` с её результатом. Функция получает Prim,
`nil` ей не передаётся.

```elixir
use Core.Prim.String,
  name: "Валюта",
  min_len: 3,
  max_len: 3

use Core.Labels.Text, with: &Agg.Currency.title/1
```

- `with:` не захватом функции арности 1 (`&Mod.fun/1`) — `CompileError`: анонимная функция модуля,
  который ещё собирается, в атрибут не сохраняется
- `use` не после `use Core.Prim.*` и вместе с `use Core.Labels.ID` — `CompileError`

`Core.Labels.Text.find/1` — функция по модулю или `nil`.

Проверяется: `test/core/labels/text_test.exs`.

### Сведения события (`Core.Labels.Details`)

`Details.build/1` — чистая функция «событие → `{название, сведения}`». Сведение —
`%{label, kind, value}`, значение — Prim как есть: дампа нет, в JSON его переводит wire.

| `kind` | Спека поля |
|---|---|
| `:text` | Prim `:string`; `type: :string`; `type: :boolean` — «Да» / «Нет»; `enum:` — подпись значения; `text:` и Prim с `Core.Labels.Text` — результат функции; id `kind: :id` |
| `:number` | Prim `:integer`, `:decimal`; `type:` целого |
| `:date`, `:datetime` | Prim `:date`, `:datetime` |
| `:user` | id `kind: :user` |
| `:ref` | id `kind: :ref`; рядом `entity` — вид записи |
| `:group` | `entity:` — сведения вложенного struct'а; `union:` — сведения полей варианта по его `Core.Labels.Fields` |
| `:list` | `list:` — элементы `%{kind, value}` вида спеки элемента, без подписи; map'а с `[label:, key:, value:]` — группы «ключ — значение» |
| `:change` | struct изменения (`change:`) — вместо `value` стороны `old` и `new`: `%{kind, value}` вида значения изменения, без подписи |

- Сведения идут в порядке спеки полей; `:hidden` в них не попадает
- Prim-композит (`Core.Prim.Compose`) выходит видом своего базового Prim: обёртка роли не меняет
  отображение. Вид id или текст базы действует и на композит: значение — база с объявлением, текст —
  функция от неё
- Map'а с id в ключах — список групп по паре: ключ с подписью `key:`, значение с подписью `value:`;
  вид каждого — по самому значению (Prim, строка, число, `boolean`, `nil`). Ссылками ключи выходят,
  только если нагрузку грузит ручной плагин с Prim в ключах: `type: :map` плагина по полям грузит
  map'у как есть, и ключи-строки выходят текстом
- Prim-идентификатор (`Core.Prim.UUID`) без `Core.Labels.ID` и `Core.Labels.Text` — `ArgumentError`
  с именем модуля: ошибка программиста, а не молчаливый текст
- Поле без значения — `value: nil` со своим видом; нагрузка `nil` — пустые сведения; нагрузка-Prim —
  одно сведение с подписью `payload:`
- Struct изменения — одно сведение `%{label, kind: :change, old, new}`; сторона без значения —
  `value: nil`

Проверяется: `test/core/labels/details_test.exs`.

Вид `type:` MUST задаваться на каждое значение `Core.Helper.FieldCheck.type_values/0`, отдельный
перечень видов MUST NOT: новый тип проверки полей иначе дошёл бы до сведений без вида.

Проверяется: сборка библиотеки — `Core.Labels.Details` берёт вид каждого значения
`type_values/0` через `Keyword.fetch!`.

Нормы приложения, отдающего сведения событий, — `deps/core/docs/rules/app/11-domain.md`,
«Подписи».

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

Формы результата названы типами `Core.Result` и `Core.Option`:

| Тип | Форма | Когда |
|---|---|---|
| `Result.t(a)` | `{:ok, a} \| {:error, Error.t()}` | значение `a`, ошибка библиотеки — частый случай |
| `Result.t(a, e)` | `{:ok, a} \| {:error, e}` | причина не `%Error{}`: `:none`, `{code, detail}`, `term()` |
| `Result.t()` | `Result.t(term(), Error.t())` | значение произвольно |
| `Result.unit()` | `:ok \| {:error, Error.t()}` | CQS-команда без возвращаемого значения |
| `Result.unit(e)` | `:ok \| {:error, e}` | то же, причина не `%Error{}` |
| `Option.t(a)` | `a \| nil` | опциональное значение |

Локальный `@type`, чья форма совпадает с результатом, MUST выражаться этими типами, а не заводить
форме второе имя: имя результата одно на библиотеку, а параметр называет причину. Тип с третьим
вариантом (`{:skip, _}` у `Core.PubSub.handler_result`) или объединяющий unit с valued
(`Core.Helper.Savepoint.result`) MAY оставаться таплом: через типы он длиннее и читается хуже.

```elixir
# плохо — форма переписана прописью в каждом модуле
@type result :: :ok | {:error, {code(), detail()}}
@type to_message :: (message(), metadata() -> {:ok, Message.t()} | {:error, Error.t()})

# хорошо — имя одно, параметр называет причину
@type result :: Result.unit({code(), detail()})
@type to_message :: (message(), metadata() -> Result.t(Message.t()))
```

В `@spec` функции развёрнутая форма MAY оставаться: там она — контракт, читаемый глазами на месте,
и так записаны спеки repo-методов, `@callback` behaviour'ов и таблицы возвратов `13-repos.md`.
Правило про второе имя формы касается `@type`, где имя как раз и заводится.

Состав обоих модулей — по назначению функции. Набор полон намеренно: соседняя функция
назначения есть всегда, и call site не проверяет это перед вызовом.

| Назначение | `Core.Result` |
|---|---|
| конструкторы | `ok/0`, `ok/1`, `error/1` |
| комбинаторы успеха | `map/2`, `and_then/2`, `map_or/3`, `map_or_else/3`, `and_/2` |
| комбинаторы ошибки | `map_error/2`, `or_/2`, `or_else/2` |
| эффект | `tap/2` |
| предикаты | `ok?/1`, `error?/1` |
| терминаторы | `unwrap!/1`, `unwrap_or/2`, `unwrap_or_else/2` |
| обход списка | `traverse/2`, `traverse_all/2` |
| конверсия | `to_option/1` |

| Назначение | `Core.Option` |
|---|---|
| комбинаторы | `map/2`, `or_/2`, `or_else/2` |
| предикат | `some?/1` |
| терминаторы | `unwrap!/1`, `unwrap_or/2`, `unwrap_or_else/2` |
| конверсии | `to_result/1` (valued), `to_unit/1` (unit, CQS) |

`unwrap!/1` — единственная bang-дверь обоих модулей; выбор safe против bang на call site —
`20-agreements.md`, «Safe vs bang».

Новая функция заводится по требованию call site и MUST занимать место в одной из строк
таблицы. Удаление публичной функции — ломающее изменение контракта: пункт CHANGELOG «Ломающие
изменения контракта» с «было → стало» на каждое имя. Ноль вызовов внутри `lib/` основанием для
удаления MUST NOT быть: модуль публичен для потребителя, которого библиотека знать не имеет
права (`10-architecture.md`), и срез использования по её коду вызовов у потребителя не видит.

```text
# плохо — функция убрана по нулю вызовов в lib/, у потребителя она есть, в CHANGELOG ни строки

# хорошо — «Ломающие изменения контракта»:
- `Result.expect!/2` удалён — вторая bang-дверь вела мимо `Exc`:
  было `Result.expect!(res, "нет значения")` → стало `Result.unwrap!(res)`
```

Предикаты `ok?/1` / `error?/1` / `some?/1` держатся в наборе для позиции функции-значения, где
матч не выражается; форму результата в своём коде MUST разбирать клозой или `case` / `with`
(`20-agreements.md`, «Паттерн-матчинг и арность»).

```elixir
# плохо — предикат вместо матча в своём коде
if Result.ok?(res), do: handle(res), else: :skip

# хорошо — предикат там, где нужна функция-значение
Enum.split_with(results, &Result.ok?/1)
```

Домен обоих обходов — список: `traverse/2` и `traverse_all/2` принимают `[a]`, а не
`Enumerable.t()`. Пачку иной формы (карта, `MapSet`, поток) call site MUST приводить к списку сам —
`Map.to_list/1`, `Map.values/1`, `Enum.to_list/1`. Так guard `is_list/1` держит связь «список на
входе → список на выходе», а промах виден предупреждением компиляции при известном типе входа.
Замеры call sites и отвергнутое расширение — ADR-0022.

```elixir
# плохо — карта прямо в обход: предупреждение инференса, а на dynamic-значении — отказ в рантайме
Result.traverse(params, &load_param(&1, codec))

# хорошо — приведение на call site; видно и то, что колбэк получает пары {k, v}
Result.traverse(Map.to_list(params), &load_param(&1, codec))
```

Проверяется: `test/core/result_test.exs`, тесты «traverse/2 rejects non-list at runtime» и
«traverse_all/2 rejects non-list at runtime».

Guard арности MUST стоять на **каждой** клозе функции и на каждом аргументе, который контракт
объявляет колбэком (у `map_or_else/3` их два), а не только там, где колбэк вызывается:
`is_function(fun, 0)` — у нуль-арных (`or_else/2`, `unwrap_or_else/2` обоих модулей),
`is_function(fun, 1)` — у остальных. Домен аргумента не зависит от формы результата на входе:
колбэк чужой арности недопустим по `@spec` на любой ветке. Без guard'а на клозе, которая колбэк
не зовёт, неверная арность проходит и сборку, и рантайм — функция молча отдаёт свой обычный
результат; с ним литеральный колбэк даёт предупреждение инференса на call site, а спрятанный за
`dynamic()` — `FunctionClauseError`.

```elixir
# плохо — guard только на клозе с вызовом: or_else(:ok, fn _ -> ... end) молча отдаёт :ok
def or_else(:ok, _fun), do: :ok
def or_else({:error, _reason}, fun) when is_function(fun, 0), do: fun.()

# хорошо — домен аргумента один на все формы входа
def or_else(:ok, fun) when is_function(fun, 0), do: :ok
def or_else({:error, _reason}, fun) when is_function(fun, 0), do: fun.()
```

Проверяется: `test/core/result_test.exs` и `test/core/option_test.exs`, тесты «отвергает колбэк
чужой арности»; снятие guard'а с любой клозы без вызова валит прогон.

Набор функций `Core.Result` делится по форме успеха на входе: функция, которой значение нужно,
на `:ok` даёт `FunctionClauseError`. Состав групп — таблица в `@moduledoc Core.Result`.

Проверяется: `test/core/result_test.exs`, тест «value ops reject unit at runtime».

## Связанные правила

- Архитектура / usecases — `10-architecture.md`
- Ошибки / `Exc` — `12-errors.md`
- Persist агрегатов — `13-repos.md`
- События и outbox — `14-events-outbox.md`
