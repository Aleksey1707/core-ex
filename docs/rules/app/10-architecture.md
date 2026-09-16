# Архитектура приложения

- **Область.** `lib/my_app/**`, `lib/my_app_web/**`, `config/**`: namespaces, boundary,
  actor-срезы, usecases, DI, композиционный корень, конфигурация библиотеки.
- **Читать перед.** Новым BC, актором или usecase; переносом модулей между слоями; правкой
  DI, дерева `boundary` и конфигурации `:core`.
- **Словарь.** Плейсхолдеры и модальность — `deps/core/docs/rules/00-index.md`.

Границы самой библиотеки, контракт `Core.Config`, адаптеры брокеров и состав `Core.Web.*`
нормирует `deps/core/docs/rules/10-architecture.md`. Здесь — то, что обязано быть сделано
**на стороне приложения**.

## Top-level namespaces

| Namespace | Path | Назначение |
|---|---|---|
| `Core` | зависимость `:core` | shared-фундамент: `Prim`, `Enum`, `Codec`, `View`, `Context`, `Error`, `Es`, `Repo`, `Outbox`, `Mq`, `PubSub`, `Web`, `Helper` |
| `MyApp.Codec` | `lib/my_app/codec/` | Prim-профили `Prim.{Internal,External}`, entity-фасады `{Internal,External}`, реестр плагинов |
| `MyApp.Domain.<BC>` | `lib/my_app/domain/<bc>/` | bounded context: `common` + actor-срезы |
| `MyApp.Outbox` | `lib/my_app/outbox/` | OTP-дерево очереди: writer + поллер + cleaner |
| `MyApp.PromEx` | `lib/my_app/prom_ex*` | плагины метрик и MFA-провайдеры списков |
| `MyApp.ContextFactory` | `lib/my_app/context_factory.ex` | сборка `%Context{}` вне web |
| `MyApp.DAO` | `lib/my_app/dao.ex` | единственный `Ecto.Repo` |
| `MyAppWeb` | `lib/my_app_web/` | HTTP-поверхности, плаги, презентеры |

Модуль верхнего уровня, не попавший в таблицу, — либо подсистема приложения (актуализация,
хранилище, интеграция), либо признак того, что слой выбран неверно.

## Обязательства перед библиотекой

Всё, что библиотека знает о приложении, лежит под её собственным ключом:

```elixir
# config/config.exs — читается на компиляции call site, поэтому не в runtime.exs
config :core,
  otp_app: :my_app,
  dao: MyApp.DAO,
  codec: MyApp.Codec.Internal,
  tz: "Etc/UTC",
  telemetry_prefix: [:my_app]
```

- `MyApp.DAO` MUST объявляться через `use Core.DAO`, а не `use Ecto.Repo`: иначе after-commit
  хуки (wake поллера outbox, эталон `Repo.Sc`) молча не выполняются, и ошибка проявится
  отложенной доставкой и перезаписью дочерних строк, а не падением.
- `Core.Outbox.Codec` MUST входить в реестр плагинов фасада (`11-domain.md`).
- `otp_app` MUST лежать в `config.exs`: его читает `Core.Config.repo!/1` на компиляции каждого
  call site, и в `runtime.exs` он опоздает.
- `telemetry_prefix` MUST задаваться явно, даже когда совпадает с дефолтом `[otp_app()]`:
  имена метрик зашиты в дашборды и алерты и обязаны пережить смену `otp_app`
  (`21-observability.md`).
- Клиент брокера MUST быть объявлен в `deps` приложения: в библиотеке он `optional: true`, и
  без записи в `deps` адаптеров `Core.Mq.*` просто нет. После добавления или удаления клиента —
  `mix deps.compile core --force`, иначе адаптер останется в том состоянии, в каком его собрали.
- Ключи под `:my_app` — только подмена конвенции `<Behaviour>.Pg` (`13-repos.md`) и настройки
  подсистем самого приложения.

Старт MUST проверять конфигурацию до подъёма дерева — неверная конфигурация роняет старт, а не
всплывает на первом запросе (`17-otp-concurrency.md`):

