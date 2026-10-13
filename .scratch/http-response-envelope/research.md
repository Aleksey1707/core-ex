# Конверт HTTP-ответа: проект-образец против core-ex

Исследование по исходному коду. Цель — переделка `Core.Web.Response` / `Core.Web.ErrorMapper`
под формат проекта-образца.

Обозначения ссылок:

- `web/…` — пакет веб-слоя проекта-образца (относительно корня его кода приложения);
- `<веб-библиотека>/…` — внешняя веб-библиотека образца, поверх которой он строит ответ (aiohttp-часть
  библиотеки, версия зафиксирована в lock-файле образца; исходники читались из кеша пакетного
  менеджера по коммиту из lock-файла — в виртуальном окружении проекта пакет не установлен);
- `<модуль-N>/…` — модули предметной области образца, обезличены; номер сквозной по документу;
- `tests/…` — тесты образца, доменные каталоги заменены так же;
- ссылки без префикса — файлы core-ex.

Тексты сообщений в JSON-примерах заменены на нейтральные, форма тел — как в первоисточнике.

## 1. Проект-образец

### 1.1. Как строится ответ

Цепочка успешного ответа:

1. View образца наследует `View` веб-библиотеки (`web/view.py:54`), `execute()` возвращает
   dataclass / dict / `None`.
2. `View.process_response` — если результат не `StreamResponse`, вызывается `serialize`
   (`<веб-библиотека>/views/view.py:121-125`).
3. `serialize` прогоняет результат через `Meta.response_schema.dump` (если схема задана) и отдаёт
   сериализатору (`<веб-библиотека>/views/view.py:136-140`).
4. Сериализатор по умолчанию — `ApiSerializer` (`<веб-библиотека>/views/view.py:89`), он строит
   `ApiOkResponse(data=result, http_status=200)` (`<веб-библиотека>/serializers.py:85-89`).
5. `ApiResponse.generate_response_dict`: `{"status": api_status, "data": data}` + extra-kwargs
   в корень (`<веб-библиотека>/response.py:139-145`); `data is None` → `{}`
   (`<веб-библиотека>/response.py:118-119`, `:141-142`).
6. JSON: `Content-Type: application/json; charset=utf-8` (`<веб-библиотека>/response.py:65-66`,
   `:84`), компактный, `ensure_ascii=False` (`<веб-библиотека>/json_utils.py:43`).

Ошибки: middleware `exception_mw` веб-библиотеки (`<веб-библиотека>/middlewares.py:24-50`),
подключён приложением через `get_middlewares` базового `Application`
(`<веб-библиотека>/application.py:59-63`). Образец добавляет к нему свой `auth_mw` **внутрь**
(`web/app.py:102-104`) и ещё один middleware в хвост (`web/app.py:100`). Порядок обёрток:
`exception_mw` → `auth_mw` → обработчик, то есть исключения `auth_mw` ловятся `exception_mw`,
а возвращённые им ответы проходят мимо.

### 1.2. Конверт успеха

| Поле | Значение | Источник |
|---|---|---|
| `status` | всегда строка `"ok"` | `<веб-библиотека>/response.py:148-169`, схема — `<веб-библиотека>/schema.py:8-15` |
| `data` | результат `execute()` после `response_schema.dump`; `None` → `{}` | `<веб-библиотека>/response.py:118-119` |
| прочие | extra-kwargs `ApiOkResponse(**kwargs)` попадают в корень; приложение этим не пользуется (поиск `response_api_ok` / `ApiOkResponse` по коду приложения пуст) | `<веб-библиотека>/response.py:110-116` |

HTTP-статус — 200 (`<веб-библиотека>/serializers.py:75-77`). Других успешных статусов в конверте
приложение не ставит (поиск `http_status=` / `HTTPCreated` / `status=201` по коду приложения пуст):
создание отвечает 200.

```json
{"status": "ok", "data": {"id": 1, "name": "…", "positions": [{"id": 7, "name": "…"}]}}
```

Тест: хелпер `construct_ok_response(data)` → `{"status": "ok", "data": data}` (`tests/utils.py:82-86`);
создание — 200 и сущность в `data` (`tests/<модуль-5>/views/test_<создание>.py:57-60`).

