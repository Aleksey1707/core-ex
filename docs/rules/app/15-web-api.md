# Web API

- **Область.** `lib/my_app_web/**`: контроллеры, схемы OpenApiSpex, презентеры, плаги,
  `FallbackController`, роутер и эндпоинт.
- **Читать перед.** Новым ресурсом или экшеном, правкой схемы запроса и ответа, презентера,
  плага аутентификации и обработки ошибок HTTP.
- **Словарь.** Плейсхолдеры и модальность — `deps/core/docs/rules/00-index.md`.

Общую часть границы даёт библиотека: конверт (`Core.Web.Response` и его словарь кодов), разбор
параметров (`Core.Web.Params`), таблица `%Error{}` → статус (`Core.Web.ErrorMapper`), camelCase
(`Core.Helper.Keys`), сервер метрик (`Core.Web.MetricsPlug`) —
`deps/core/docs/rules/10-architecture.md`, «Граница HTTP». Приложение её конфигурирует, а не
повторяет: своих копий этих модулей быть
не должно.

## Поверхности и версии

- Поверхность (публичная, системная, callback внешней системы) — свой префикс и свой пайплайн
  плагов.
- Версия API — каталог `v1` со своим `ApiSpec` (`MyAppWeb.<Api>.<Version>.ApiSpec`): `servers` и
  `info.version` одни на документ, поэтому спецификация — на версию. Спецификация —
  `<префикс версии>/openapi`, UI — `<префикс версии>/swaggerui`. Следующая версия заводится
  соседним каталогом со своим `ApiSpec`, а не флагом внутри существующих модулей. До первого
  релиза приложения несовместимая правка идёт в текущей версии на месте (`00-index.md`, «Первый
  релиз»).
- Выборка с фильтрами — `POST /<resource>/search` с телом, чтение по идентификатору — `GET`,
  действие над агрегатом — `POST /<resource>/:id/<action>`.
- Литеральный сегмент MUST объявляться раньше параметра (`/spec` до `/:id`): маршрутизатор
  берёт первый совпавший маршрут.

## Раскладка

Путь файла следует из имени модуля (`10-architecture.md`, «Раскладка»). Корень `MyAppWeb` MUST
состоять из поверхностей и модулей таблицы: модуль без роли в корне (`Helper`, `Parse`) не
находится по имени, и под него заводят второй такой же.

| Модуль | Что держит |
|---|---|
| `MyAppWeb.<Api>` | поверхность: namespace её версий и ресурсов |
| `MyAppWeb.<Api>.<Version>.ApiSpec` | спецификация версии поверхности и её схема аутентификации |
| `MyAppWeb.<Api>.<Version>.<Resource>.Controller` | контроллер ресурса |
| `MyAppWeb.<Api>.<Version>.<Resource>.Schemas.*` | схемы этого ресурса |
| `MyAppWeb.<Api>.<Version>.<Resource>.Params.*` | разбор входа ресурса: query и body → Prim, фильтр, attrs |
| `MyAppWeb.<Api>.<Version>.<Resource>.<Nested>.*` | вложенный ресурс (`/orders/:id/items`) |
| `MyAppWeb.<Api>.<Version>.<Group>.<Resource>.*` | ресурс группы без своего ресурса (`/security/roles`): `<Group>` — только namespace, его `Schemas` и `Params` — по той же лестнице |
| `MyAppWeb.<Api>.<Version>.Schemas.*` | схемы, общие для ресурсов одной версии поверхности |
| `MyAppWeb.<Api>.Schemas.*` | схемы, общие для версий одной поверхности |
| `MyAppWeb.Schemas.*` | схемы, общие для поверхностей: конверт, страница, ошибка, ответ записи `Written` / `Created`, заголовки `Prefer` / `Preference-Applied` |
| `MyAppWeb.Params.*` | разбор входа, общий для поверхностей; общий для версий или ресурсов — `<Api>.Params.*`, `<Api>.<Version>.Params.*` |
| `MyAppWeb.Presenters.*`, `MyAppWeb.Plugs.*` | View / domain → map ответа, одна форма на весь HTTP-слой; контекст и аутентификация. Презентер или плаг одной поверхности (версии, ресурса) — по той же лестнице, что `Schemas` |
| `MyAppWeb.FallbackController`, `MyAppWeb.ErrorMapper` | ответ на ошибку и таблица статусов; один на приложение в корне, MAY — свой у поверхности (`<Api>.FallbackController`) |
| `MyAppWeb.ErrorJSON` | ответ Phoenix на исключение (`render_errors:` у `Endpoint`) |
| `MyAppWeb.Accepted` | ответ команды после ожидания проекции — решение по `Prefer`, 202 и ответ создания, один на приложение («Ожидание проекции») |
| `MyAppWeb.Response`, `MyAppWeb.Response.Code` | конверт ответа `use Core.Web.Response, codes: MyAppWeb.Response.Code` (`deps/core/docs/rules/10-architecture.md`) |
| `MyAppWeb.Endpoint`, `MyAppWeb.Router`, `MyAppWeb.Telemetry` | обвязка Phoenix |

