# Архитектура библиотеки

- **Область.** Границы библиотеки целиком: `Core.Config`, резолв зависимостей в макросах, адаптеры
  брокеров, `Core.Web.*`, `mix.exs`.
- **Читать перед.** Правкой конфигурации и её резолва, добавлением адаптера брокера или
  `optional`-зависимости, правкой границы HTTP; любой ссылкой из `lib/` на приложение-потребителя.
- **Словарь.** Плейсхолдеры и модальность — `00-index.md`.

## Что это

`:core` — библиотека, подключаемая git-зависимостью к нескольким разным приложениям.
Она даёт фундамент (`Prim`, `Codec`, `Repo`, `Es`, `Outbox`, `Mq`, `PubSub`, `Helper`,
`Web`, PromEx-плагины) в пространстве `Core.*`; домен, роутер с эндпоинтом и композиционный
корень остаются у потребителя. Раскладка `MyApp.*` — `deps/core/docs/rules/app/10-architecture.md`,
«Top-level namespaces».

## Главный инвариант: библиотека не знает потребителя

`Core` MUST NOT содержать ссылок на конкретное приложение: ни на его модули, ни на его
имя OTP-приложения, ни на его конфигурационные ключи. Всё, что нужно от хоста, приходит
одним из пяти путей:

| Что | Как получает зависимость |
|---|---|
| Инфра-синглтоны (`dao`, `codec`, `tz`, ключ шифрования, реализация `Outbox.Repo`) | `Core.Config` — `config :core, ...` |
| Реализации репозиториев (доменных и `Outbox.Repo`) | конвенция `<Behaviour>.Pg`; ключ конфигурации — только при подмене |
| OTP-процессы (`Outbox.Poller`, `Outbox.Cleaner`, `Mq.Stream.*`, `PubSub.MqSubscriberReliable`) | `opts` от supervisor'а потребителя |
| Макросы (`Repo.Pg`, `Repo.Pg.Schema`, `Repo.Pg.StateStored`, `Es.Aggregate.Repo.Pg`, `Es.Outbox`, `Es.Projection`, `Prim.DateTime`, `Prim.Date`) | `use`-опция (`repo:`, `codec:`, `tz:`), без неё — `Core.Config` в рантайме |
| PromEx-плагины | списки процессов / размеров — MFA-провайдер в `opts` плагина |

**Контроль — линтер, а не компилятор** (boundary здесь бесполезен: приложение одно).
`scripts/boundary_lint.exs` (цель `make boundary-check`, первый шаг цепочки) разбирает
AST `lib/**/*.ex` и проверяет три правила:

| # | Правило | Почему |
|---|---|---|
| 1 | `Mix.Project` в `lib/` MUST NOT встречаться | сборочный контекст принадлежит потребителю |
| 2 | `Application.{get_env,fetch_env,fetch_env!,compile_env,compile_env!}` с **литеральным** именем приложения MUST называть только `:core` или `:argon2_elixir` | чужое имя в библиотеке не зашивается |
| 3 | `Core.Config.otp_app/0` MUST NOT вызываться вне `lib/core/config.ex` | имя потребителя приходит переменной, и правило 2 его не видит: единственный источник — `otp_app/0`, и звать его вправе только `Core.Config` |

Разбор идёт по AST, а не грепом: `Application.compile_env!` внутри `@moduledoc` — строковый
литерал, а не обращение. Чтение app-env по имени в **переменной** правилом 2 не ограничено
(`Mq.Stream.Credentials.from_env/2`): имя даёт вызывающий, библиотека его не знает.

Доступ к app-env потребителя целиком живёт в `Core.Config` (`repo!/1`) — правило 3 и есть
машинная форма этого инварианта.

## Компиляция не имеет права требовать конфиг потребителя

Библиотека собирается как зависимость — раньше, чем загружается конфигурация приложения,
и всегда раньше `runtime.exs`. Поэтому:

- значения `Core.Config` резолвятся **в рантайме**, а не модульными атрибутами;
- макрос, которому нужен фасад или `Ecto.Repo`, при отсутствии явной опции подставляет
  **вызов** (`Core.Config.codec()` / `Core.Config.dao()`), а не запечённый модуль: резолв
  делает `Core.Helper.Opts.module_or_config!/4` (`Repo.Pg.Schema`, `Repo.Pg.StateStored`,
  `Es.Aggregate.Repo.Pg`, `Es.Outbox`, `Es.Projection`); `Repo.Pg` хранит `repo:` как есть и
  берёт DAO на каждом вызове — `Core.Repo.Pg.dao/1`;
- реализация outbox-репозитория — вызов `Core.Config.outbox_repo()` в момент записи
  (`Repo.Pg.StateStored`, `Es.Aggregate.Repo.Pg`), а не опция макроса;
- `tz` у `Prim.DateTime` / `Prim.Date` без опции `tz:` — вызов `Core.Config.tz()` в теле
  функции (`now/0`, `today/0`);
- имена telemetry-событий строятся вызовом `Core.Telemetry.event/1`, а не атрибутом:
  префикс задаёт потребитель (`config :core, telemetry_prefix: [...]`).

