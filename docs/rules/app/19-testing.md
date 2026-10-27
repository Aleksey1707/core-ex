# Тесты приложения

- **Область.** `test/**`, включая `test/support/**`, golden-фикстуры событий и ратчеты.
- **Читать перед.** Новым тестом, правкой тестовой обвязки, добавлением ратчета или
  контрактного набора.
- **Словарь.** Плейсхолдеры и модальность — `deps/core/docs/rules/00-index.md`.

Виды тестов, которых требует контракт библиотеки — round-trip кодеков, тесты View, golden-
фикстуры событий, `constraint_errors`, negative-тесты ACL, работа со временем, тесты проекций —
нормирует `deps/core/docs/rules/19-testing.md`. Здесь — обвязка приложения и его ратчеты.

## Case-модули

| Case | Когда |
|---|---|
| `ExUnit.Case` | чистые модули: Prim, Enum, кодеки, агрегаты, презентеры, хелперы |
| `MyAppTest.DataCase` | всё, что ходит в `MyApp.Infra.DAO`: репозитории, usecases, воркеры |
| `MyAppTest.ConnCase` | контроллеры и плаги |
| `Core.Es.EventCompatCase` | golden-фикстуры событий агрегата |
| `Core.Es.ProjectionCase` | очистка `clear/0` проекции |
| `Core.Labels.CompletenessCase` | полнота подписей, если приложение отдаёт сведения событий |

- `async:`, причины `async: false` и уборка после них, тест репозитория через behaviour —
  `deps/core/docs/rules/19-testing.md`, «Case-модули».
- Собственный case-модуль совместимости событий MUST NOT: библиотечный уже держит все инварианты
  (`deps/core/docs/rules/14-events-outbox.md`, «Совместимость событий»), а копия расходится с
  форматом конверта.
- `MyAppTest.DataCase` MUST поднимать sandbox через
  `Ecto.Adapters.SQL.Sandbox.start_owner!(MyApp.Infra.DAO, shared: not tags[:async])` и
  останавливать владельца в `on_exit`: на shared mode при `async: false` держатся прогон проекции
  и процесс, стартующий внутри вызова (`deps/core/docs/rules/19-testing.md`, «Процессы»).

```elixir
# плохо — checkout без shared mode: процесс, стартующий внутри вызова, соединения не получит
setup tags do
  :ok = Ecto.Adapters.SQL.Sandbox.checkout(MyApp.Infra.DAO)
end

# хорошо — test/support/data_case.ex
setup tags do
  pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MyApp.Infra.DAO, shared: not tags[:async])
  on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  :ok
end
```

## Раскладка `test/`

- Тест модуля SHOULD лежать по пути модуля: `MyApp.Domain.<BC>.<Aggregate>` —
  `test/my_app/domain/<bc>/<aggregate>_test.exs`. Тест находится по имени модуля так же, как
  сам модуль (`10-architecture.md`, «Раскладка»).
- Тест, который держит норму на всём дереве, — ратчет («Ратчеты») — MUST лежать в `test/my_app/`:
  модуля, по пути которого его положить, у него нет. Исключение — ратчет, чей тест-модуль назван в
  namespace web (`MyAppWeb.IfMatchSpecTest`, сверка спецификаций поверхностей): он лежит в
  `test/my_app_web/`, путь следует за именем модуля.
- Архитектурного теста на направления зависимостей нет: «web не ссылается на `*Repo` и `DAO`» и
  ссылки мимо `exports` контекста ловит сборка (`10-architecture.md`, «Boundary»).
- Case-модули (`MyAppTest.DataCase`, `MyAppTest.ConnCase`) и прочая обвязка MUST лежать в
  `test/support/` в границе `MyAppTest` («Case-модули», «Обвязка `test/support`»): это не тесты,
  а код, который компилируется в `:test`.