```text
lib/my_app_web/<api>/<version>/api_spec.ex
lib/my_app_web/<api>/<version>/<resource>/controller.ex
lib/my_app_web/<api>/<version>/<resource>/schemas/*.ex
lib/my_app_web/<api>/<version>/<resource>/params/*.ex
lib/my_app_web/<api>/<version>/<resource>/<nested>/controller.ex
lib/my_app_web/<api>/<version>/schemas/*.ex
lib/my_app_web/<api>/schemas/*.ex
lib/my_app_web/{schemas,params}/*.ex
lib/my_app_web/{presenters,plugs}/*.ex
lib/my_app_web/{error_mapper,fallback_controller,error_json,accepted,response}.ex
lib/my_app_web/{endpoint,router,telemetry}.ex
```

- Поверхность MUST быть своим namespace `MyAppWeb.<Api>`: префикс, пайплайн и спецификации у
  поверхностей разные («Поверхности и версии»).
- Общее для нескольких поверхностей — `FallbackController`, `ErrorMapper`, `Presenters`, `Plugs`,
  `Schemas` — MUST лежать в корне `MyAppWeb`, а не в одной из поверхностей: иначе вторая
  поверхность ссылается на первую.
- Ресурс — каталог: контроллер и его схемы лежат рядом, а не по типам файлов. Вложенный ресурс
  MUST быть вложенным namespace родителя, а не соседним ресурсом.
- Схема, которую делят два ресурса, две версии или две поверхности, поднимается в `Schemas`
  ближайшего общего уровня (таблица выше), а не импортируется из соседнего ресурса. Разбор входа
  (`Params`), презентеры и плаги поднимаются по той же лестнице.
- Ответ записи — `MyAppWeb.Schemas.Written` (`id` и целое `version`, оба обязательны; 200 создания
  и 202 любой команды) и `MyAppWeb.Schemas.Created` (`id`, обязателен; создание state-stored) —
  MUST лежать в корне при любом числе поверхностей: форма ответа записи одна на приложение, и вторая
  поверхность берёт ту же схему, а не заводит копию. Туда же и по той же причине — определения
  заголовков ожидания `MyAppWeb.Schemas.Prefer`: параметр запроса `Prefer` и заголовок ответа
  `Preference-Applied` («Ожидание проекции»).
- Модуль одной поверхности лежит в её namespace, общий для поверхностей — в корне под ролью из
  таблицы. `Helper` и другие имена без роли — MUST NOT: новая роль корня — новая строка таблицы.
- `ErrorJSON` MUST лежать в `lib/my_app_web/error_json.ex`, а не в `controllers/`, куда его кладёт
  генератор Phoenix: путь — по имени модуля, `render_errors:` ссылается на модуль, а не на файл.

