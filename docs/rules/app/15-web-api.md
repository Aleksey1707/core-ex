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

- Поверхность (публичная, системная, callback внешней системы) — свой префикс, свой
  `ApiSpec` и свой пайплайн плагов. Спецификация — `<префикс>/openapi`, UI — `<префикс>/swaggerui`.
- Версия API — каталог `v1`: следующая версия заводится соседним каталогом, а не флагом внутри
  существующих модулей.
- Выборка с фильтрами — `POST /<resource>/search` с телом, чтение по идентификатору — `GET`,
  действие над агрегатом — `POST /<resource>/:id/<action>`.
- Литеральный сегмент MUST объявляться раньше параметра (`/spec` до `/:id`): маршрутизатор
  берёт первый совпавший маршрут.

## Раскладка

```text
lib/my_app_web/<api>/<version>/<resource>/controller.ex
lib/my_app_web/<api>/<version>/<resource>/schemas/*.ex   # схемы этого ресурса
lib/my_app_web/<api>/<version>/schemas/*.ex              # общие: конверт, страницы, ошибка
lib/my_app_web/presenters/*.ex                           # View / domain → map ответа
lib/my_app_web/plugs/*.ex                                # контекст и аутентификация
lib/my_app_web/{error_mapper,fallback_controller}.ex
```

- Ресурс — каталог: контроллер и его схемы лежат рядом, а не по типам файлов.
- Схема, которую делят два ресурса или две поверхности, поднимается в общий каталог, а не
  импортируется из соседнего ресурса.
- Презентеры общие для всех поверхностей: одна форма агрегата на весь HTTP-слой.

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
- Схема аутентификации MUST быть объявлена в `ApiSpec` своей поверхности, иначе UI не даёт
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

```elixir
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
После успешного usecase экшен MUST дождаться её — **вне** транзакции, по потоку агрегата
(`deps/core/docs/rules/22-projections.md`, «Read-after-write»).

- Usecase команды отдаёт версию после записи, у заведения — пару `{id, version}`
  (`10-architecture.md`, «Usecases»). Ждать проекцию и читать представление — дело экшена.
- `:projection_timeout` и `:projection_rebuilding` — ответ 202 с `{id, version}`, а не ошибка:
  запись применена, повтор команды по ним запрещает свод библиотеки.
- Операция такой команды MUST объявлять ответ `accepted:` со своей схемой.
- Ответ 202 по `:projection_timeout` / `:projection_rebuilding` собирает один хелпер
  приложения — `MyAppWeb.Helper.Projection`. Проекцию ждёт литеральный вызов
  `Projection.await(Agg, id, timeout)` в экшене или в его `defp`, хелпер принимает результат.
  ID на месте вызова MUST быть сужен до `%Agg.ID{}` — паттерном в голове функции с вызовом или
  в `with`: ID из параметра без сужения сборка не сверяет, и ловится только агрегат не из
  `events:`. Хелпер, который зовёт
  `projection.await(agg, id, timeout)` сам, MUST NOT: через модуль-переменную сборка не
  проверяет ни агрегат, ни ID.
- Ветку 202 MUST проверять один тест на приложение, через
  `Core.Es.Projection.Test.with_rebuilding/2` (`19-testing.md`, «Event sourcing»).

```elixir
# плохо — чтение сразу после команды: проекция ещё не обработала запись
with {:ok, _version} <- Usecases.Agg.take(id, version, context),
     do: reload(conn, id)

# плохо — модуль проекции параметром хелпера: ID другого агрегата сборка не видит
MyAppWeb.Helper.Projection.await(conn, Projection, Agg, id, written, &reload(&1, id))

# плохо — ID параметром defp без сужения: ID другого агрегата сборка не видит
defp respond_taken(conn, id, version) do
  MyAppWeb.Helper.Projection.respond(conn, Projection.await(Agg, id, 5_000), {id, version}, &reload(&1, id))
end

# хорошо — литерал в defp экшена, ID сужен в голове, ответ 202 получает {id, version}
with {:ok, version} <- Usecases.Agg.take(id, expected, context),
     do: respond_taken(conn, id, version)

defp respond_taken(conn, %Agg.ID{} = id, version) do
  MyAppWeb.Helper.Projection.respond(conn, Projection.await(Agg, id, 5_000), {id, version}, &reload(&1, id))
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