```text
test/my_app/domain/<bc>/<aggregate>_test.exs          # тест модуля — по его пути
test/my_app/enum_docs_test.exs                        # ратчет — норма на всём дереве
test/support/{data_case,conn_case}.ex                 # обвязка
```

## Обвязка `test/support`

| Модуль | Роль |
|---|---|
| `*_fixture.ex` | доменные фабрики агрегатов |
| `*_seed.ex` | наполнение БД связанными агрегатами под тест |
| `*_contract.ex` | общие наборы тестов behaviour (`deps/core/docs/rules/19-testing.md`, «Контрактные тесты behaviour») |
| дублёры внешних систем | канал, брокер, каталог пользователей без сети |
| `mocks.ex` | мок порта проверки доступа `MyAppTest.Authz` («Проверка доступа») |
| `test/support/fixtures/events/**` | снимки wire-формата событий |

- Сборка фикстур доменными конструкторами и событиями, а не строками в БД, —
  `deps/core/docs/rules/19-testing.md`, «Case-модули»; объявления Prim для проверки «секрет не
  утекает» — там же, «Чувствительные данные».
- Дублёр внешней системы MUST держать контракт адаптера буквально, включая поведение при
  ошибке. Дублёр, который «всегда `:ok`», прячет ровно тот класс ошибок, ради которого пишется
  тест. Общий контрактный набор behaviour прогоняется и на дублёре, на моке — нет
  (`deps/core/docs/rules/19-testing.md`, «Контрактные тесты behaviour»).

## Проверка доступа

Порт `MyApp.Authz` (`10-architecture.md`, «Проверка доступа») в тестах закрывает мок Mox:
`Mox.defmock(MyAppTest.Authz, for: MyApp.Authz)` в `test/support/mocks.ex`, `config/test.exs`
называет его реализацией порта, `{:mox, "~> 1.2", only: :test}` — в `deps` приложения. Ожидания
Mox принадлежат процессу теста, и тест с моком остаётся `async: true`.

- Тест usecase MUST идти с моком порта, а не с реализацией контекста прав: `Mox.stub/3`
  пропускает проверку, `Mox.expect/4` — сверяет типы учётной записи, ключ и операции. Данные
  готовит только свой контекст: роли, учётные записи и проекции контекста прав тесту предметной
  логики не нужны.
- Если порт реализует контекст прав, каждый модуль декларации MUST иметь интеграционный тест с
  боевой реализацией: `Mox.stub_with(MyAppTest.Authz, MyApp.Domain.<BC>.Authz)`, отказ
  `{:error, %Error{code: :access_denied}}` без выданного права и успех с ним; права выдают usecases
  контекста прав. Только он видит, что `account:` и пространства декларации сходятся с выданными
  правами. Операции модуля — табличным тестом в том же модуле теста: строка на usecase и
  пространство с его операциями, один сетап прав на таблицу. Операции, не объявленной в
  оглавлении, тест не нужен — её ловит сборка
  (`deps/core/docs/adr/0052-authz-test-per-declaration-doubles-under-contract.md`,
  `deps/core/docs/adr/0054-authz-ops-checked-at-compile.md`). `async:` у него
  — по модели прав: ожидание её проекции — `async: false` (`deps/core/docs/rules/19-testing.md`,
  «Case-модули»).
- Контрактный набор behaviour на мок не распространяется — его место занимает интеграционный тест
  модуля декларации (`deps/core/docs/rules/19-testing.md`, «Контрактные тесты behaviour»).
- Декларация `use MyApp.Authz` в тестовом модуле MUST NOT: макрос выводит оглавление из имени
  модуля, и тестовый модуль вне `MyApp.Domain.<BC>.*` не собирается. Usecase тестируется через его
  модуль, порт закрывает мок; тест самого макроса порта заводит фикстуру контекста.
- Тест макроса порта MUST проходить три случая `CompileError` на фикстуре контекста: ключ
  `check_user/3` вне декларации, операция, не объявленная в оглавлении, и операции не литералом —
  с файлом и строкой вызова `check_user`. Сборочную сверку тест usecase не видит: модуль с ошибкой
  до него не собирается.