```elixir
# плохо — схема, общая для поверхностей, лежит в одной из них; вложенный ресурс — сосед родителя;
# ответ записи у единственной поверхности — в её namespace
defmodule MyAppWeb.Public.V1.Schemas.Envelope do
defmodule MyAppWeb.Public.V1.OrderItem.Controller do
defmodule MyAppWeb.Public.V1.Schemas.Written do

# хорошо — ответ записи в корне при любом числе поверхностей
defmodule MyAppWeb.Schemas.Envelope do
defmodule MyAppWeb.Public.V1.Order.Item.Controller do
defmodule MyAppWeb.Schemas.Written do

# плохо — модули без роли в корне web
defmodule MyAppWeb.Parse.OrderFilter do
defmodule MyAppWeb.Helper.Projection do

# хорошо — разбор входа у своего ресурса, ответ после ожидания проекции — роль корня
defmodule MyAppWeb.Public.V1.Order.Params.Filter do
defmodule MyAppWeb.Accepted do
```

Поверхность — namespace `MyAppWeb.<Api>` хотя бы с одним `MyAppWeb.<Api>.<Version>.ApiSpec`, где
`<Version>` — `V<N>`. `ApiSpec` на уровне поверхности (`<Api>.ApiSpec`), в корне
(`MyAppWeb.ApiSpec`) или глубже (`Helper.Deep.ApiSpec`) поверхностью не делает. Отступление — маркер
`web-root` и строка `DEBT.md` (`10-architecture.md`, «Отступление»).

Проверяется: `deps/core/scripts/boundary_lint.exs --consumer` — правило `web-root`: второй сегмент
`MyAppWeb.<X>` — модуль таблицы или поверхность. Нарушение — одно на namespace `MyAppWeb.<X>`: на
модуле `MyAppWeb.<X>.ApiSpec`, если он есть, иначе на первом модуле; маркер ставится туда же.

## Аутентификация в плагах

Аутентификация живёт в плагах, а не в контроллерах.

- Плаг контекста MUST стоять первым: он кладёт `%Context{}` с shadow copy в `conn.assigns` и
  снимает ETS в `before_send` (`11-domain.md`). Плаг аутентификации только докладывает в него
  текущего пользователя.
- Отказ формируется на границе: плаг отвечает 401 сам и дальше `conn` не пускает.
- Текст 401 — константа независимо от причины (нет заголовка, битый токен, истёкшая сессия):
  `deps/core/docs/rules/10-architecture.md`, «Граница HTTP»; причина уходит в `Logger.debug`
  (`12-errors.md`).
- Существование и права пользователя плаг не проверяет — это работа usecase, иначе authz
  растечётся по двум слоям.
- Схема аутентификации MUST быть объявлена в `ApiSpec` своей версии поверхности, иначе UI не даёт
  подставить заголовок.

## Controller

- Бизнес-логика и authz в контроллере MUST NOT: только разбор параметров, вызов usecase и
  презентация.
- `%Context{}` берётся из `conn.assigns`.
- Параметры → доменные Prim через `Core.Web.Params` и `Result.and_then/2`; разбор тела в
  `attrs` — отдельным модулем, а не россыпью в экшене.
- Optimistic lock: заголовок `If-Match` → `Version` через `Core.Web.Params`, форма разбора — по
  экшену:
  - команда MUST — `explicit_version/2` (`*` отвергается 400 `:current_not_allowed`), кроме
    случая ниже;
  - `*` на команде MAY — `expected_version/2`, если исход команды не зависит от состояния,
    которое видел клиент (выдача роли, увеличение счётчика);
  - команда без `If-Match` MUST NOT: забытый заголовок молча затирает конкурентные изменения,
    а `*` — видимое намерение;
  - чтение по версии SHOULD — `expected_version/2`: нет заголовка → 400 `:missing_param`,
    `*` → `:current`; `*` — видимое намерение читать текущее, как на команде, а клиент, который
    всегда шлёт `If-Match`, при гонке получает 412, а не молча чужую версию;
  - чтение по версии MAY — `optional_version/2`: нет заголовка → `:current`;
  - форма чтения выбирается проектом одна на все чтения по версии; другая форма в отдельном
    экшене MUST NOT — клиент API не угадывает, какому чтению нужен заголовок;
  - параметр `If-Match` в `operation/2` SHOULD описываться той же формой, что и разбор:
    `required` и тип — целое либо «целое | `*`».

  `If-Match` над незаведённым event-sourced агрегатом — ошибка домена, если команда отклонена,
  и отказ предусловия, если принята (`deps/core/docs/rules/13-repos.md`, «Write event-sourced
  агрегата»).