Ключи `data` — snake_case, как поля marshmallow-dataclass схем (`tests/<модуль-5>/views/test_<список>.py:142-181`);
camelCase — точечно, опцией отдельной view (`<модуль-6>/views/base_view.py:47`, `:58-59`).

Даты: если значение не прошло через `response_schema`, JSON-энкодер библиотеки пишет
`datetime`/`date` **unix-timestamp целым** (`<веб-библиотека>/json_utils.py:22-23`), а через схему —
ISO-строкой marshmallow. Два формата даты в зависимости от пути.

### 1.3. Конверт ошибки

Тело собирает `ApiErrorResponse`: `{"status": "error", "data": data or {}}` + `code` + `message`
(`<веб-библиотека>/response.py:178-212`). `message` кладётся только если непустой
(`<веб-библиотека>/response.py:191-192`); `code` передаётся всегда и при `None` уходит `null`
(`<веб-библиотека>/error.py:47-55`).

| Поле | Тип | Смысл |
|---|---|---|
| `status` | `"error"` | константа |
| `data` | object, по умолчанию `{}` | структурированные детали; на практике — только `{"fields": …}` |
| `code` | string \| null | машинный код класса ошибки; у aiohttp-исключений — `null` |
| `message` | string | один текст для человека; отсутствует, если пуст |

Поля `inline` и `description` у `Error` хранятся (`<веб-библиотека>/error.py:41`, `:44`), но в тело
не попадают (`<веб-библиотека>/error.py:47-55`).

Как исключение становится телом:

| Источник | HTTP | `code` | `message` | `data` | Ссылка |
|---|---|---|---|---|---|
| `Error` веб-библиотеки и подклассы | `status` класса | `code` класса | `message` | `data` | `<веб-библиотека>/middlewares.py:30-35`, `<веб-библиотека>/error.py:47-55` |
| `InternalError` | 500 | `"internal_error"` | `"Internal Error"` | `{}` | `<веб-библиотека>/error.py:68-71` |
| `BadRequestError` | 400 | `"bad_request"` | `"Bad request"` | `{}` | `<веб-библиотека>/error.py:74-77` |
| `NotAuthorizedError` | 401 | `"not_authorized"` | `"Not authorized"` | `{}` | `<веб-библиотека>/error.py:80-83` |
| `ForbiddenError` | 403 | `"forbidden"` | `"Forbidden"` | `{}` | `<веб-библиотека>/error.py:86-89` |
| `NotFoundError` | 404 | `"not_found"` | `"Not Found"` | `{}` | `<веб-библиотека>/error.py:92-95` |
| `AlreadyExistsError` | 409 | `"conflict"` | `"Already exists"` | `{}` | `<веб-библиотека>/error.py:98-101` |
| свои подклассы `Error` приложения | 400 / 409 | свой (`"client_error_with_msg"`, `"bad_multipart_form_data_request"`, …) | свой | `{}` | `<модуль-9>/errors.py:4-6`, `web/form_data/errors.py:10-23` |
| aiohttp `HTTPException` < 500 | его статус | `null` | `e.text` | `{}` | `<веб-библиотека>/middlewares.py:37-44` |
| aiohttp `HTTPException` ≥ 500 | его статус | `"internal_error"` | `"Internal Error"` | `{}` | `<веб-библиотека>/middlewares.py:38-40` |
| marshmallow `ValidationError` в view | 400 | `"bad_request"` | `"Bad request"` | `{"fields": normalized_messages()}` | `<веб-библиотека>/views/view.py:175-181` |
| любое другое исключение | 500 | `"internal_error"` | `"Internal Error"` | `{}` | `<веб-библиотека>/middlewares.py:48-50` |

`e.text` у aiohttp-исключения: если view передала `text=` — сам текст; если только `reason=` —
`"<статус>: <reason>"` (aiohttp 3.8.6, `aiohttp/web_exceptions.py:109-110`). Пример второго случая —
`"424: Ошибка валидации: …"`.

