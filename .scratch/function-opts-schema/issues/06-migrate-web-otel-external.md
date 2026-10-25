# 06: Перевод на схему — web, трассировка, внешние вызовы

**What to build:** функции границы HTTP, трассировки и внешних вызовов отклоняют опечатку в
опциях `ArgumentError`, а их опции описаны в `@doc` из схемы.

Спека — «Объём перевода», волна 1.

**Blocked by:** 02

**Status:** resolved

- [x] Классифицированы и переведены `Web.ErrorMapper` (`map`, `unauthorized`, `critical`,
      `by_status`, `cast_errors`), `Web.Params.page`, `Otel` (`span`, `root_span`,
      `with_span_from`), `Otel.Messaging` (`create`, `send`, `process`), `External.call`; функция,
      передающая опции насквозь (в OpenTelemetry, в соседнюю функцию модуля), — без схемы, с
      обоснованием в `## Comments`.
- [x] Ручная проза об опциях в `@doc` переведённых функций убрана.
- [x] Тесты модулей: по одной проверке «неизвестный ключ → `ArgumentError`»; остальные зелёные.
- [x] CHANGELOG: переведённые публичные функции добавлены в список пункта «Ломающие изменения
      контракта».
- [x] `make` зелёный.

## Comments

- Свои ключи, схема: `Web.ErrorMapper.map/2`, `unauthorized/1`, `critical/1`, `by_status/2`,
  `cast_errors/2`, `Web.Params.page/2`, `Otel.Messaging.create/4`, `External.call/4`.
- `Web.ErrorMapper`: ключи общие у нескольких функций, поэтому схема собрана из атрибутов
  `@auth_opts` / `@unauthorized_opts` / `@critical_opts`. `map/2` и `by_status/2` больше не зовут
  публичные `unauthorized/1` / `critical/1` (их схема отклонила бы чужие ключи вроде `auth_codes:`),
  а идут в приватные `unauthorized_error/1` / `critical_error/1` блока «общее»: опции уже проверены
  один раз. `by_status(5xx кроме 500)` сбрасывает `error_id:` в `nil` вместо `Keyword.delete`:
  тело читает его `Keyword.fetch!`.
- `Web.ErrorMapper`: схема у каждой функции своя, по составу ключей `10-architecture.md`,
  «Граница HTTP», а не общая на модуль. Цена: общий список опций маппера приложения, переданный
  целиком в `critical/1` / `unauthorized/1` / `by_status/2`, теперь отклоняется (`auth_codes:` там не
  действовал) — это и есть «ключ, который не действовал» спеки; правка потребителя (`Keyword.take`)
  записана в CHANGELOG. Общая схема на модуль приняла бы `auth_codes:` у `critical/1` молча.
- `Otel.Messaging.create/4`: умолчаний у ключей нет — их читает общий с `send/5` / `process/5`
  приватный `attributes/3`, а у тех схемы нет (ниже). `attributes:` — `{:map, :string, :any}`:
  имена атрибутов строковые.
- `External.call/4`: ручной `classifier!/1` с `raise ArgumentError` снят — `outcome:` обязательный
  ключ `{:fun, 1}`; `@spec` — `keyword()` вместо `[outcome: …]` (правило «тип опций — `keyword()`»).
- Без схемы:
  - `Otel.root_span/3` — передаёт опции насквозь в соседний `Otel.span/3`.
  - `Otel.span/3`, `Otel.with_span_from/4`, `Otel.Messaging.send/5`, `Otel.Messaging.process/5` —
    опции у них не последний аргумент (за ними колбэк `fun`), а `Core.Options` проверяет только
    последний аргумент функции. Перестановка аргументов сломала бы всех вызывающих. Кроме того,
    `Otel.span/3` — горячий путь: `Otel.Es` и `Otel.External` зовут его на каждую команду, пачку
    проекции и внешний вызов с непустыми опциями (`attributes:`), и схема гнала бы NimbleOptions
    на каждом span'е. Ключи `Otel.span/3` переводятся в опции `:otel_tracer` (`kind`, `attributes`,
    `links`, `scope`) — это граница OpenTelemetry. Если их всё же нужно закрыть схемой — нужна
    поддержка опций не последним аргументом в `Core.Options` (вне этого тикета); иначе
    `CredoChecks.OptsSchema` (тикет 11) должен их пропускать.
  - Отступление записано в `docs/rules/DEBT.md`, «Опции функций `lib/` мимо схемы».
- Пересмотрено после тикета 10 (решение пользователя): опции `Otel.span/3`, `root_span/3`,
  `with_span_from/4`, `Otel.Messaging.send/5`, `process/5` перенесены после колбэка —
  `…, fun, opts \\ []`, как требует `20-agreements.md`, «Context — последний из данных»
  (`…, context, fun, opts \\ []`). Поддержка опций не последним аргументом в `Core.Options` не
  нужна: свод и так ставит опции в хвост, а второй способ найти опции (по позиции) усложнил бы
  подмену `def` ради одного модуля. Цена — ломающее изменение у вызывающих (CHANGELOG, строка
  было → стало), его принял пользователь; в `lib/` вызовов шесть, в тестах — механическая замена.
- Схему получили функции, которые читают свои ключи: `span/3`, `with_span_from/4` — общий
  `@span_opts_schema` с умолчаниями (`kind: :internal`, `attributes: %{}`, `links: []`,
  `scope: Core.Otel`), тело читает `Keyword.fetch!/2`; `Messaging.send/5`, `process/5` — общий с
  `create/4` `@operation_opts_schema`. `root_span/3` — насквозь в `span/3`, без схемы: отказ
  называет `Core.Otel.span/3`. Типы `Otel.start_opts/0` и `Otel.Messaging.opts/0` сняты: тип опций
  в `@spec` — `keyword()`, состав — раздел «Опции» из схемы.
- Горячий путь: `Otel.Es` и `Otel.External` зовут `span/3` с непустыми `attributes:`, и такой вызов
  проходит NimbleOptions на каждом span'е — принято пользователем: проверка — микросекунды против
  записи span'а и работы под ним. `Messaging.send/5` / `process/5` проверяют опции дважды (своя
  схема и схема `span/3` / `with_span_from/4` на собранных `span_opts`) — по разу на пачку
  поллера и на сообщение подписчика.
- Запись об Otel в `docs/rules/DEBT.md` снята.