- Тело, где «ключ не передан» отличается от «передан `null`», разбирается функцией с явной
  семантикой (`{:ok, value} | :skip`), а не `Map.get/2`.
- Каждый экшен описывается `operation/2`; `@spec` у экшенов не требуется — контракт задаёт
  `operation/2` (`20-agreements.md`).
- Ответы: `Response.success/1` + `json/2`; ошибки — через `action_fallback`.
- Создание state-stored агрегата MUST отвечать `{id}` схемой `MyAppWeb.Schemas.Created`: usecase
  отдаёт только идентификатор (`10-architecture.md`, «Usecases»), проекции у агрегата нет. Создание
  event-sourced агрегата — «Ожидание проекции».

```elixir
# создание state-stored агрегата — `{id}`, в `operation/2` ответ `MyAppWeb.Schemas.Created`
def create(conn, _params) do
  body = OpenApiSpex.body_params(conn)

  with {:ok, name} <- body |> Params.get(:name) |> Result.and_then(&Agg.Name.new/1),
       {:ok, id} <- Usecases.Agg.create(name, conn.assigns.context) do
    json(conn, Response.success(%{id: OutCodec.dump(id)}))
  end
end
```

```elixir
# плохо — забытый If-Match на команде становится :current и затирает конкурентную запись
with {:ok, version} <- Params.optional_version(params),
     {:ok, written} <- Usecases.Agg.take(id, version, context),
     do: respond_taken(conn, id, written)

# хорошо — команда требует явную версию
with {:ok, version} <- Params.explicit_version(params),
     {:ok, written} <- Usecases.Agg.take(id, version, context),
     do: respond_taken(conn, id, written)

# хорошо — чтение по версии: нет заголовка → 400, `*` → :current
with {:ok, version} <- Params.expected_version(params),
     {:ok, view} <- Usecases.Agg.get(id, version, context),
     do: json(conn, Response.success(OutCodec.dump(view)))

# допустимо, если проект выбрал необязательный заголовок: нет заголовка → :current
with {:ok, version} <- Params.optional_version(params),
     {:ok, view} <- Usecases.Agg.get(id, version, context),
     do: json(conn, Response.success(OutCodec.dump(view)))
```

## Ожидание проекции

Команда event-sourced агрегата отвечает представлением из read-модели, но его пишет проекция.
После успешного usecase экшен ждёт её — **вне** транзакции, по потоку агрегата
(`deps/core/docs/rules/22-projections.md`, «Read-after-write»), — если клиент не отказался от
ожидания заголовком `Prefer` (RFC 7240).

Создание ждёт проекцию так же, но MUST отвечать не представлением, а `{id, version}` записи —
одной схемой `MyAppWeb.Schemas.Written` на 200 и на 202: 200 значит, что `GET` по `id` уже видит
запись, 202 — что ещё нет. Почему не представление — ADR-0027
(`deps/core/docs/adr/0027-create-responds-id-and-version.md`).

Готовность ждать задаёт клиент, а не операция: `Prefer` MUST понимать каждая команда
event-sourced агрегата, одинаково. Без ожидания ответ — всегда 202: 200 сохраняет смысл «`GET` уже
видит запись». Почему клиент и почему не 200 — ADR-0030
(`deps/core/docs/adr/0030-prefer-controls-projection-await.md`).

| `Prefer` | Ответ | `Preference-Applied` |
|---|---|---|
| нет, неизвестное или неразборчивое предпочтение | ждать с пределом хелпера (`await_timeout_ms:`): дождался — 200, нет — 202 | нет |
| `respond-async`, `wait=0` | `await` не звать, 202 с `{id, version}` | `respond-async` / `wait=0` |
| `wait=N` | ждать `min(N с, предел)`: дождался — 200, нет — 202 | `wait=<применённое>` |
| `respond-async, wait=N` | как `wait=N` | `wait=<применённое>`; на 202 — и `respond-async` |

