# Ошибки

- **Область.** `lib/core/error.ex`, `lib/core/exc.ex`, `lib/core/security/secret.ex`; у потребителя
  — каталоги `<Aggregate>.Errors` и обработчики на границе.
- **Читать перед.** Введением нового кода ошибки или каталога агрегата, работой с чувствительными
  данными, правкой cause-цепочек и обработчиков `%Error{}`.
- **Словарь.** Плейсхолдеры и модальность — `00-index.md`.

Типичная реализация: struct `%Error{}` + обёртка `defexception` для `raise` (например `Exc`).

## Общие правила

- Классифицировать каждую ошибку: доменное | прикладное | ошибка программиста.
- Каждая ошибка требует обработки — стандартной или кастомной.
- В логах MUST NOT попадать чувствительные данные (пароли, токены, ключи, ПДн, банковские данные) —
  механика в разделе «Чувствительные данные».
- Предпочтительный канал — `{:error, %Error{}}`; `raise` — только на границе, где результат обязан
  быть успешным (например `new!` / `get!`).
- Единственное место поднятия исключения из `%Error{}` — bang-границы (`Prim.new!/1`, `get!/…`,
  `Result.unwrap!/1` при `%Error{}`, Schema `to_entity!`/`to_model!` и т.п.): `raise Exc, error` (в
  т.ч. через `Result.unwrap!`).

## Структура

`%Error{kind, ns, module, code, message, detail, parent}`:

| Поле | Назначение |
|---|---|
| `kind` | `:domain` или `:app` |
| `ns` | атом предметной категории ошибки (обязателен); **не** namespace разрешений приложения |
| `module` | модуль-источник (кто создал) |
| `code` | атом кода ошибки |
| `message` | текст для клиента / логов; **обязателен для `:domain`**, опционален для `:app` (`nil` или `""` → `String.Chars` fallback `"#{ns}/#{code}"`) |
| `detail` | произвольный контекст ошибки (`term()`) — без фиксированной формы; `nil`, map, struct, exception, … |
| `parent` | опциональная внутренняя ошибка (cause); default `nil` |

Конструкторы: макросы `Error.domain/1|2`, `Error.app/1|2`. На call site нужен `require Error` (рядом
с `alias`).

