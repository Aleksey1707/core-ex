# Ошибки

Типичная реализация: struct `%Error{}` + обёртка `defexception` для `raise` (например `Exc`).

## Общие правила

- Классифицировать каждую ошибку: доменное | прикладное | ошибка программиста.
- Каждая ошибка требует обработки — стандартной или кастомной.
- В логах MUST NOT попадать чувствительные данные (пароли, токены, ключи, ПДн, банковские данные) — механика в разделе «Чувствительные данные».
- Предпочтительный канал — `{:error, %Error{}}`; `raise` — только на границе, где результат обязан быть успешным (например `new!` / `get!`).
- Единственное место поднятия исключения из `%Error{}` — bang-границы (`Prim.new!/1`, `get!/…`, `Result.unwrap!/1` при `%Error{}`, Schema `to_entity!`/`to_model!` и т.п.): `raise Exc, error` (в т.ч. через `Result.unwrap!`).

## Структура

`%Error{kind, ns, module, code, message, detail, parent}`:

| Поле | Назначение |
|---|---|
| `kind` | `:domain` или `:app` |
| `ns` | атом предметной категории ошибки (обязателен); **не** `Domain.Perms.Namespace` |
| `module` | модуль-источник (кто создал) |
| `code` | атом кода ошибки |
| `message` | текст для клиента / логов; **обязателен для `:domain`**, опционален для `:app` (`nil` → `String.Chars` fallback `"#{ns}/#{code}"`) |
| `detail` | произвольный контекст ошибки (`term()`) — без фиксированной формы; `nil`, map, struct, exception, … |
| `parent` | опциональная внутренняя ошибка (cause); default `nil` |

Конструкторы: макросы `Error.domain/1|2`, `Error.app/1|2`. На call site нужен `require Error` (рядом с `alias`).