```elixir
Core.Config.validate!()
Core.Security.Secret.ensure_configured!()
Core.Mq.Stream.ensure_available!()
```

## Boundary

| Boundary | `deps:` | Что внутри |
|---|---|---|
| `MyApp` | `[]` | app-слой + `Domain.*` + `Codec.*` |
| `MyAppWeb` | `[MyApp]` | web-слой |
| `MyApp.Application` | `[MyApp, MyAppWeb]` | композиционный корень (`top_level?: true`) |
| `MyApp.PromEx` | `[MyApp, MyAppWeb]` | обвязка наблюдаемости (`top_level?: true`) |

- `Core.*` в `deps:` MUST NOT перечисляться: `boundary` размечает модули этого приложения, а
  чужое OTP-приложение его проверками не покрыто.
- `Application` и `PromEx` выносятся в отдельные top-level boundary: только они сводят app-слой
  и web вместе (старт `Endpoint`, PromEx-плагин Phoenix с `endpoint:` / `router:`). Остальному
  app-слою ссылаться на `MyAppWeb` MUST NOT.
- Mix-таски лежат вне дерева `MyApp.*` — им нужен явный `use Boundary, classify_to: MyApp`.

Мельче резать не требуется: `Domain` и `Codec` развести нельзя — фасад знает плагины, плагины
зовут фасад, и это настоящий compile-time цикл, а `boundary` циклы запрещает. Проверяемая часть
инварианта MUST выноситься в архитектурный тест: web-слой не ссылается на `*Repo` и `DAO`.
Исключение — `Core.Repo.Sc`: это shadow copy контекста, а не репозиторий.

Проверяется: `mix compile --warnings-as-errors`, архитектурный тест (`19-testing.md`).

## Actor / role slices

Bounded context делится на `common` и actor-срезы. Это **actor-based** структура, а не
отдельные доменные модели.

| Часть | Что держит |
|---|---|
| `<BC>.Common` | агрегаты, Prim, события, кодеки событий, outbox-маппинг, репозитории и схемы |
| `<BC>.<Actor>` | usecases под свою роль; при надобности actor-domain и actor-specific Repo |

- Actor в предметном BC MAY не совпадать с типом учётной записи: это роль в контексте.
- Срез, который зовут не из web, а из воркеров, подписчиков и mix-тасок, MUST получать актора
  от `ContextFactory` (`11-domain.md`), а не собирать контекст на месте.
- Actor-специфичный репозиторий заводится там, где у среза **свой ACL-фильтр**; в остальных
  случаях срезы читают и пишут общий репозиторий из `Common` (`13-repos.md`).

## Usecases

Имя — `MyApp.Domain.<BC>.<Actor>.Usecases.<Aggregate>`. Конвенция тела:

1. Authz — до открытия транзакции.
2. Актор: `CurrentUser.get(context)` → `by` — там же, до транзакции.
3. Load → мутация домена → persist — внутри `Transact.run`.
4. Последний аргумент публичных функций — `%Context{}` (`deps/core/docs/rules/20-agreements.md`).

Authz и резолв актора MUST идти до открытия транзакции: проверка прав ходит в read-путь, а тот
в dev и prod MAY быть закеширован, и внепроцессный сайд-эффект внутри транзакции запрещён.
Транзакционности с самой командой проверка доступа не требует — отказ по правам это отказ до
начала работы.

Возвраты по CQS (`deps/core/docs/rules/20-agreements.md`):

| Вид | Возврат |
|---|---|
| Команда | `:ok \| {:error, Error.t()}` |
| Команда-создание | MAY `{:ok, <Aggregate>.ID.t()}` — идентификатор генерирует домен |
| Команда event-sourced агрегата | `{:ok, Version.t()}`; создание — `{:ok, {<Aggregate>.ID.t(), Version.t()}}` |
| Запрос | `{:ok, <Aggregate>.View.t()} \| {:error, Error.t()}` — read-путь отдаёт представление |

Возврат id из команды-создания — единственное допустимое отступление от CQS: без него
вызывающий вынужден искать созданный агрегат отдельным запросом. Версия после записи
отступлением не считается — это результат собственного выполнения команды, по ней граница
ждёт проекцию (`15-web-api.md`). Прочие данные агрегата команда не возвращает.