- Приложение, у которого порт закрывает заглушка `MyApp.Authz.Stub`, MAY не заводить мок: тест
  usecase идёт с заглушкой из `config/test.exs`, интеграционных тестов доступа нет — модели прав
  нет.

```elixir
# плохо — тест логики отмены поднимает модель прав: выдачу роли и прогон её проекции
setup %{user_id: user_id} do
  :ok = MyAppTest.RightsSeed.grant(user_id, :orders, ~w(update)a)
  :ok = Core.Es.Projection.Test.run_until_idle(MyApp.Domain.Rights.Access.Projection)
end

# хорошо — test/my_app/domain/orders/order/client/usecases_test.exs: логика — с моком
setup do
  Mox.stub(MyAppTest.Authz, :check, fn _account, _namespace, _ops, _context -> :ok end)
  :ok
end

# хорошо — там же, describe «доступ»: операция — с боевой реализацией
setup do
  Mox.stub_with(MyAppTest.Authz, MyApp.Domain.Rights.Authz)
  :ok
end
```

## Event sourcing

Тесты решений агрегата, записанных событий, совместимости wire и проекций, тестовое дерево
`enabled: false, await: :inline` — `deps/core/docs/rules/19-testing.md`, «Event-sourced
агрегат», «Совместимость событий» и «Проекции».

Ветку `:accepted` usecase с ожиданием (`:projection_timeout` / `:projection_rebuilding` →
`{:accepted, id, version}`, `10-architecture.md`, «Usecases») приложение MUST проверять тестом
usecase через `Core.Es.Projection.Test.with_rebuilding/2` в `MyAppTest.DataCase, async: false` —
**одним** на модуль usecases, который ждёт проекцию: ветка живёт в его хелпере ожидания, и у
каждого модуля она своя. Ответ 202 на `:accepted` у всех контроллеров один, и его покрывает тест
хелпера `MyAppWeb.Accepted` как чистой функции: `ConnCase` ради ветки не нужен. Механика и запрет
доводить тест до `:projection_timeout` — `deps/core/docs/rules/19-testing.md`, «Ветка неготовой
read-модели».

Тест хелпера MUST проходить три ветки `Prefer` (`15-web-api.md`, «Ожидание проекции»): без заголовка
`wait/1` отдаёт предел хелпера, на `respond-async` — `:none`, на `wait=N` — урезанный таймаут;
`respond/3` и `written/2` отвечают 200 на `:projected` и 202 на `:accepted`, `respond/3` — 204 без
`Preference-Applied` на `:unchanged`, и `Preference-Applied` сверяется в каждой ветке. Разбор самого
заголовка проверяют тесты `Core.Web.Prefer` в библиотеке.

Тесту, который read-модель не читает, прогон не нужен: версию для следующей команды он берёт
из возврата usecase, а не из ReadRepo.

```elixir
# плохо — прогон и чтение ради версии: её уже вернул usecase
{:ok, {:accepted, id, _version}} = <Aggregate>.<Actor>.Usecases.open(context)
:ok = Core.Es.Projection.Test.run_until_idle(MyApp.Domain.<BC>.<ReadModel>.Projection)
{:ok, view} = <Aggregate>.<Actor>.Usecases.get(id, :current, context)
{:ok, _closed} = <Aggregate>.<Actor>.Usecases.close(id, Version.new!(view.version), context)

# хорошо
{:ok, {:accepted, id, version}} = <Aggregate>.<Actor>.Usecases.open(context)
{:ok, {:accepted, ^id, _version}} = <Aggregate>.<Actor>.Usecases.close(id, version, context)
```

## Ратчеты

Ратчет — тест, который держит норму на **всём дереве**, а не на одном модуле. Приложение MUST
иметь ратчеты на те нормы, которые иначе проверяются только ревью:

| Норма | Где записана |
|---|---|
| каждое значение `Core.Enum` описано в `@moduledoc` | `deps/core/docs/rules/11-domain.md`, «Описание значений в `@moduledoc`» |
| wire-теги событий уникальны и квалифицированы типом агрегата | `14-events-outbox.md` |
| `constraint_errors` сходятся с `changeset/2` и с ограничениями БД | `13-repos.md` |
| новая миграция создаёт индексы `concurrently` | `18-migrations.md` |
| `watch_list/0` согласован с конфигурацией | `17-otp-concurrency.md` |
| состав `plugins/0` PromEx и провайдеры публикуют метрику | `21-observability.md`, «Метрики» |
| примеры тел в спецификации проходят валидацию схем | `15-web-api.md` |
| страница выборки — в query, а не в теле запроса | `15-web-api.md`, «Поверхности и версии» |
| у каждого события название и автор — учётная запись, у struct'а, Enum и id нагрузки — объявление подписей | `11-domain.md`, «Подписи» |

- Ратчет описаний enum — `test/my_app/enum_docs_test.exs`, один на приложение:
  `use Core.Enum.DocsCase, otp_app: :my_app`, а не своя копия сверки; что он сверяет —
  `deps/core/docs/rules/19-testing.md`, «Enum: описания и внешние коды».
- Ратчет wire-тегов событий — `test/my_app/es/event_tags_test.exs`, один на приложение:
  `use Core.Es.Event.TagsCase, otp_app: :my_app`, а не своя копия сверки; зонтичное приложение
  перечисляет в `otp_app:` все приложения одной базы. Что он сверяет и как снимается проверка
  с записанного тега без префикса — `deps/core/docs/rules/19-testing.md`, «Wire-теги событий».
- Ратчет `constraint_errors` — `test/my_app/repo/constraint_errors_test.exs`, один на
  приложение: `use Core.Repo.ConstraintErrorsCase, otp_app: :my_app`, а не своя копия сверки;
  что он сверяет — `deps/core/docs/rules/19-testing.md`, «`constraint_errors`».
- Ратчет полноты подписей — `test/my_app/labels/completeness_test.exs`, один на приложение.
  Приложение, отдающее сведения событий, MUST подключить его: `use Core.Labels.CompletenessCase,
  otp_app: :my_app`, а не своя копия сверки и не тест на агрегат. Что он сверяет —
  `deps/core/docs/rules/11-domain.md`, «Ратчет полноты».
- Ратчет спецификаций OpenAPI — `test/my_app_web/api_spec_test.exs`, один на приложение.
  Приложение с `open_api_spex` MUST подключить его: `use Core.Web.ApiSpecCase, otp_app: :my_app`.
  Спецификации он находит сам — модули с `@behaviour OpenApiSpex.OpenApi`; что он сверяет — его
  `@moduledoc`.
- Новый ратчет MUST объяснять в `@moduledoc`, какое правило он проверяет и почему проверка
  именно такая: иначе следующий прочтёт его как тест поведения и ослабит.
- Ратчет со списком-исключением MUST быть заморожен: список пополняется **только** вместе со
  строкой в `DEBT.md`, а не «чтобы прошло». Иначе ратчет превращается в место, куда прячут
  нарушения.

## Read-путь

- Тест `to_view/1` и исполняемая сверка формы jsonb с ручной частью спеки `Redump` —
  `deps/core/docs/rules/19-testing.md`, «View: round-trip неприменим» и «jsonb на read-пути:
  контракт wire».
- Презентер, который что-то не отдаёт наружу (ключ хранилища, внутренний идентификатор), MUST
  иметь тест именно на это (`12-errors.md`).

## Внешние зависимости

- HTTP-клиенты — через тестовый plug из `config/test.exs`; живые вызовы MUST NOT.
- Живой брокер или хранилище — под тегом (`deps/core/docs/rules/19-testing.md`, «Внешние
  зависимости»).