- `/1` — только attrs; `module` = `__CALLER__.module` (прямые call site'ы).
- `/2` — явный `module` + attrs (каталоги `*.Errors`, чужой источник).
- Литеральный kwlist attrs → compile-time проверка ключей (required / unknown) в макросе (`CompileError`).
- Динамический attrs (переменная) / внутренние `__domain__/2` / `__app__/2` → `Keyword.fetch!` на runtime (`KeyError`).
- Не путать с `Helper.Keyword.check_opts!` (для `__using__` / compile opts модулей).

| Kind | Обязательные attrs | Опциональные attrs |
|---|---|---|
| `:domain` | `code:`, `ns:`, `message:` | `detail:`, `parent:` |
| `:app` | `code:`, `ns:` | `message:`, `detail:`, `parent:` |

```elixir
Error.domain(code: :not_found, ns: :product, message: "…", detail: id)
Error.app(code: :cycle_failed, ns: :outbox, detail: e, parent: inner)
# каталог / чужой источник:
Error.domain(OtherMod, code: :not_found, ns: :product, message: "…", detail: id)
```

`ns` — самостоятельный словарь классификации ошибок (`:auth`, `:mq`, …). Может быть детальнее permission-ns; не обязан совпадать с `Agg.ns()` / `Domain.Perms.Namespace`.

Не путать `Error.detail` (произвольный payload) с Prim-кортежем `{code, detail}` (строка текста валидации).

## Чувствительные данные

`Error.detail` по умолчанию содержит **сырой ввод** (`Prim.wrap_error(..., raw)`), а `%Error{}`
попадает в логи и Sentry через `inspect/1` (`FallbackController`, `Logger.error`, crash-репорты).
Значит, любой Prim, значение которого нельзя показывать, обязан быть помечен.

### Prim: `sensitive: true`

```elixir
use Core.Prim.String,
  name: first_line(@moduledoc),
  min_len: 8,
  max_len: 32,
  sensitive: true
```

Что даёт опция:

| Эффект | Как |
|---|---|
| `inspect/1` не печатает значение | `@derive {Inspect, except: [:value]}` → `#Password<...>` |
| `Error.detail` не содержит raw | `{:redacted, byte_size}` для binary, `:redacted` для остального |
| Флаг доступен коду | `__domain_sensitive__/0` |

`Prim.Compose` наследует чувствительность базового Prim; явный `sensitive:` перебивает наследование.
Опция есть у всех обёрток (`Prim.String` / `Integer` / `UUID` / `Decimal` / `Date` / `DateTime` / `Compose`).

MUST помечать: пароли (plaintext и хеши), токены и ключи, коды подтверждения, ПДн, платёжные реквизиты.

### Структуры и колонки

- Секрет MUST лежать внутри `sensitive`-Prim или `Core.Security.Secret` — тогда любая обёртка
  (`%WithSchema{token: %Token{}}`, `%Settings{password: %Secret{}}`) безопасна автоматически,
  и дублирующий `@derive` на самой обёртке не нужен.
- Структура, хранящая секрет «голой» строкой (без Prim) — `@derive {Inspect, except: [...]}`
  либо `defimpl Inspect` (образцы: `Core.Security.Secret`, `Core.Mq.Stream.Credentials`).
- Ecto-колонка с секретом (в т.ч. JSON, где секрет вложен) — `redact: true`:
  `field :data, JSONType, redact: true`.

### Границы auth

MUST NOT класть в `Error.detail` сырой credential — заголовок `Authorization`, plaintext токена,
пароль. Вместо значения — его размер:

```elixir
{:error, Errors.domain(__MODULE__, :invalid_token, %{len: byte_size(raw)})}
```

### Чек-лист: добавляю новый секрет

1. Значение живёт в Prim с `sensitive: true` (или в `Secret`).
2. Колонка, куда он пишется, помечена `redact: true`.
3. Ни один `Logger.*` не интерполирует значение (только id / длину / признак наличия).
4. На границе auth в `detail` — не credential.
5. Тест: `refute inspect(...) =~ plaintext` (для Prim из `lib`; Prim, объявленный в самом
   тесте, не попадает в консолидацию протоколов — фикстуры класть в `test/support`).

## Оборачивание (cause-цепочка)

Аналог Go `fmt.Errorf("%w")` / `errors.Unwrap` / `errors.Is` / `errors.As`:

| Функция | Назначение |
|---|---|
| `Error.wrap/2` или `parent:` в attrs | связать outer → parent (cause) |
| `unwrap/1` | parent или `nil` |
| `root/1` | самая внутренняя |
| `chain/1` | `[outer, …, root]` |
| `has?/2` | есть ли в цепочке узел по keyword (`ns:`, `code:`, `kind:`, `module:`) |
| `find/2` | первый узел по предикату |
| `format_chain/1` | `"outer: …: root"` по `message` (или fallback `ns/code`) — для логов |

Правила:

- `wrap` **не** меняет `message` автоматически.
- Domain → клиенту по-прежнему **outer** `message` (`String.Chars` / HTTP); цепочку не отдавать.
- App / логи — `inspect(err)` или `Error.format_chain/1`.
- Wrap уместен на app-слое поверх domain/infra cause.
- Иерархии классов нет: linked list через `parent`; группировка по `{ns, code}` на нужном уровне через `has?`/`find`.
- `%Error{}` — `Enumerable`: итерация = `[outer, …, root]` (`Enum.any?(err, &(&1.code == :not_found))` / `Error.has?(err, code: :not_found)`).

## Матрица категорий

| Категория | Суть | Представление | Клиенту | Логи | Стандартный handler | Исправление |
|---|---|---|---|---|---|---|
| Доменные | Бизнес-инварианты; невалидный ввод или семантически неверный запрос. Содержимое — только предметная область | `%Error{kind: :domain, ...}` | Показывать `message` без обработки | Не обязательно; часто нежелательно | Ответ из `message`, без логирования | Не исправлять |
| Прикладные | Сбой прикладного компонента (HTTP-клиент и т.п.) или flow control | `%Error{kind: :app, ...}` | Не показывать | Логировать необработанные | Как у программистских | Кастомный handler; иначе — баг |
| Программиста | Ошибка разработки (неверные аргументы, типы, зависимости, контракты API) | не `%Error{}` (`ArgumentError`, crash, иное исключение) | Шаблон «Произошла непредвиденная ошибка»; менеджеру — минимум для локализации | Обязательно | Шаблон + логирование | Исправить код |

## Классификация

- Не каждое исключение/ошибка OTP — доменная/прикладная ошибка; каждая такая ошибка представлена `%Error{}`.
- Необработанный `%Error{kind: :app}` → ошибка программиста.
- Ситуация доменная/прикладная по смыслу, но возвращена/поднята не через `%Error{}` → ошибка программиста.
- Валидация ввода → доменное (`Error.domain/2`). `ArgumentError` и прочие стандартные исключения — НЕ доменные.
- Flow control у прикладных → кастомный handler.
- Доменные — кастомный handler допустим по необходимости; обычно достаточно стандартного.
- Термин «домен» — только для кода с бизнес-логикой; в инфраструктуре — «предметная область».
- Typespecs / Dialyzer могут частично отловить ошибки программиста на этапе типов.

## Иерархия и группировка

- Иерархии классов нет: группировка по `{ns, code}` (+ `module` как источник).
- Доменные: `Error.domain(Module, code: :…, ns: :…, message: "...")`.
- Прикладные: `Error.app(Module, code: :…, ns: :…)`.
- Всё, что не является `%Error{kind: :domain | :app}`, — ошибка программиста.
- Ошибки программиста MUST NOT обрабатываться кастомным handler'ом как доменные/прикладные.

## Каталог агрегата (`<Aggregate>.Errors`)

Доменные ошибки агрегата объявлять в `MyApp.Domain.<BC>.Common.<Aggregate>.Errors`:

- `ns/0` — атом пространства имён ошибок.
- `domain(module, code, detail)` / `domain(module, code, detail, message)` — PM по `code`, **без** catch-all и **без** `@type code`.
- Clause: `def domain(module, :empty = code, detail, message)` → `Error.domain(module, code: code, ns: ns(), message: …, detail: detail)` (не дублировать атом кода).
- `module` — `__MODULE__` вызывающего; `message` опционален (дефолт в clause); если тексты для одного кода различаются — message обязателен на call site.
- Возврат — `%Error{}`; обёртку `{:error, _}` оставляет вызывающий.
- Repo-коды (`:not_found`, `:version_mismatch`, `:incomplete_result`, `:no_ids`) — в том же каталоге; `use Repo.Pg, errors: Draft.Errors` (через родителя агрегата, не leaf `Errors`).

## Источники `%Error{}` в проекте

- Доменные примитивы (`Prim`) и агрегаты — основной источник `%Error{kind: :domain}` (см. `11-domain.md`); агрегаты — через `<Aggregate>.Errors`.
- Репозитории (`Repo.Pg`): `not_found` / `version_mismatch` / … → `errors_mod.domain(behaviour, code, detail)`; провал `insert`/`update` → `{:error, Ecto.Changeset.t()}` (не `%Error{}`) — см. `13-repos.md`.
- Outbox / инфраструктура — часто `%Error{kind: :app}` (см. `14-events-outbox.md`).
