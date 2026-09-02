# Архитектура библиотеки

Плейсхолдеры: `MyApp` — корневой namespace приложения-потребителя; `:my_app` — его OTP app atom;
`<BC>` — bounded context; `<Actor>` — actor/role-срез; `<Aggregate>` — агрегат.

## Что это

`:core` — библиотека, подключаемая git-зависимостью к нескольким разным приложениям.
Она даёт фундамент (`Prim`, `Codec`, `Repo`, `Es`, `Outbox`, `Mq`, `PubSub`, `Helper`,
PromEx-плагины); домен, web-слой и композиционный корень остаются у потребителя.

| Namespace | Где живёт |
|---|---|
| `Core.*` | эта библиотека |
| `MyApp.Codec.*` | потребитель: Prim-профили и entity-фасады поверх `Core.Codec` |
| `MyApp.Domain.<BC>.*` | потребитель: агрегаты, репозитории, usecases |
| `MyApp.DAO` | потребитель: единственный `Ecto.Repo` |
| `MyApp.Application` | потребитель: композиционный корень, поднимает процессы Core |

## Главный инвариант: библиотека не знает потребителя

`Core` MUST NOT содержать ссылок на конкретное приложение: ни на его модули, ни на его
имя OTP-приложения, ни на его конфигурационные ключи. Всё, что нужно от хоста, приходит
одним из четырёх путей:

| Что | Как получает зависимость |
|---|---|
| Инфра-синглтоны (`dao`, `codec`, `tz`, ключ шифрования, реализация `Outbox.Repo`) | `Core.Config` — `config :core, ...` |
| OTP-процессы (`Outbox.Poller`, `Outbox.Cleaner`, `Mq.Stream.*`, `PubSub.MqSubscriberReliable`) | `opts` от supervisor'а потребителя |
| Макросы (`Repo.Pg`, `Repo.Pg.Schema`, `Prim.DateTime`, `Codec.Facade`) | `use`-опция, fallback → `Core.Config` |
| PromEx-плагины | списки процессов / размеров — MFA-провайдер в `opts` плагина |

**Контроль — греп, а не компилятор** (boundary здесь бесполезен: приложение одно):

```bash
rg 'Mix\.Project' lib                                       # пусто
rg 'Application\.(get_env|fetch_env!?|compile_env!?)' lib    # только :core и :argon2_elixir
```

Единственное исключение из «только `:core`» — `Core.Repo.Pg.Es`: он резолвит
`event_repo:` через `Application.compile_env!(Core.Config.otp_app(), <behaviour>)`,
то есть в app-env потребителя. DI доменных репозиториев — контракт хоста, и жить он
обязан под его именем. Исключение задокументировано в moduledoc `Repo.Pg.Es` и README;
расширять список — только с такой же аргументацией.

## Компиляция не имеет права требовать конфиг потребителя

Библиотека собирается как зависимость — раньше, чем загружается конфигурация приложения,
и всегда раньше `runtime.exs`. Поэтому:

- значения `Core.Config` резолвятся **в рантайме**, а не модульными атрибутами;
- макрос, которому нужен фасад или репозиторий, при отсутствии явной опции подставляет
  **вызов** (`Core.Config.codec()`), а не запечённый модуль
  (см. `codec!/1` в `Core.Repo.Pg.Schema`);
- имена telemetry-событий строятся вызовом `Core.Telemetry.event/1`, а не атрибутом:
  префикс задаёт потребитель (`config :core, telemetry_prefix: [...]`).

Нарушение выглядит одинаково: `mix deps.compile core` падает с
`Core.Config: не задан config :core, ...` у любого потребителя.

## Контракт конфигурации

```elixir
config :core,
  otp_app: :my_app,          # обязателен: app-env с DI-ключами потребителя
  dao: MyApp.DAO,            # обязателен
  codec: MyApp.Codec.Internal, # обязателен
  tz: "Etc/UTC",             # опционален, дефолт "Etc/UTC"
  telemetry_prefix: [:my_app]  # опционален, дефолт [otp_app()]

config :core, Core.Outbox.Repo, Core.Outbox.Repo.Pg
config :core, Core.Outbox, poller_name: MyApp.Outbox.Poller
config :core, Core.Security.Secret, secret_key: "<base64 fernet key>"
```

Полное описание, включая обязанности потребителя, — в `README.md`.
`Core.Config.validate!/0` проверяет контракт на старте приложения.

## Адаптеры и абстракции

Адаптеры брокеров (`Mq.Writer` / `Mq.Reader`: `Mq.Stream.*`, `Mq.Kafka.Writer`) живут
в библиотеке — конкретный клиент/коннекшн приходит им аргументом или через `opts`.
Сконфигурированные клиенты с compile-time привязкой к OTP-приложению
(например, Kafka `use Klife.Client, otp_app: :my_app`), их supervision, runtime-тумблеры
и реестры доменных процессов остаются в app-слое потребителя.

## Ссылки

- Домен, `Prim`, `Codec` — `11-domain.md`
- Ошибки — `12-errors.md`
- Репозитории — `13-repos.md`
- События и outbox — `14-events-outbox.md`
- OTP — `17-otp-concurrency.md`
- Тесты — `19-testing.md`
- Соглашения по коду — `20-agreements.md`