`N` — секунды, MAY с дробной частью (`wait=0.2`): это шире RFC 7240. Точность и форму применённого
задаёт `Core.Web.Prefer`.
Почему дробь — ADR-0031 (`deps/core/docs/adr/0031-prefer-wait-accepts-decimal.md`).

Разбор заголовка и значение `Preference-Applied` по итоговому статусу — `Core.Web.Prefer`
(`parse/1`, `mode/2`, `applied/3`). Команда state-stored агрегата и чтение `Prefer` не разбирают и
`Preference-Applied` не ставят: ждать им нечего.

- Usecase команды отдаёт версию после записи, у заведения — пару `{id, version}`
  (`10-architecture.md`, «Usecases»). Ждать проекцию и читать представление — дело экшена.
- `:projection_timeout` и `:projection_rebuilding` — ответ 202 с `{id, version}`, а не ошибка:
  запись применена, повтор команды по ним запрещает свод библиотеки.
- Операция такой команды MUST объявлять ответ `accepted:` со схемой `MyAppWeb.Schemas.Written`,
  операция создания — её же и в `ok:`. Параметр-заголовок `Prefer` и заголовок ответа
  `Preference-Applied` на 200 и 202 операция MUST объявлять общими определениями
  `MyAppWeb.Schemas.Prefer` («Раскладка»): без них клиент об отказе от ожидания не узнает.
- Ответ собирает один хелпер приложения — `MyAppWeb.Accepted` («Раскладка»): он разбирает
  `Prefer` через `Core.Web.Prefer`, решает, ждать ли и сколько, ставит `Preference-Applied` и
  отвечает 200 или 202. Свой разбор `Prefer` в хелпере или экшене MUST NOT: разборы разойдутся.
- Проекцию ждёт литеральный вызов в колбэке-захвате `&Projection.await(Agg, id, &1)`, записанном
  в экшене или в его `defp`: хелпер зовёт колбэк с таймаутом из `Core.Web.Prefer.mode/2` либо не
  зовёт вовсе. Сборка сверяет агрегат и ID там, где записан вызов, и внутри захвата.
  ID на месте вызова MUST быть сужен до `%Agg.ID{}` — паттерном в голове функции с вызовом или
  в `with`: ID из параметра без сужения сборка не сверяет, и ловится только агрегат не из
  `events:`. Хелпер, который зовёт `projection.await(agg, id, timeout)` сам, MUST NOT: через
  модуль-переменную сборка не проверяет ни агрегат, ни ID.
- Ответ создания MUST собирать тот же хелпер — `MyAppWeb.Accepted.written/4` (`conn`, колбэк
  ожидания, `id`, `version`) через `respond/4` с `render`, который отдаёт тело `{id, version}`:
  ветка 202 у хелпера одна, и её тест покрывает и создание.
- Ветку 202 MUST проверять один тест на приложение, через
  `Core.Es.Projection.Test.with_rebuilding/2` (`19-testing.md`, «Event sourcing»).

```elixir
# плохо — чтение сразу после команды: проекция ещё не обработала запись
with {:ok, _version} <- Usecases.Agg.take(id, version, context),
     do: reload(conn, id)

# плохо — ожидание до хелпера: `Prefer` не работает, таймаут клиента не применяется
MyAppWeb.Accepted.respond(conn, Projection.await(Agg, id, 5_000), {id, version}, &reload(&1, id))

# плохо — модуль проекции параметром хелпера: ID другого агрегата сборка не видит
MyAppWeb.Accepted.await(conn, Projection, Agg, id, written, &reload(&1, id))

# плохо — ID параметром defp без сужения: ID другого агрегата сборка не видит
defp respond_taken(conn, id, version) do
  MyAppWeb.Accepted.respond(conn, &Projection.await(Agg, id, &1), {id, version}, &reload(&1, id))
end

# хорошо — литерал в захвате defp экшена, ID сужен в голове, хелпер решает по `Prefer`
with {:ok, version} <- Usecases.Agg.take(id, expected, context),
     do: respond_taken(conn, id, version)

defp respond_taken(conn, %Agg.ID{} = id, version) do
  MyAppWeb.Accepted.respond(conn, &Projection.await(Agg, id, &1), {id, version}, &reload(&1, id))
end

# хорошо — создание: {id, version} и на 200, и на 202
with {:ok, {id, version}} <- Usecases.Agg.open(name, context),
     do: respond_created(conn, id, version)

defp respond_created(conn, %Agg.ID{} = id, version) do
  MyAppWeb.Accepted.written(conn, &Projection.await(Agg, id, &1), id, version)
end

# хорошо — ядро хелпера (`alias Core.Web.Prefer`): колбэк не зван при отказе от ожидания,
# `Preference-Applied` — по итоговому статусу: `Prefer.applied(prefer, max_ms, 200 | 202)`
def respond(conn, await, {id, version}, render) when is_function(await, 1) do
  prefer = conn |> get_req_header("prefer") |> Prefer.parse()
  max_ms = await_timeout_ms()

  case Prefer.mode(prefer, max_ms) do
    :respond_async -> accepted(conn, {prefer, max_ms}, {id, version})
    {:wait, timeout} -> respond_awaited(conn, {prefer, max_ms}, await.(timeout), {id, version}, render)
  end
end
```