- Oban — режим `testing: :manual`; постановка джобы проверяется
  `Oban.Testing.assert_enqueued/1`. Воркер с внешним эффектом MUST иметь тест на ключ
  идемпотентности: две постановки с одинаковыми `unique`-полями дают одну джобу
  (`14-events-outbox.md`, «Идемпотентность потребителей»).
- Служба учёта ошибок — тестовый режим SDK: `config :sentry, test_mode: true` в
  `config/test.exs`, `Sentry.Test.setup_sentry/1` в `setup`, пойманные события —
  `Sentry.Test.pop_sentry_reports/0`. `setup_sentry/1` без `{:bypass, "~> 2.0", only: :test}` в
  зависимостях не работает. Заглушка `Core.Web.CriticalError` или SDK — MUST NOT: она не
  проверяет ни форму события, ни то, что идентификатор принадлежит записи этого запроса. `async:` и
  дедупликация SDK — `deps/core/docs/rules/21-observability.md`, «Тесты».
- Хранилище ключей субъектов в тестах — встроенное `Core.Es.Personal.KeyStore.Pg` с тестовыми
  литералами KEK (набор версий с `current_kek:`) и секрета индекса в `config/test.exs`, на той же
  миграции `es_subject_keys`, что в проде; дублёр порта MUST NOT. Приложение со своей реализацией
  порта MAY подменять её в тестах встроенной (`config :core, Core.Es.Personal.KeyStore,
  Core.Es.Personal.KeyStore.Pg` в `config/test.exs`): свою реализацию держит её контрактный набор и
  golden (`deps/core/docs/rules/19-testing.md`, «Хранилище ключей»). Литералы теста в
  `config/runtime.exs` и в прод-конфигурации MUST NOT.
- Обе точки ответа 500 (`15-web-api.md`, «FallbackController») MUST иметь тест, который сверяет
  `data.errorId` ответа с `event_id` пойманного события, а не только наличие поля. Исключение из
  экшена `Phoenix.ConnTest` выбрасывает заново: ответ `ErrorJSON` берётся `assert_error_sent/2`.

```elixir
# плохо — заглушка отчёта: идентификатор не связан с записью
stub(CriticalErrorMock, :report, fn _reason, _stacktrace -> "id" end)
assert %{"data" => %{"errorId" => "id"}} = json_response(conn, 500)

# хорошо — MyAppTest.ConnCase, тестовый режим SDK
setup do
  Sentry.Test.setup_sentry(dedup_events: false)
end

# FallbackController: usecase отказал прикладной ошибкой
test "критическая ошибка записана, ответ несёт её идентификатор", %{conn: conn, order: order} do
  body = conn |> post(~p"/api/v1/orders/#{order.id}/cancel") |> json_response(500)

  assert [%Sentry.Event{event_id: error_id}] = Sentry.Test.pop_sentry_reports()
  assert %{"code" => "internal_error", "data" => %{"errorId" => ^error_id}} = body
end

# ErrorJSON: экшен упал исключением
test "падение экшена записано, ответ несёт его идентификатор", %{conn: conn, order: order} do
  {500, _headers, body} =
    assert_error_sent(500, fn -> post(conn, ~p"/api/v1/orders/#{order.id}/cancel") end)

  assert [%Sentry.Event{event_id: error_id}] = Sentry.Test.pop_sentry_reports()
  assert %{"data" => %{"errorId" => ^error_id}} = Jason.decode!(body)
end
```

## Доменное время

Тестовые часы включаются строкой конфигурации и стартом сервера владения: `config/test.exs` MUST
задавать `config :core, clock: Core.Clock.Test`, `test/test_helper.exs` MUST звать
`:ok = Core.Clock.Test.start()` до `ExUnit.start/1`. Без часов тест не остановит доменное время, и
история с истечением срока через usecase или HTTP не проверяется. В prod ключ не задаётся:
системные часы — умолчание `Core.Config`. `freeze` / `advance` / `allow` и когда глобальный режим —
`deps/core/docs/rules/19-testing.md`, «Время».