- `/1` — только attrs; `module` = `__CALLER__.module` (прямые call site'ы).
- `/2` — явный `module` + attrs (каталоги `*.Errors`, чужой источник).
- Литеральный kwlist attrs → compile-time проверка ключей (required / unknown / дубли) в макросе
  (`CompileError`).
- Динамический attrs (переменная) / внутренние `__domain__/2` / `__app__/2` → проверка на runtime:
  отсутствие обязательного — `KeyError` (`Keyword.fetch!`), лишний ключ — `ArgumentError`.
- Не путать с `Helper.Opts.validate!` (для `__using__` / compile opts модулей).
- `parent:` принимает только `%Error{}` или `nil`; иное — `FunctionClauseError` (ошибка
  программиста), как и у `wrap/2`.

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

`ns` — самостоятельный словарь классификации ошибок (`:prim`, `:mq`, `ns/0` каталога агрегата, …).
Может быть детальнее namespace разрешений приложения и не обязан с ним совпадать.

Не путать `Error.detail` (произвольный payload) с Prim-кортежем `{code, detail}` (строка текста
валидации).

## Чувствительные данные

`Error.detail` по умолчанию содержит **сырой ввод** (`Prim.wrap_error(..., raw)`), а `%Error{}`
попадает в логи и Sentry через `inspect/1` (`FallbackController`, `Logger.error`, crash-репорты).
Значит, любой Prim, значение которого нельзя показывать, обязан быть помечен.

### Prim: `sensitive: true`

Что делает опция — скрытие в `inspect/1`, редактирование `Error.detail`, наследование в
`Prim.Compose` — `11-domain.md`, «Prim (value object)».

```elixir
use Core.Prim.String,
  name: first_line(@moduledoc),
  min_len: 8,
  max_len: 32,
  sensitive: true
```

MUST помечать: пароли (plaintext и хеши), токены и ключи, коды подтверждения, ПДн, платёжные
реквизиты.

### Структуры и колонки

- Секрет MUST лежать внутри `sensitive`-Prim или `Core.Security.Secret` — тогда любая обёртка
  (`%WithSchema{token: %Token{}}`, `%Settings{password: %Secret{}}`) безопасна автоматически,
  и дублирующий `@derive` на самой обёртке не нужен.
- Структура, хранящая секрет «голой» строкой (без Prim) — `@derive {Inspect, except: [...]}`
  (образец — `Core.Mq.Stream.Credentials`) либо `defimpl Inspect`, печатающий **не** саму
  структуру (образец — `Core.Security.Secret`: константа `"#Secret<...>"`). `defimpl`, отдающий
  `Inspect.Algebra.to_doc/2` от той же структуры с заменённым полем, зовёт сам себя —
  бесконечная рекурсия, и `inspect/1` вешает процесс.
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
| `has?/2` | есть ли в цепочке узел по keyword (`ns:`, `code:`, `kind:`, `module:`); критерий непустой, иной ключ или не keyword-пара — `ArgumentError` |
| `find/2` | первый узел по предикату |
| `format_chain/1` | `"outer: …: root"` по `message` (или fallback `ns/code`) — для логов |

Правила:

- `wrap` **не** меняет `message` автоматически.
- `wrap` поверх ошибки, у которой `parent` уже есть, подцепляет новый cause в **конец** цепочки —
  он становится `root/1`; ничего из существующей цепочки не теряется.
- Domain → клиенту по-прежнему **outer** `message` (`String.Chars` / HTTP); цепочку не отдавать.
- App / логи — `inspect(err)` или `Error.format_chain/1`.
- Wrap уместен на app-слое поверх domain/infra cause.
- Иерархии классов нет: linked list через `parent`; группировка по `{ns, code}` на нужном уровне
  через `has?`/`find`.
- `%Error{}` — `Enumerable`: итерация = `[outer, …, root]`
  (`Enum.any?(err, &(&1.code == :not_found))` / `Error.has?(err, code: :not_found)`). Обратная
  сторона: `%Error{}` вместо списка проходит через `Enum.*` молча — форму проверять до итерации.

## Матрица категорий

| Категория | Суть | Представление | Клиенту | Логи | Стандартный handler | Исправление |
|---|---|---|---|---|---|---|
| Доменные | Бизнес-инварианты; невалидный ввод или семантически неверный запрос. Содержимое — только предметная область | `%Error{kind: :domain, ...}` | Показывать `message` без обработки | SHOULD NOT: доменная ошибка — не инцидент | Ответ из `message`, без логирования | Не исправлять |
| Прикладные | Сбой прикладного компонента (HTTP-клиент и т.п.) или flow control | `%Error{kind: :app, ...}` | Не показывать | Логировать необработанные | Как у программистских | Кастомный handler; иначе — баг |
| Программиста | Ошибка разработки (неверные аргументы, типы, зависимости, контракты API) | не `%Error{}` (`ArgumentError`, crash, иное исключение) | Шаблон «Произошла непредвиденная ошибка»; менеджеру — минимум для локализации | Обязательно | Шаблон + логирование | Исправить код |

## Классификация

- Не каждое исключение/ошибка OTP — доменная/прикладная ошибка; каждая такая ошибка представлена
  `%Error{}`.
- Необработанный `%Error{kind: :app}` → ошибка программиста.
- Ситуация доменная/прикладная по смыслу, но возвращена/поднята не через `%Error{}` → ошибка
  программиста.
- Валидация ввода → доменное (`Error.domain/2`). `ArgumentError` и прочие стандартные исключения —
  НЕ доменные.
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

Каталог ошибок — модуль, который макросы репозиториев принимают опцией `errors:` и зовут как
`errors.domain(behaviour, code, detail)`. Возврат — `%Error{}`, обёртку `{:error, _}` добавляет
репозиторий. Сборка проверяет каталог вызовом `domain(_, code, nil)` на каждый код, который
макрос может вернуть:

| Макрос | Коды, обязательные в `errors:` |
|---|---|
| `use Core.Repo.Pg` (read- и write-репозиторий) | `:not_found`, `:version_mismatch`, `:incomplete_result`, `:no_ids` и каждый код `constraint_errors:` |
| `use Core.Repo.Pg.StateStored` | коды `Repo.Pg` плюс коды `constraint_errors:` дочерних схем `children:` |
| `use Core.Es.Aggregate.Repo.Pg` | `:version_mismatch` и `code:` каждого модуля `key_reservations:` |

- Клаузы по коду MUST NOT иметь catch-all: пропущенный код сборка находит по
  `FunctionClauseError`, а catch-all превращает опечатку в валидную ошибку и прячет перечень
  кодов.
- Clause обязательного кода MUST принимать `detail` `nil`: с ним её зовёт проверка при сборке.

Проверяется: `CompileError` в `use Core.Repo.Pg`, `use Core.Repo.Pg.StateStored` и
`use Core.Es.Aggregate.Repo.Pg` — у модуля `errors:` нет `domain/3` или clause обязательного кода.

Раскладка каталога в приложении — путь, `ns/0`, `domain/4`, тексты по умолчанию —
`deps/core/docs/rules/app/12-errors.md`, «Каталоги агрегатов».

## Источники `%Error{}` в проекте

- Доменные примитивы (`Prim`) и агрегаты — основной источник `%Error{kind: :domain}` (см.
  `11-domain.md`); агрегаты — через `<Aggregate>.Errors`.
- Репозитории (`Repo.Pg`): `not_found` / `version_mismatch` / … →
  `errors_mod.domain(behaviour, code, detail)`; незамапленный constraint и провал `changeset/2` →
  `%Error{kind: :app}` (`ns: :repo`, `code: :write_failed`) — см. `13-repos.md`.
- Хранилище событий (`Core.Es.Store.append`): отказ записи → `version_mismatch` →
  `errors_mod.domain(behaviour, :version_mismatch, %{aggregate_id, expected, actual, source:})`;
  код и `behaviour` задаёт write-репозиторий (`Repo.Pg.StateStored`, `Es.Aggregate.Repo.Pg`), а не
  хранилище — см. `13-repos.md`. У `get` / `get_decision` / `refresh` event-sourced
  репозитория, когда `%Version{}` не равна голове потока, detail той же формы, у `get_many` — их
  список. `source:` — источник отказа (`:storage` у хранилища, `:expected` у сверки): по нему
  решается повтор команды, и вкладывать в `detail` свой ключ с этим именем MUST NOT.
- Резерв ключа (`append` репозитория с `key_reservations:`): ключ, занятый другим агрегатом, →
  `errors_mod.domain(behaviour, code, %{scope: scope})`, код — `code:` модуля ключа, значения
  ключа в detail нет — см. `13-repos.md`, «Резервы ключей». Отказ вставки, который не снял повтор,
  → `%Error{kind: :app}` (`ns: :es`, `code: :reservation_unresolved`) — это аномалия состязания, а
  не занятый ключ, и клиенту её показывать нечем.
- Пачка проекции (`Core.Es.Projection.run_once/2`): `{:error, _}` колбэка и ошибка загрузки
  события — как есть; исключение `project/1` / `clear/0` → `%Error{kind: :app}` (`ns: :es`,
  `code: :projection_raised`) с модулем исключения в detail и без текста; CAS чекпоинта мимо
  прочитанной строки → `:checkpoint_conflict` — перечень исходов в moduledoc `Core.Es.Projection`.
- Ожидание проекции (`Projection.await/3`): чекпоинт не догнал последнее событие потока
  за таймаут → `%Error{kind: :app}` (`ns: :es`, `code: :projection_timeout`) с `projection` и
  `timeout` в detail; идёт пересборка → `:projection_rebuilding` сразу, без ожидания. Запись к
  этому моменту закоммичена — `22-projections.md`, «Read-after-write».
- Outbox / инфраструктура — часто `%Error{kind: :app}` (см. `14-events-outbox.md`).

### `ns`, которые ставит библиотека

Коды репозиториев (`:not_found`, `:version_mismatch`, …) строит каталог `errors:` приложения —
у них `ns` каталога. Остальные ошибки библиотека собирает сама:

| Модуль-источник | `ns` | Kind | Коды |
|---|---|---|---|
| `Core.Prim` и обёртки `Core.Prim.*` | `:prim` | `:domain` | код шага валидации |
| `Core.Enum` | `:enum` | `:domain` | `:invalid_value` |
| `Core.Context` | `:context` | `:domain` | `:not_found` |
| `Core.DurationParser` | `:duration_parser` | `:domain` | `:invalid_format`, `:precision_loss`, `:unsupported_component`, `:invalid_component`, `:invalid_input`, `:negative_duration` |
| `Core.Web.Params` | `:web` | `:domain` | `:missing_param`, `:current_not_allowed` |
| `Core.Mq.Message` | `:mq` | `:domain` | `:header_not_found`, `:invalid_header_value` |
| `Core.Mq.Stream.Codec` | `:mq` | `:app` | `:encode_failed`, `:invalid_payload`, `:invalid_body`, `:invalid_topic`, `:invalid_key`, `:invalid_headers` |
| `Core.Mq.Stream.Reader` | `:mq` | `:app` | `:not_reliable`, `:nothing_to_commit`, `:commit_failed` |
| `Core.Mq.Stream.Writer` | `:mq` | `:app` | `:publish_unconfirmed`, `:producer_setup_failed` |
| `Core.Mq.Kafka.Writer` | `:mq` | `:app` | `:kafka_publish_failed` |
| `Core.PubSub.MqSubscriberReliable` | `:pubsub` | `:app` | `:already_subscribed`, `:reader_unavailable`, `:dlq_publish_failed`, `:handler_crashed`, `:unexpected_handler_result` |
| `Core.Outbox.Poller`, `Core.Outbox.Cleaner` | `:outbox` | `:app` | `:cycle_failed`, `:cycle_exit` |
| `Core.Outbox.Delivery.Mq` | `:outbox` | `:app` | `:encode_payload_failed` |
| `Core.Security.Secret` | `:secret` | `:app` | `:encrypt_failed`, `:decrypt_failed` |
| `Core.Repo.Pg` | `:repo` | `:app` | `:write_failed` |
| `Core.Es.Event.Codec` (модуль ошибки — кодек агрегата) | `:es` | `:domain` | `:invalid_envelope`, `:unknown_event_type` |
| `Core.Es.Events` | `:events` | `:domain` | `:not_found` |
| `Core.Es.KeyReservation` | `:es` | `:app` | `:reservation_unresolved` |
| `Core.Es.Projection` (`Batch`, `Checkpoint`, `Await`) | `:es` | `:app` | `:projection_raised`, `:checkpoint_conflict`, `:projection_timeout`, `:projection_rebuilding` |

## Связанные правила

- Домен, `Prim` и агрегаты — `11-domain.md`
- Репозитории — `13-repos.md`
- События и outbox — `14-events-outbox.md`
- Граница HTTP (`ErrorMapper`) — `10-architecture.md`
- Логирование — `20-agreements.md`