## FallbackController

`FallbackController` таблицы статусов не содержит: он зовёт маппер приложения, отправляет
конверт и логирует на уровне, который вернула таблица.

- Таблица маппера приложения — чистая функция, проверяемая тестом построчно: свои клозы `map/1`
  перед делегированием в `Core.Web.ErrorMapper.map/2` (`deps/core/docs/rules/10-architecture.md`,
  «Граница HTTP»).
- `%Ecto.Changeset{}` в клозах MUST NOT: репозиторий его не отдаёт (`13-repos.md`).
- Ошибку, не дошедшую до контроллера (неизвестный маршрут, неразобранное тело, отказ плага,
  непойманное исключение), MUST отдавать тем же конвертом: клиент разбирает ответ одинаково на
  любой ошибке API, и сгенерированный фреймворком формат здесь MUST NOT.

## Schemas

- Только контракт HTTP request/response; смешивать с domain-struct и Ecto-схемой MUST NOT.
- Конверт и страницы собираются общими хелперами, а не переписываются в каждом ресурсе.
- Значения справочников берутся из самого enum (`Enum.map(Status.values(), …)`), а не
  выписываются строками: иначе список разойдётся с доменом.
- Форма, повторяющаяся в нескольких ответах, объявляется отдельной схемой и подключается
  **модулем**: в спецификации появляется ссылка, а не копия.
- Примеры тел в спецификации MUST проходить валидацию своих схем — ратчетом, а не на глаз
  (`19-testing.md`).

## Presenters

| Concern | Convention |
|---|---|
| Ключи | camelCase (`Core.Helper.Keys.camelize/1,2`) |
| Представление | `OutCodec.dump(view)` — формат задаёт `<Aggregate>.View.Codec` |
| Агрегат | `OutCodec.dump(agg)` либо ручной маппинг полей под форму API |
| События | `OutCodec.dump(event)` → конверт целиком; нагрузка — `camelize` |
| Страница | презентер отдаёт **один** элемент; `%{count, items}` собирает конверт |

- Query-usecases отдают **представление**, а не агрегат: на read-пути презентер агрегаты не
  трогает (`13-repos.md`).
- Форматировать даты, идентификаторы и суммы руками в презентере MUST NOT: формат разъедется
  с агрегатным путём.
- Ключи, которые задаёт не приложение (значения справочника, заголовки клиента), MUST NOT
  камелизоваться: переименованный ключ уйдёт потребителю чужим. Такие поддеревья выводятся
  из общей камелизации через `except:`.
- Публичный API презентера — `to_map/1`, при необходимости сокращённая форма для вложенных
  ссылок. Больше одной формы на ресурс без нужды не заводить: расхождение форм — расхождение
  контракта.

## Связанные правила

- Usecases и слои — `10-architecture.md`
- Prim и `Version` на входе — `11-domain.md`
- Ошибки на границе — `12-errors.md`
- Представления read-пути — `13-repos.md`
- Тесты контроллеров и примеров спецификации — `19-testing.md`
