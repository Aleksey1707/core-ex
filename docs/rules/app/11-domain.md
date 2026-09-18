# Домен приложения

- **Область.** `lib/my_app/codec/**`, `lib/my_app/domain/**`: профили и фасады Codec, реестр
  плагинов, агрегаты и их Prim, справочники, сборка `%Context{}`.
- **Читать перед.** Новым Prim, Enum, кодеком или агрегатом; правкой профилей Codec и реестра
  плагинов; правкой `ContextFactory`.
- **Словарь.** Плейсхолдеры и модальность — `deps/core/docs/rules/00-index.md`.

Контракты `Core.Prim`, `Core.Enum`, `Core.Codec.*`, `Core.View`, `Core.Es.Aggregate`,
`Core.Es.Cmd`, `Es.Event`, `Version` и `Context` нормирует `deps/core/docs/rules/11-domain.md`:
там опции макросов, конвейер `cast → mutate → validate`, приоритеты dump/load, формы `decide` /
`evolve` и требования к описанию значений enum.
Здесь — как это собирается в приложении.

## Профили Codec

Профилей Prim — ровно два, оба объявлены `use Core.Codec`:

| Профиль | Где применяется | Что задаёт |
|---|---|---|
| `MyApp.Codec.Prim.Internal` | БД, outbox, MQ, события | форму хранения: `uuid: :full`, `datetime: :datetime`, `datetime_tz: "Etc/UTC"`, `date: :date`, `decimal: :decimal` |
| `MyApp.Codec.Prim.External` | HTTP JSON | форму контракта: `uuid: :hex`, `datetime: :iso8601`, `datetime_tz: :app` либо `:keep`, `date: :iso8601`, `decimal: :string` |

- Момент времени MUST храниться в UTC, а наружу уходить в зоне приложения либо как записан
  (`datetime_tz:` внешнего профиля) — но не наоборот: приложение с локальной зоной в БД
  нельзя перевезти между площадками.
- Профиль SHOULD NOT переопределять `dump/1` и `dump_kind/2`: доменные значения укладываются
  в builtin-форматы. Переопределение plain-kind MUST быть идемпотентным — на read-пути оно
  ложится на значение, уже прошедшее dump (`deps/core/docs/rules/11-domain.md`).
- Третий профиль — признак того, что различие принадлежит не транспорту, а форме конкретного
  ответа: его место в презентере (`15-web-api.md`), а не в новом профиле.

## Фасады и реестр плагинов

Фасады — `MyApp.Codec.Internal` (алиас `InCodec`) и `MyApp.Codec.External` (`OutCodec`); список
плагинов у них **общий** — `MyApp.Codec.plugins/0`.

- Новый entity-кодек (`use Core.Codec.Plugin`) MUST попадать в `plugins/0`: фасад
  диспетчеризуется клоузами на модуль, и у незарегистрированного плагина их нет — `dump/1` его
  значения даёт предупреждение при сборке и `FunctionClauseError`, `load/2` — `ArgumentError`
  (`deps/core/docs/rules/11-domain.md`, «Codec (Prim и Entity)»).
- В реестре MUST быть `Core.Outbox.Codec` — иначе запись outbox не сериализуется.
- Вложенная сущность агрегата — тоже плагин реестра, а не приватный хелпер внутри кодека
  агрегата: иначе её форму нельзя ни переиспользовать, ни покрыть round-trip-тестом.
- Кодеки представлений (`<Aggregate>.View.Codec`) генерирует `use Core.View`, кодеки событий —
  `use Core.Es.Event.Codec`; оба регистрируются наравне с остальными.
- Вызовы идут **только** через фасад: `codec.dump(value)` внутри плагина, `InCodec` / `OutCodec`
  снаружи. Обращение к соседнему `*.Codec` напрямую — MUST NOT
  (`deps/core/docs/rules/11-domain.md`, «Dump/load только через фасад»).

Событие — обычная сущность фасада: `InCodec.dump(event)` отдаёт конверт целиком,
`InCodec.load(<Aggregate>.Event, wire)` восстанавливает его по тегу внутри конверта.

## Агрегаты

Вид агрегата — state-stored или event-sourced — выбирается на агрегат (`13-repos.md`, «Вид
агрегата»); контракты обоих (`Version`, `decide` / `evolve`, черновики событий, `id` / `version`,
команда `use Core.Es.Cmd`) нормирует `deps/core/docs/rules/11-domain.md`, «Aggregates». Общее
для обоих:

- домен MUST NOT писать в БД, брокер или очередь — только менять состояние и отдавать события;
  persist — задача репозитория;