Чем пользуется приложение на деле (поиск `raise …` по коду приложения): aiohttp-исключения —
298 мест (`HTTPNotFound` 137, `HTTPConflict` 64, `HTTPBadRequest` 61, `HTTPFailedDependency` 23,
прочие единицы); классы веб-библиотеки — 9 (`BadRequestError` 8, `NotAuthorizedError` 1) плюс
четыре базовых своих подкласса `Error`. То есть **основная масса ошибок уходит с `code: null`**,
различаются они HTTP-статусом и текстом.

Типовая ошибка (aiohttp-исключение с `text=`):

```json
{"status": "error", "data": {}, "code": null, "message": "Ресурс не найден или удалён"}
```

Тесты: `construct_error_response(message)` → `{"status": "error", "data": {}, "code": null, "message": …}`
(`tests/utils.py:73-79`); 404 (`tests/<модуль-5>/views/test_<изменение>.py:137-143`); 409 с `code: null`
(`tests/<модуль-10>/views/test_<создание>.py:90-96`).

Ошибка со своим кодом (подкласс `Error`, 409):

```json
{"status": "error", "data": {}, "code": "client_error_with_msg", "message": "Действие недоступно: …"}
```

Тест: `tests/<модуль-9>/views/test_<действие>.py:194-200`.

#### Ошибки валидации

Основной формат — по полям, в `data.fields`, значения — списки строк (форма marshmallow
`normalized_messages()`), вложенность сохраняется, индекс элемента списка — строковый ключ:

```json
{
  "status": "error",
  "code": "bad_request",
  "message": "Bad request",
  "data": {"fields": {"plan_id": ["Not a valid UUID."], "items": {"0": {"kind": ["Bad kind"]}}}}
}
```

- Источник — `ValidationError` из `query_schema` / `body_schema` / тела `execute()`:
  `<веб-библиотека>/views/view.py:175-181`; разбор запроса образца —
  `web/view.py:79-96`, `:145`.
- Тесты: плоское поле и вложенный индекс — `tests/<модуль-10>/views/test_<пакет>.py:632-633`,
  `:690-693`; полное тело — `tests/<модуль-5>/views/test_<изменение>.py:171-182`.
- Ошибка уровня схемы (`@validates_schema` без имени поля) по правилам marshmallow ложится под
  ключ `"_schema"` (в образце такие валидаторы есть: `<модуль-11>/schema.py:80-85`).
- То же тело приложение собирает и вручную: `raise BadRequestError(data={"fields": fields})`
  (`<модуль-5>/views/<вью-1>.py:107`, `<модуль-5>/views/<вью-2>.py:90`).

Второй формат — **строкой, статус 424**: `ValidationError`, пойманный при разборе multipart-тела,
склеивается в одну строку через `", "` и уходит `HTTPFailedDependency(reason="Ошибка валидации: …")`
(`web/view.py:124-125`, `:147-168`). Итог — `code: null`, `message: "424: Ошибка валидации: a, b"`.

Прочие ошибки разбора тела (`web/view.py:126-144`, `<веб-библиотека>/schema_utils.py:57-64`):

| Ситуация | HTTP | `code` | `message` |
|---|---|---|---|
| тело не JSON / ошибка чтения | 400 | `"bad_request"` | `"body is invalid"` |
| тело превышает лимит | 400 | `null` | `"400: Request body size exceeds …"` |
| тела нет | 400 | `null` | `"body is required"` |
| не тот тип корня | 400 | `null` | `"body must be a mapping but got …"` |

Сбой внешней системы, от которой зависит ответ, — 424 со строкой (`<модуль-6>/views/base_view.py:73-120`;
тесты проверяют только статус — `tests/<модуль-6>/views/test_<загрузка>.py:78`).

### 1.4. Список с пагинацией

Метаданные — **внутри `data`**, рядом с `items`; есть только `total`. Параметры запроса
(`limit`/`offset` или `page`/`size`) в ответ не возвращаются.

```json
{"status": "ok", "data": {"items": [{"id": 1, "name": "…"}], "total": 2}}
```

- Схема ответа `items` + `total`, запрос `limit` (по умолчанию 50, `0..50`) / `offset` —
  `<модуль-5>/views/<список>.py:13-28`, сборка `data` — `:52-65`; подсчёт `total` — `ListView.get_total`
  (`web/view.py:282-287`).