Репозиторий резолвится **только** через `Core.Config.repo!/1`; прямой
`Application.compile_env!/2` на доменный behaviour — MUST NOT (`13-repos.md`).

У команды **event-sourced** агрегата то же тело, но другой состав шагов: `get` → `Agg.execute/2`
→ `append` под одной транзакцией, либо `<Aggregate>.Process.execute` вместо неё. Отличия, которые
видит usecase (`13-repos.md`, «Event-sourced агрегат»):

- существование агрегата решает `decide` по `version: nil`, а не `:not_found` репозитория;
- запись по `:current` повторяется после `:version_mismatch`, по явной `%Version{}` — нет;
- команду собирает usecase (`<Aggregate>.Cmd.<Name>` с `by` и `at` — `11-domain.md`);
- ответ клиенту, которому нужна свежая read-модель, ждёт проекцию — **после** commit, вне
  транзакции (`15-web-api.md`).

```elixir
def command(%Agg.ID{} = id, %Version{} = version, %Context{} = context) do
  with :ok <- check_user(~w(update)a, context),
       {:ok, by} <- CurrentUser.get(context) do
    Transact.run(DAO, fn ->
      with {:ok, agg} <- @repo.get(id, version, context),
           {:ok, agg} <- Actor.Agg.mutate(agg, by),
           {:ok, _saved} <- @repo.save(agg, context) do
        :ok
      end
    end)
  end
end
```

### Что можно внутри `Transact.run`

Транзакция удерживает соединение из пула и блокировки строк на всё время работы колбэка.

| Внутри `Transact.run` | Статус |
|---|---|
| запросы через `DAO` (repo и его flush событий и outbox) | MAY |
| enqueue фоновой задачи в той же транзакции | MAY — задача появится только при успешном commit |
| HTTP-вызовы, publish в брокер, обращения к объектному хранилищу | MUST NOT |
| кеш и прочие внепроцессные сайд-эффекты | MUST NOT |
| `:timer.sleep`, ожидание внешнего события, ожидание проекции | MUST NOT |
| команда процесса агрегата (`<Aggregate>.Process.execute`) | MUST NOT — она идёт своей транзакцией |

Побочный эффект после успешной записи — `Core.Helper.AfterCommit.register/1` либо отдельным
шагом вызывающего. Каскад с внешним вызовом посередине MUST разбиваться на отдельные
транзакции, а не оборачиваться одной вокруг всего.

Границы, которые ходят по сети, MUST звать `Core.Helper.Transact.warn_in_transaction/1`:
нарушение попадает в лог как `error`, а не всплывает деградацией пула под нагрузкой.

## Слои и зависимости

```mermaid
flowchart TB
  Web["Web: Controller / Presenter"]
  Worker["Воркеры, подписчики, mix-таски"]
  UC["Usecases"]
  Domain["Domain: Aggregate / Actor-domain"]
  Repo["Repo / ReadRepo"]
  Store["Event store / Outbox"]
  DAO["DAO"]

  Web --> UC
  Worker --> UC
  UC --> Domain
  UC --> Repo
  Repo --> Store
  Repo --> DAO
  Store --> DAO
```

- Web вызывает только usecases; domain и repo напрямую — MUST NOT.
- Воркеры, подписчики и mix-таски — такие же вызывающие, как web: оркестрация прогона, но не
  доменные мутации.
- Usecases оркестрируют domain и репозитории; authz живёт здесь.
- Domain не пишет в БД и не знает про Ecto.
- Repo пишет состояние и — при наличии — события с outbox в одной транзакции.
- Command-путь работает с агрегатом на доменных Prim, query-путь — с `<Aggregate>.View`
  из примитивных значений (`13-repos.md`).

## Связанные правила

- Домен, Codec, `ContextFactory` — `11-domain.md`
- Ошибки и их границы — `12-errors.md`
- Репозитории и DI — `13-repos.md`
- События и outbox — `14-events-outbox.md`
- Web API — `15-web-api.md`
- Дерево процессов — `17-otp-concurrency.md`
- Пайплайн проверок — `20-agreements.md`