```elixir
# config/test.exs
config :core, clock: Core.Clock.Test

# test/test_helper.exs
:ok = Core.Clock.Test.start()
ExUnit.start()
```

## Доставка outbox

Брокера в `make test` нет: цепочку реакций через outbox тест гонит дублёр доставки
`Core.Outbox.Test` (`deps/core/docs/rules/19-testing.md`, «Доставка outbox»).

- Список подписчиков компонента MUST отдавать одна функция приложения: её зовут и корень
  компонента (элемент `subscriber:` в `topics:` дерева
  `Core.PubSub.MqSubscriberReliable.Supervisor`), и тест (`Core.Outbox.Test.drain/2`, реактор).
  Копия списка в тесте расходится с деревом по составу и опциям обработки, и тест проверяет не
  тех подписчиков, что работают в проде.
- Дерево очереди `Core.Outbox.Supervisor` в тестовом окружении MUST быть выключено: тумблер
  `OUTBOX_ENABLED` (`14-events-outbox.md`, «Конфигурация») в `:test` даёт `enabled: false`.
  Включённый поллер резервирует те же записи, что дублёр, и уводит их мимо подписчиков теста.
  Дублёр дерево не трогает и без него работает.
- Приложение с реактором `Core.Outbox.Test.Reactor` MUST задать тестовому repo
  `queue_target: 5_000` в `config/test.exs`. Реактор работает на соединении sandbox теста и ждёт,
  пока тест или его HTTP-запрос держит это соединение. Ожидающего sandbox отбрасывает через
  `queue_target * 2` — по умолчанию через 100 мс. Под нагрузкой CI запрос дольше этого роняет
  проход реактора отказом соединения, и `settle/2` валит тест чужим отказом.

```elixir
# плохо — список подписчиков переписан в тесте: новый подписчик дерева тестом не покрыт
:ok = Core.Outbox.Test.drain([[name: :notify, topic: "orders", on_message: &Notify.on_message/3]])

# хорошо — одна функция для дерева и теста
def subscribers do
  [[name: MyApp.<Component>.OrdersSubscriber, topic: "orders",
    from_message: &MyApp.<Component>.from_message/1, on_message: &MyApp.<Component>.on_message/3]]
end

topics: Enum.map(subscribers(), &[reader: reader(&1), subscriber: &1])
:ok = Core.Outbox.Test.drain(MyApp.<Component>.subscribers())

# config/runtime.exs — в :test очередь выключена независимо от env
config :my_app, Core.Outbox.Supervisor,
  enabled: config_env() != :test and System.get_env("OUTBOX_ENABLED") == "true"

# config/test.exs — реактор дождётся соединения, которое держит тест
config :my_app, MyApp.Infra.DAO,
  pool: Ecto.Adapters.SQL.Sandbox,
  queue_target: 5_000
```

## Пробелы

Известный пробел покрытия MUST быть записан задачей в трекере задач приложения, а не оставаться
незафиксированным: ненаписанный тест и сознательно отложенный тест выглядят одинаково.

Строкой `DEBT.md` пробел MUST NOT (`00-index.md`, «`DEBT.md` приложения»).

## Связанные правила

- Раскладка слоёв — `10-architecture.md`
- Кодеки и справочники — `11-domain.md`
- Репозитории, View и ACL — `13-repos.md`
- События и идемпотентность — `14-events-outbox.md`
- Контрактные тесты фасадов кеша — `16-caching.md`
- Процессы — `17-otp-concurrency.md`
- Ратчет миграций — `18-migrations.md`
- Контракты тестов библиотеки — `deps/core/docs/rules/19-testing.md`
- Служба учёта ошибок — `21-observability.md`