- Другие списки запрашивают `page`/`size` (`<модуль-11>/schema.py:75-78`, `<модуль-12>/views/<поиск>.py:21-22`)
  и при этом могут не отдавать `total` вовсе (`<модуль-12>/views/<поиск>.py:43-45`) или отдавать
  `total = len(items)` без пагинации (`<модуль-10>/views/<список>.py:68`).
- Тест: `tests/<модуль-5>/views/test_<список>.py:139-181` — `{"items": […], "total": 2}` внутри `data`.

Единого хелпера страницы нет: каждый ресурс объявляет `items`/`total` в своей схеме.

### 1.5. Пустой ответ

- Изменяющая view возвращает `None` (`<модуль-10>/views/<изменение>.py:60` и ещё шесть с `-> None`) →
  `data: {}`, HTTP 200:

  ```json
  {"status": "ok", "data": {}}
  ```

  Тест: `tests/<модуль-5>/views/test_<обновление>.py:87-90` — `construct_ok_response({})`.
- 204, 201, 202 в конверте не используются. Создание — 200 с сущностью в `data` либо с `data: {}`
  (если view вернула `None`).

### 1.6. Ответы в обход конверта

| Место | HTTP | Тело |
|---|---|---|
| `web/mw.py:38` — нет заголовка пользователя | 401 | `{"error": "Unauthorized"}` |
| `web/mw.py:47`, `:74` — пользователь не найден / нет сопоставления | 403 | `{"error": "Forbidden"}` |
| `<модуль-1>/views/<вью>.py:52` — запись не найдена | 404 | `text/plain` `Event not found` |
| `<модуль-4>/views/<вью>.py:40` | 200 | `{"success": true}` |
| `<модуль-3>/views/<вебхук-1>.py:27`, `:33`, `<модуль-3>/views/<вебхук-2>.py:49` | 200 | `{"success": true}` (контракт вебхука внешнего сервиса идентификации) |
| `<модуль-3>/views/<вебхук-1>.py:35`, `<модуль-3>/views/<вебхук-2>.py:56` | 500 | `{"messages": [{"messages": [{"id": 500, "text": "…", "type": "error"}]}]}` (тот же внешний контракт) |
| `<модуль-2>/views/<вебхук>.py:31` | 200 | произвольный JSON без конверта (контракт вебхука внешнего сервиса токенов) |
| `<модуль-5>/views/<вью>.py:14` | 200 | пустое тело |
| `<модуль-7>/views/<прокси>.py:46`, `:105`, `:171`, `:189`, `:213`; `<модуль-7>/views/<конфиг>.py:43`, `:49`; `<модуль-8>/views/<прокси>.py:49-197` | статус апстрима | тело апстрима как есть (прокси) |
| `<модуль-8>/views/<прокси>.py:246` | 200 | мок-JSON без конверта |
| выгрузки: `<модуль-5>/views/<выгрузка-1>.py:63`, `<выгрузка-2>.py:65`, `<выгрузка-3>.py:41`; файл: `<модуль-6>/views/<файл>.py:66` | 200 | файл (xlsx / бинарь) |

Тесты фиксируют обход: `{"error": "Unauthorized"}` — `tests/app/base.py:59-64`;
`{"error": "Forbidden"}` — `tests/<модуль-4>/views/test_<авторизация>.py:18`.

`raise web.HTTPForbidden(text=…)` в том же `auth_mw` (`web/mw.py:77`) ловится `exception_mw` и уходит
**конвертом** с `code: null` — то есть один middleware отдаёт отказ в двух форматах.

Следствие порядка middleware (выведено из кода, тестом не подтверждено): неизвестный маршрут без
заголовка пользователя получает `{"error": "Unauthorized"}` 401 из `auth_mw` раньше, чем 404;
с заголовком — конверт `{"status": "error", "data": {}, "code": null, "message": "404: Not Found"}`.

## 2. core-ex сейчас

### 2.1. Конверт успеха

`%{code, messages}` / `%{code, messages, data}` (`lib/core/web/response.ex:3`). Это map, отдаёт его
контроллер потребителя `json/2` (`lib/core/web/response.ex:24-26`; `docs/rules/app/15-web-api.md:171`).

