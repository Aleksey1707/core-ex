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
  сам модуль (`10-architecture.md`, «Раскладка»); линтер дерево `test/` не проверяет.
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
| `test/support/fixtures/events/**` | снимки wire-формата событий |

- Сборка фикстур доменными конструкторами и событиями, а не строками в БД, —
  `deps/core/docs/rules/19-testing.md`, «Case-модули»; объявления Prim для проверки «секрет не
  утекает» — там же, «Чувствительные данные».
- Дублёр внешней системы MUST держать контракт адаптера буквально, включая поведение при
  ошибке. Дублёр, который «всегда `:ok`», прячет ровно тот класс ошибок, ради которого пишется
  тест.

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

Тест хелпера MUST проходить три ветки `Prefer` (`15-web-api.md`, «Ожидание проекции»): без
заголовка `wait/1` отдаёт предел хелпера, на `respond-async` — `:none`, на `wait=N` — урезанный
таймаут; `respond/3` и `written/2` отвечают 200 на `:projected` и 202 на `:accepted`, и
`Preference-Applied` сверяется в каждой ветке. Разбор самого заголовка проверяют тесты
`Core.Web.Prefer` в библиотеке.

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
| корень очереди зовёт `Core.Outbox.check_singleton!/1` до подъёма своих детей | `14-events-outbox.md`, «Единственность поллера» |
| примеры тел в спецификации проходят валидацию схем | `15-web-api.md` |

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
- Новый ратчет MUST объяснять в `@moduledoc`, какое правило он проверяет и почему проверка
  именно такая: иначе следующий прочтёт его как тест поведения и ослабит.
- Ратчет со списком-исключением MUST быть заморожен: список пополняется **только** вместе со
  строкой в `DEBT.md`, а не «чтобы прошло». Иначе ратчет превращается в место, куда прячут
  нарушения.

## Read-путь

- Тест `to_view/1` и исполняемая сверка формы jsonb по спеке `Redump` —
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