- поля аудита (`created_at`, `created_by`, `updated_at`, `updated_by`, `deleted_at`,
  `deleted_by`) MAY; нормирован только их порядок при сборке struct
  (`deps/core/docs/rules/20-agreements.md`, «Сборка struct»).

### State-stored

- Мутация — функция агрегата: возвращает `{:ok, %Agg{}} | {:error, Error.t()}` и копит событие в
  `events`; сбрасывает их в хранилище репозиторий, в той же транзакции, что и состояние.
- Удаление — soft-delete парой `deleted_at` / `deleted_by`, если строку нужно пережить.
- Агрегат **без событий** заводится осознанно и MUST иметь записанную причину: производность от
  чужого события, собственный жизненный цикл вложения, объём fan-out.

### Event-sourced

`use Core.Es.Aggregate, event_codec:` — приложение пишет `decide/2` и `evolve/2`, свёртку и
`execute/2` даёт библиотека; их контракт — `deps/core/docs/rules/11-domain.md`, «Event-sourced».

- Автор и момент изменения лежат в `by` / `at` событий: поля аудита в состоянии не нужны, а
  soft-delete к агрегату не применяется — удаление является доменным событием.
- Конверсия момента события в Prim состояния внутри `evolve/2` — bang
  (`deps/core/docs/rules/20-agreements.md`, «Safe vs bang»).

### Команда

Команда event-sourced агрегата — `<Aggregate>.Cmd.<Name>` (`use Core.Es.Cmd`); её контракт
(`by` и `at` в `@enforce_keys`) — `deps/core/docs/rules/11-domain.md`, «Команда».

Собирает команду usecase: `by` — из `CurrentUser.get(context)`, `at` — из текущего времени
(`Es.Event.At.now/0` либо момента внешнего источника). Брать автора внутри `decide` из контекста
MUST NOT: домен контекста не знает.

## Prim и Enum

- Prim объявляются **вложенными модулями** внутри владельца значения — агрегата
  (`<Aggregate>.ID`, `<Aggregate>.Name`) или модуля, которому значение принадлежит.
  Отдельный namespace «все примитивы приложения» MUST NOT: значение без владельца теряет
  инварианты.
- Чувствительное значение объявляется `sensitive: true` (`12-errors.md`).
- Справочник **внешнего** источника объявляется `Core.Enum` с `codes:` — картой «значение →
  код источника». Карта соответствий рядом с модулем MUST NOT: она разойдётся со словарём.
- Собственный словарь домена объявляется через `values:`: кода у него нет и быть не должно.
- Описание значений enum в `@moduledoc` — `deps/core/docs/rules/11-domain.md`, «Описание
  значений в `@moduledoc`». Проверяется: ратчет описаний enum `use Core.Enum.DocsCase`
  (`19-testing.md`, «Ратчеты»).
- Guard'ы в заголовках — `Core.Guard` через `import` (`is/2`, `is_opt/2`, `is_enum/2`,
  `in_enum/3`), а не россыпь `is_*` (`deps/core/docs/rules/20-agreements.md`).

## Context

App-код собирает контекст **только** через `MyApp.ContextFactory`:

| Функция | Когда |
|---|---|
| `sc/0` | контекст с инициализированным shadow copy, без пользователя |
| `as_user/1` | контекст с `Sc` и текущим пользователем |
| `anonymous/0` | анонимный вызов |
| `system/0` | фоновая работа от системной учётной записи |
| `empty/0` | без `Sc` и без пользователя |

Текущий пользователь адресуется аксессором (`use Core.Context.Accessor`), а не ключом map.

### Время жизни `Repo.Sc`

Контекст владеет ETS-таблицей эталонов `Core.Repo.Sc`. Она MUST NOT переживать единицу работы:

| Вызывающий | Что делает |
|---|---|
| web-запрос | плаг кладёт контекст, `before_send` зовёт `Sc.delete/1` |
| воркер, подписчик, mix-таска | контекст на единицу работы (задача, сообщение, прогон) |
| долгоживущий процесс с контекстом из `init/1` | `Sc.clear/1` после каждой единицы работы |

Долгоживущий контекст без очистки растёт весь срок жизни процесса и отдаёт write-репозиториям
устаревшие эталоны — то есть немой пропуск `update` вместо записи
(`deps/core/docs/rules/20-agreements.md`, «Load/save агрегата»).

## Связанные правила

- Слои и usecases — `10-architecture.md`
- Ошибки и чувствительные данные — `12-errors.md`
- Persist агрегатов, View и Specs — `13-repos.md`
- События и совместимость wire-формата — `14-events-outbox.md`
- Презентеры и внешний профиль — `15-web-api.md`
- Тесты кодеков и справочников — `19-testing.md`