| Функция | Тело | Ссылка |
|---|---|---|
| `success/0` | `{"code": 0, "messages": []}` — без ключа `data` | `lib/core/web/response.ex:174` |
| `success/1` | `{"code": 0, "messages": [], "data": …}` | `lib/core/web/response.ex:179` |
| `success/2` | `{"code": 0, "messages": ["…"], "data": …}` | `lib/core/web/response.ex:184-185` |

```json
{"code": 0, "messages": [], "data": {"id": "0190…", "name": "…"}}
```

HTTP-статус выбирает контроллер: 200; у команды event-sourced агрегата — 200 / 202 / 204 по
результату usecase (`docs/rules/app/15-web-api.md:229-235`). Создание state-stored агрегата — `{id}`
в `data` (`docs/rules/app/15-web-api.md:172-185`).

Ключи данных — camelCase (`docs/rules/app/15-web-api.md:331`), формат значений — кодек `OutCodec`
(`docs/rules/app/15-web-api.md:332`).

Тесты: `test/core/web/response_test.exs:35-45`.

### 2.2. Конверт ошибки

`error/2,3` → `{"code": <int>, "messages": [<string>, …]}` (+ `data` у `error/3`); строка
заворачивается в список, пустой список — `FunctionClauseError` (`lib/core/web/response.ex:190-205`).

Коды `Core.Web.Response.Code` (`lib/core/web/response/code.ex:23-30`):

| Значение | Код |
|---|---|
| `:success` | 0 |
| `:error` | 1 |
| `:domain_error` | 2 |
| `:diff_version` | 3 |
| `:auth_error` | 8 |
| `:critical` | 9 |

`0..9` зарезервированы за библиотекой (`lib/core/web/response/code.ex:32`); словарь потребителя —
`Core.Enum` с **целочисленными** кодами, покрывающий базовые; нарушение — `CompileError`
(`lib/core/web/response.ex:161-169`, `:217-264`).

Статусы — `Core.Web.ErrorMapper.map/2` → `{статус, код, текст, уровень лога}`
(`lib/core/web/error_mapper.ex:76-103`; таблица — `docs/rules/10-architecture.md:176-183`):

| Ошибка | HTTP | Код | Текст |
|---|---|---|---|
| `%Error{kind: :domain, code: :version_mismatch}` | 412 | 3 `:diff_version` | `message` |
| `%Error{kind: :domain, code: :access_denied}` | 403 | 1 `:error` | `message` |
| `%Error{code: c}`, `c` в `auth_codes:` | 401 | 8 `:auth_error` | константа `"Не авторизован"` |
| `%Error{kind: :domain}` (в т. ч. `:not_found`) | 400 | 2 `:domain_error` | `message` |
| `%Error{kind: :app}` | 500 | 9 `:critical` | `"Произошла непредвиденная ошибка"` |
| не `%Error{}` | 500 | 9 `:critical` | то же |

Константы — `lib/core/web/error_mapper.ex:30-32`. Текст — `to_string(error)`: `message`, а при
пустом — `"ns/code"` (`lib/core/error.ex:426-432`). Доменный `:not_found` — 400, а не 404,
намеренно (`docs/rules/10-architecture.md:187-193`).

```json
{"code": 2, "messages": ["Значение не найдено"]}
```

```json
{"code": 8, "messages": ["Не авторизован"]}
```

```json
{"code": 9, "messages": ["Произошла непредвиденная ошибка"]}
```

Множество ошибок (`Error.many`): маппер видит контейнер как одну ошибку; состав подставляет
fallback-контроллер потребителя через `Error.messages/1` — **только** на `:domain_error`, иначе
константа (`docs/rules/12-errors.md:212-230`; `lib/core/error.ex:423-424`). Состав — плоский список
строк без привязки к полю:

```json
{"code": 2, "messages": ["имя пусто", "срок в прошлом"]}
```

Тест: `test/core/web/response_test.exs:80-94`.