Нарушение выглядит одинаково: `mix deps.compile core` падает с
`Core.Config: не задан config :core, ...` у любого потребителя.

Проверяется: `test/core/macro_config_test.exs` — компилирует макросы репозиториев, `Es.Outbox`
и `Es.Projection` со снятыми ключами `:core`.

## Контракт конфигурации

```elixir
config :core,
  otp_app: :my_app,          # обязателен: app-env с DI-ключами потребителя; читается на компиляции call site
  dao: MyApp.DAO,            # обязателен
  codec: MyApp.Codec.Internal, # обязателен
  tz: "Etc/UTC",             # опционален, дефолт "Etc/UTC"
  telemetry_prefix: [:my_app]  # опционален, дефолт [otp_app()]; префикс имён telemetry-событий

config :core, Core.Outbox, poller_name: MyApp.Outbox.Poller
config :core, Core.Security.Secret, secret_key: "<base64 fernet key>"
```

Реализации репозиториев в контракт не входят: `Core.Config.repo!/1` и
`Core.Config.outbox_repo/0` выводят их из имени behaviour по конвенции `<Behaviour>.Pg`,
и ключ нужен только при подмене (`13-repos.md`, «DI»; ADR-0006).

Полное описание, включая обязанности потребителя, — в `README.md`.
`Core.Config.validate!/0` проверяет контракт на старте приложения.

## Адаптеры и абстракции

Адаптеры брокеров (`Mq.Writer` / `Mq.ReaderReliable`: `Mq.Stream.*`, `Mq.Kafka.Writer`)
живут в библиотеке — конкретный клиент/коннекшн приходит им аргументом или через `opts`.

Клиентские библиотеки объявлены `optional: true`, а модули, которым нужен клиент
на этапе компиляции (`use RabbitMQStream.Connection`, структуры `%OsirisChunk{}`,
`%Klife.Record{}`), обёрнуты в `if Code.ensure_loaded?/1`. Потребитель платит только
за тот брокер, который использует. Правила при добавлении нового адаптера:

- всё, что не требует клиента на этапе компиляции, MUST оставаться вне условия
  (`Mq.Stream.Writer` работает с любым connection-модулем и компилируется всегда);
- ссылки на условные модули из безусловных (`Mq.PromEx` → `Mq.Stream.Reader`)
  MUST попадать в `elixirc_options: [no_warn_undefined: [...]]` в `mix.exs`;
- новый брокер подключается реализацией behaviour `Mq.Writer` / `Mq.ReaderReliable` —
  как в библиотеке, так и на стороне потребителя;
- у адаптера MUST быть `ensure_available!/0` на модуле брокера, делегирующая общей проверке
  `Core.Mq.Client.ensure_available!/1` строкой опций, а не копией `cond` (образцы —
  `Core.Mq.Stream`, `Core.Mq.Kafka`): отличает «клиента нет в deps» от «клиент есть, но `core`
  собран без него»;
- инвариант «библиотека собирается без клиентов» держится на сборке без них: собственные
  тесты библиотеки его не ловят, в них оба клиента есть всегда. Тот же приём —
  у `ecto_sql` (`if Code.ensure_loaded?(Postgrex) do` вокруг `Ecto.Adapters.Postgres.Connection`).

Проверяется: `make compile-no-optional` (`mix compile --no-optional-deps
--warnings-as-errors`, часть `make`).

### Wire-формат принадлежит адаптеру

`Mq.Message` — внутренняя модель, а не контракт провода: `Mq.Writer` / `Mq.ReaderReliable`
задают порядок публикации и обработку ошибок, но не то, во что сообщение превращается
на проводе.

- представление MAY различаться между адаптерами (`Mq.Stream.Codec` — JSON с base64-телом,
  `Mq.Kafka.Writer` — нативно);
- адаптер MUST документировать своё представление в `@moduledoc` и держать кодек в
  собственном пространстве имён (`Mq.Stream.Codec`, а не `Mq.Codec`): общее имя врёт о том,
  что формат один на всех;
- продюсер и потребитель одного топика MUST использовать один адаптер;
- адаптер MUST отбрасывать то, чью позицию в потоке он не может назвать, а не отдавать
  наверх с догадкой (чанк с sub-entry batching в `Mq.Stream.Reader` — `error` и
  `decode_drop` на весь чанк);
- unified wire-формат между брокерами — отдельная задача с dual-read на переходный период,
  а не побочный эффект правки адаптера.

Почему формат не унифицирован и чем платим — ADR-0004.

Сконфигурированные клиенты с compile-time привязкой к OTP-приложению
(например, Kafka `use Klife.Client, otp_app: :my_app`), их supervision, runtime-тумблеры
и реестры доменных процессов остаются в app-слое потребителя.

## Граница HTTP

`Core.Web.*` — то, что на границе HTTP одинаково у всех потребителей и **не** зависит
ни от Phoenix, ни от OpenApiSpex:

| Модуль | Роль |
|---|---|
| `Core.Web.Params` | параметры запроса → значения (`find` / `get` / `get!`), `page/2`, `If-Match` → `Version`: `explicit_version/2` (только явная), `expected_version/2` (`*` → `:current`), `optional_version/2` (нет заголовка → `:current`) |
| `Core.Web.Response` + `Core.Web.Response.Code` | конверт `%{code, messages[, data]}` и его числовые коды; `use Core.Web.Response, codes:` — конверт на своём словаре |
| `Core.Web.ErrorMapper` | `%Error{}` → `{статус, код конверта, текст, уровень лога}` |
| `Core.Web.MetricsPlug` | standalone-сервер метрик поверх `PromEx.Plug` |
| `Core.Helper.Keys` | camelCase ↔ snake_case ключей (`camelize/1` / `snakify/1` — рекурсивно; `camelize_key/1` / `snakify_key/1` — один ключ) |

`Core.Web.*` возвращает **данные**: map конверта и кортеж ответа. Ни `Plug.Conn`, ни
`Phoenix.Controller` в них не участвуют (исключение — `MetricsPlug`, он и есть плаг).

Что остаётся у потребителя (роутер, эндпоинт, контроллеры, `FallbackController`, схемы, плаги,
презентеры) — `deps/core/docs/rules/app/15-web-api.md`.

`Core.Web.ErrorMapper.map/2` — чистая функция: `{статус, код конверта, текст, уровень лога}`.
`Logger` зовёт потребитель по возвращённому уровню (`nil` — не логировать): так таблица остаётся
запросом и проверяется тестом построчно.

| Ошибка | Статус | Код | Текст | Лог |
|---|---|---|---|---|
| `%Error{kind: :domain, code: :version_mismatch}` | 412 | `:diff_version` | `message` | — |
| `%Error{kind: :domain, code: :access_denied}` | 403 | `:error` | `message` | — |
| `%Error{code: c}` любого `kind`, `c` в `auth_codes:` | 401 | `:auth_error` | константа | `:debug` |
| `%Error{kind: :domain}` | 400 | `:domain_error` | `message` | — |
| `%Error{kind: :app}` с любым `code` | 500 | `:critical` | шаблон | `:error` |
| прочее (не `%Error{}`) | 500 | `:critical` | шаблон | `:error` |

- Статус по `code:` разбирается только у `kind: :domain`: прикладную ошибку клиенту показывать
  нельзя, и она обязана попасть в лог (`12-errors.md`).
- Доменный `:not_found` — 400 `:domain_error` по строке `kind: :domain`; своя строка 404 в
  `Core.Web.ErrorMapper.map/2` MUST NOT. `:not_found` домен отдаёт и на ресурс из URI, и на запись,
  на которую ссылается тело команды, а по `%Error{}` маппер их не различит: 404 на существующий
  ресурс клиент прочтёт как «ресурса нет». Отказу домена на команде с `If-Match` 404 не нужен —
  по RFC 9110 §13.2.1 ответу достаточно не быть ни 2xx, ни 412. Приложение, чей домен разводит
  коды «ресурс не найден» и «ссылка не найдена», MAY отдать 404 своей клозой `map/1` перед
  делегированием.
- На 401 наружу MUST уходить константный текст независимо от причины: разные тексты позволяют
  перебирать учётки, сессии и токены. Причина — только в лог (`Error.format_chain/1`).
- Опции: `auth_codes:` (дефолт `~w(unauthorized auth_failed invalid_token session_not_found)a`),
  `unauthorized_message:`, `critical_message:`.
- Своя строка таблицы — клоза `map/1` маппера приложения. Свои клозы MUST объявляться **перед**
  делегированием в `Core.Web.ErrorMapper.map/2`: `map/2` не макрос и не behaviour, и порядок
  клоз — это приоритет строк.

Проверяется: `test/core/web/error_mapper_test.exs` — таблица построчно, `:not_found` → 400 отдельным
тестом.

Расширение под потребителя — тремя независимыми шагами, каждый нужен только по надобности:

| Нужно | Как |
|---|---|
| свой статус/код для конкретной ошибки | свои клозы `map/1` перед делегированием в `Core.Web.ErrorMapper.map/2` |
| больше кодов конверта | свой `Core.Enum` поверх базового: `codes: Map.merge(Core.Web.Response.Code.codes(), %{...})` |
| отдать эти коды в конверт | `use Core.Web.Response, codes: MyAppWeb.Response.Code` |

Словарь потребителя MUST покрывать `Core.Web.Response.Code.values/0` — эти значения
возвращает `ErrorMapper.map/2`.

Проверяется: компиляция — билдер `Core.Web.Response`.

## Связанные правила

- Домен, `Prim`, `Codec` — `11-domain.md`
- Ошибки — `12-errors.md`
- Репозитории — `13-repos.md`
- События и outbox — `14-events-outbox.md`
- OTP — `17-otp-concurrency.md`
- Тесты — `19-testing.md`
- Соглашения по коду — `20-agreements.md`
- Метрики, трейсы, логи — `21-observability.md`