Чего нет: `code`/`ns`/`detail` ошибки клиенту не уходят — маппер отдаёт только `to_string(error)`
(`lib/core/web/error_mapper.ex:78-95`, `lib/core/error.ex:426-432`; цепочку не отдавать —
`docs/rules/12-errors.md:142`); ошибок по полям нет; `data` у ошибки маппер не формирует —
`error/3` есть, но заполнять его нечем, кроме ручного вызова. Ошибки разбора параметров —
обычные доменные: `:missing_param` / `:current_not_allowed` с `ns: :web` и `detail: key`
(`lib/core/web/params.ex:134-150`) → 400 `:domain_error`, имя поля только в тексте.

Ошибку, не дошедшую до контроллера (маршрут, тело, плаг, исключение), потребитель MUST отдавать тем
же конвертом (`docs/rules/app/15-web-api.md:312-314`).

Тесты маппера: `test/core/web/error_mapper_test.exs:15-81`.

### 2.3. Пагинация

`page_data/2` → `%{count, items}`, кладётся в `success/1` — метаданные внутри `data`
(`lib/core/web/response.ex:210-213`; `docs/rules/app/15-web-api.md:335`). `count` — размер всей
выборки (`lib/core/pagination/result.ex:9`, `:25-27`). Вход — `limit`/`offset`
(`lib/core/web/params.ex:59-64`), `limit` по умолчанию 10, `1..100`
(`lib/core/web/params.ex:19`, `lib/core/pagination.ex:15-18`).

```json
{"code": 0, "messages": [], "data": {"count": 2, "items": [{"id": "…"}]}}
```

Тест: `test/core/web/response_test.exs:164-169`.

### 2.4. Пустой ответ

- `success/0` → `{"code": 0, "messages": []}` — без `data` (`lib/core/web/response.ex:174`).
- Пакетная команда с пустым пакетом — 204 без тела (`docs/rules/app/15-web-api.md:235`, `:250-252`).
- Команда без ожидания проекции — 202 с `{id, version}` схемой `Written`
  (`docs/rules/app/15-web-api.md:229-233`, `:253-254`); оборачивается ли `Written` в конверт,
  библиотека не фиксирует — хелпер `MyAppWeb.Accepted` у потребителя.
- `Core.Web.Prefer` на тело не влияет: только режим ожидания и заголовок `Preference-Applied`
  (`lib/core/web/prefer.ex:116-140`).

## 3. Расхождения: core-ex сейчас → образец

| Аспект | core-ex сейчас | Образец |
|---|---|---|
| Признак успеха в теле | `code: 0` (число) | `status: "ok"` / `"error"` (строка) |
| Код ошибки | `code` — целое из `Core.Enum`, всегда есть | `code` — строка (`"bad_request"`, `"not_found"`, свои), у большинства ошибок `null` |
| Текст | `messages` — список строк, есть и в успехе | `message` — одна строка, только в ошибке; ключа нет, если текст пуст |
| `data` в успехе | есть только у `success/1,2` | есть всегда, `None` → `{}` |
| `data` в ошибке | только у `error/3`, маппер не заполняет | есть всегда, `{}` по умолчанию; валидация — `{"fields": …}` |
| Ошибки валидации | плоский `messages` без полей | `data.fields`: `{поле: [тексты]}`, вложенно, индексы — строковые ключи, `_schema` для уровня схемы; плюс второй формат — строка в `message` с 424 |
| Множество ошибок | `messages: [...]` через `Error.messages/1` на `:domain_error` | аналога нет: либо `fields`, либо одна строка |
| Доменный отказ | 400 `:domain_error` | 409 (конфликт бизнес-правила, свой `code` или `null`), 400 (неверный ввод) |
| Не найдено | 400 `:domain_error` (намеренно) | 404 |
| Нет прав | 403 `:error` | 403 `"forbidden"`/`null`, либо `{"error": "Forbidden"}` из middleware |
| Не авторизован | 401 `:auth_error`, константа `"Не авторизован"` | 401 `{"error": "Unauthorized"}` (middleware) либо конверт `"not_authorized"`/`"Not authorized"` |
| Конфликт версии | 412 `:diff_version` | аналога нет |
| Сбой внешней зависимости | 500 `:critical` | 424, текст причины наружу (`"424: …"`) |
| Непредвиденная ошибка | 500 `:critical`, `"Произошла непредвиденная ошибка"` | 500 `"internal_error"`, `"Internal Error"` |
| Пагинация | `data: {count, items}`, хелпер `page_data/2` | `data: {items, total}`, хелпера нет, `total` не у всех |
| Пустой успех | `{"code": 0, "messages": []}` без `data`; 204 у пустого пакета | `{"status": "ok", "data": {}}` 200; 204 нет |
| Создание | `{id}` в `data`; у event-sourced — представление 200 / `{id, version}` 202 | сущность или `{}` в `data`, 200; 201/202 нет |
| Ключи данных | camelCase | snake_case |
| Расширение кодов | `use Core.Web.Response, codes:` — целые вне `0..9`, проверка на компиляции | подкласс `Error` с полями `status`/`code`/`message` |

## 4. Открытые вопросы

1. **Какой формат считать образцом.** В образце их минимум пять: конверт веб-библиотеки,
   `{"error": "..."}` из middleware авторизации, `text/plain`, `{"success": true}` и форматы
   внешних вебхуков, сквозные тела прокси. Код не говорит, какой канонический; тесты закрепляют
   и конверт, и `{"error": …}`.
2. **`code` строкой или числом.** Образец — строка или `null`; core-ex требует целые коды
   (`lib/core/web/response.ex:217-224`) и резервирует `0..9`. Переход на строки ломает словари
   всех потребителей и проверку `ensure_integer_codes!`. Нужна ли таблица соответствия
   (`:domain_error` → `"bad_request"`? `"conflict"`?) и допустим ли `code: null`.
3. **`message` против `messages`.** Одна строка в образце; куда девать состав `Error.many` —
   склеивать, класть в `data`, отдавать первый элемент?
4. **Ошибки по полям.** Образцу нужен `data.fields` с путём до поля; в `%Error{}` пути поля нет
   (`detail` — произвольный term, наружу не уходит). Нужен новый контракт: откуда брать путь
   (`detail`? новое поле? элементы `errors` с ключом?) и как раскрывать вложенные списки
   (строковые индексы, как у marshmallow).
5. **Статусы.** Образец отдаёт 404 на «не найдено» и 409 на бизнес-конфликт; core-ex сознательно
   держит доменный `:not_found` в 400 (`docs/rules/10-architecture.md:187-193`) и не имеет 409.
   Меняется ли таблица маппера или это остаётся клозами потребителя.
6. **424 и текст причины.** Образец отдаёт 424 со строкой сбоя внешней системы, включая имя типа
   исключения (`<модуль-6>/views/base_view.py:84-89`); в core-ex прикладная ошибка — 500 с константой,
   текст наружу MUST NOT (`docs/rules/10-architecture.md:185-186`). Переносить ли 424 и в каком виде.
7. **Префикс `"NNN: "` в `message`.** Артефакт aiohttp при `reason=` без `text=`; воспроизводить ли.
8. **`data: {}` в ошибке и пустом успехе.** Всегда ли отдавать `data`, даже пустым, — образец да.
9. **`status` дублирует HTTP-статус** (`"ok"`/`"error"`); при этом в образце нет 202/204 — как
   выглядит тело 202 (`Written`) и остаётся ли 204 без тела для пустого пакета.
10. **`messages` в успехе** (`success/2`, предупреждения о частичном результате) — в образце места
    нет; убрать или перенести в `data`.
11. **`count` → `total`.** Переименование ключа страницы; отдавать ли `limit`/`offset` обратно
    (образец не отдаёт); вход `page`/`size` в образце тоже встречается.
12. **Тексты по умолчанию.** Образец — английские (`"Internal Error"`, `"Not authorized"`), core-ex —
    русские константы маппера.
13. **412 `:diff_version`** в образце аналога не имеет (оптимистичной блокировки нет) — какой
    строковый `code` ему дать.
14. **Регистр ключей данных** (camelCase в core-ex против snake_case в образце) — часть конверта или
    вне задачи.
15. **Формат дат** в образце зависит от пути (unix-timestamp через энкодер против ISO через схему);
    брать ли что-то из этого или оставить кодекам core-ex.
