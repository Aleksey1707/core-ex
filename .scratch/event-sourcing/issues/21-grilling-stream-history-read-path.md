# История потока на read-пути

Type: grilling
Status: resolved
Map: [Event-sourced агрегат в :core](../map.md)

## Question

Как потребитель показывает историю потока — экран изменений агрегата — после удаления `list_by_aggregate` /
`count_by_aggregate` / `page_by_aggregate` у обоих видов агрегатов:

- где живёт чтение: страница потока в `Core.Es.Store`, отдельный модуль библиотеки над `es_events` со своей схемой, как
  ReadRepo, или проекция истории, которую пишет потребитель;
- что отдаёт: `Es.Event` через `InCodec.load(Agg.Event, _)` или View из примитивных значений; как история уходит наружу
  через `OutCodec`;
- страница: `limit` / `offset` или курсор по версии, `count`, порядок; история нескольких типов агрегатов на одном
  экране;
- тег, неизвестный кодеку: `:unknown_event_type` на всю страницу, пропуск события или маркер нечитаемого;
- доступ: где проверяется, что пользователь из `Context` видит этот агрегат, если чтение идёт по одному `aggregate_id`;
- место в `13-repos.md` вместо разделов «Role Repo vs common Repo.Pg vs Event.Repo» и «Event store».

## Answer

- **Чтение** — `Core.Es.Store.page_stream(Agg.Event.Codec, %Agg.ID{}, %Limit{}, %Offset{}, context)` →
  `{:ok, Pagination.Result.t(Es.Event)}` у обоих видов агрегатов; usecase зовёт напрямую; тип агрегата — `type:` кодека,
  семейство событий — из кодека. Билдер `<Agg>.History` с DI, ReadRepo над `es_events` и проекция истории отвергнуты.
- **Страница** — строки грузятся фасадом `InCodec.load(Agg.Event, wire)` с апкастом; наружу — презентер потребителя
  `OutCodec.dump` → `Es.Event.Codec.to_fields/1` (остаётся публичной). Не View: Prim события не ужесточается
  ([ADR-0010](../../../docs/adr/0010-event-evolution-tag-upcast.md)), проверенное на записи событие грузится.
- **Форма** — `Pagination.Limit` / `Offset`, `count` всего потока, по возрастанию `aggregate_version`, без
  `xid < pg_snapshot_xmin`: порядок внутри потока держит версия. Курсор по версии и выбор направления отвергнуты.
- **Нечитаемое событие** — первая ошибка `load` (`:unknown_event_type`, `:invalid_envelope`) на всю страницу через
  `Result.traverse`, без `raise`, HTTP 400 `:domain_error`; пропуск события и маркер нечитаемого отвергнуты.
- **Доступ** — `page_stream` доступ не проверяет и `:not_found` не отдаёт: пустой поток — пустая страница (`count: 0`).
  Usecase MUST до чтения проверить права по `Context` и существование агрегата через
  `ReadRepo.get(id, :current, context)`; у event-sourced агрегата без проекции — только роли.
- **Несколько агрегатов или типов на экране** — проекция потребителя (`use Core.Es.Projection, events:`) и ReadRepo над
  ней, фильтры там же; хранилище не даёт.
- **Сигнатура** — `context` последний из данных, в функции не используется; `opts`, span и telemetry нет — как у чтений
  `Repo.Pg` и восстановления агрегата.
- **Тесты** — `Core.Es.Store.Test.events!(Agg.Event.Codec, %Agg.ID{})` в `lib/`: `[Es.Event]` всего потока через фасад
  по возрастанию версии, ошибка `load` — `raise`.
- **Слова** — в библиотеке «страница потока» / «чтение потока»; «история» — имя экрана потребителя. `CONTEXT.md` не
  меняется.
- **`CHANGELOG.md`** — к пункту об удалённом триплете из
  [«Контракт state-stored агрегата поверх общей таблицы событий»](16-grilling-state-stored-shared-event-table.md):
  `@event_repo.page_by_aggregate(id, limit, offset, context)` →
  `Core.Es.Store.page_stream(Agg.Event.Codec, id, limit, offset, context)`; в тестах `list_by_aggregate` →
  `Core.Es.Store.Test.events!/2`; норма проверки доступа до чтения.
- **Своды** — содержание норм и уход разделов «Event store» и строки `Event.Repo` из `13-repos.md` — в
  [«Раскладка сводов `docs/rules` под event sourcing»](22-grilling-rules-layout.md); страница потока нужна и
  state-stored потребителю.
- ADR не заводится: откат — одна функция. Не проверено на нагрузке: `offset` и `count` на длинном потоке.

## Comments

- 2026-09-13 — ограничения из закрытых тикетов и сводов:
  - [«Контракт репозитория event-sourced агрегата»](07-grilling-repo-contract.md): write-репозиторий отдаёт только `get`
    / `get_many` / `append`, история потока для экрана — read-путь;
  - [«Эволюция событий: где апкастится история»](09-grilling-event-evolution.md): апкаст действует везде, где грузит
    фасад, в том числе на экране истории; история не переписывается;
  - [«Контракт state-stored агрегата поверх общей таблицы событий»](16-grilling-state-stored-shared-event-table.md):
    триплет `Es.Event.Repo{,.Pg,.Pg.Schema}` и его чтения удалены у обоих видов агрегатов, замены нет; поток — тип
    агрегата и `aggregate_id` в `es_events`;
  - [«Пересборка проекций»](17-grilling-projection-rebuild.md): таблицу read-модели пишет одна проекция, ReadRepo MAY
    читать таблицы нескольких проекций;
  - `13-repos.md` сейчас: чтение истории — safe, неизвестный кодеку тег даёт доменную `:unknown_event_type` (HTTP 400),
    а не 500 на весь GET.
- 2026-09-13 — факты потребителей (`quality-control-back`, `gar-back`):
  - в `lib` — 13 вызовов, все `page_by_aggregate(id, limit, offset, context)` в `history/4` usecase'ов
    `quality-control-back` (User, Perm, Role, UserRoles, Delivery, VehicleInspection, Acceptance, ClaimAct,
    ItemInspection), 6 из них за HTTP `POST …/:id/history/search`; `list_by_aggregate` / `count_by_aggregate` и
    `:from_version` / `:to_version` в `lib` не зовёт никто, в `gar-back` чтений в `lib` нет;
  - доступ — `check_user([Ops.read()], context)` по ролям, затем `ReadRepo.get(id, :current)` (`not_found`,
    `not_deleted`); у `perms/admin/usecases/user_roles.ex` `get` нет — чтение по голому id; сам `page_by_aggregate`
    контекст игнорирует;
  - результат — `Pagination.Result` из `Es.Event` как есть; презентер `qc_web/presenters/event.ex`: `OutCodec.dump` →
    `Es.Event.Codec.to_fields` → `%{id, aggregateId, type, payload (camelize), at, by}`, ответ `{count, items}`, порядок
    по возрастанию версии, `limit` / `offset` в query;
  - истории нескольких агрегатов и фильтров (тип, дата, автор) нет, тело `SearchRequest` зарезервировано пустым;
  - `:unknown_event_type` уходит в HTTP 400 `:domain_error` через `Core.Web.ErrorMapper`; тестов на неё из истории нет;
  - `list_by_aggregate` зовут только тесты — проверить, что `append` записал события (`repo_test.exs` агрегатов,
    `acceptance/system/usecases/delivery_test.exs`, `gar-back/…/user/event/repo/pg_test.exs` — все три функции).
- 2026-09-13 — раунд 1:
  - чтение — функция хранилища `Core.Es.Store.page_stream(Agg.Event.Codec, %Agg.ID{}, %Limit{}, %Offset{}, context)`,
    usecase зовёт её напрямую; тип агрегата — `type:` кодека, семейство событий — из кодека; имя `page_stream`, а не
    `page`: у хранилища есть чтение по глобальной позиции; билдер `<Agg>.History` с DI отвергнут — возвращает хвост
    модулей, убранный в «Контракт state-stored агрегата поверх общей таблицы событий», ради одной функции; ReadRepo над
    `es_events` отвергнут — Redump-спек по тегу нет, апкаст мимо; проекция истории отвергнута — вторая копия `es_events`;
  - страница — `{:ok, Pagination.Result.t(Es.Event)}`, строки грузятся фасадом `InCodec.load(Agg.Event, wire)` с
    апкастом; презентер потребителя прежний (`OutCodec.dump` → `Es.Event.Codec.to_fields/1`, функция остаётся
    публичной); отступление от «read-путь → View» — в норме: Prim события не ужесточается, проверенное на записи событие
    грузится; View с Redump по тегу отвергнут;
  - форма — `Pagination.Limit` / `Offset`, `count` всего потока, порядок по возрастанию `aggregate_version`; фильтра
    `xid < pg_snapshot_xmin` нет — порядок внутри потока держит версия, иначе страница ждёт любую пишущую транзакцию
    кластера; курсор по версии и выбор направления отвергнуты; не проверено на нагрузке: `offset` и `count` на длинном
    потоке;
  - `page_stream` не проверяет доступ и не отдаёт `:not_found`: пустой поток — пустая страница (`count: 0`), поток
    state-stored законно пуст; usecase истории MUST до чтения проверить права по `Context` и существование агрегата через
    `ReadRepo.get(id, :current, context)` с его `default_filters`; у event-sourced агрегата построчный ACL — ReadRepo над
    проекцией, без неё — только роли и пустая страница; `:not_found` на пустом потоке и фильтр доступа в `page_stream`
    отвергнуты;
  - история нескольких агрегатов или типов на одном экране хранилищем не даётся — проекция потребителя
    (`use Core.Es.Projection, events:` из нескольких типов) и ReadRepo над ней, фильтры там же; список потоков в
    `page_stream` отвергнут.
- 2026-09-13 — раунд 2:
  - нечитаемое событие (окно поэтапной выкладки или ошибка программиста) — первая ошибка `load` (`:unknown_event_type`,
    `:invalid_envelope`) на всю страницу через `Result.traverse`, без `raise`, HTTP 400 `:domain_error` как сейчас;
    пропуск события (расходится `count`, молчаливая дыра) и маркер нечитаемого (новый вид элемента в API) отвергнуты;
  - проверка записанных событий в тестах — `Core.Es.Store.Test.events!(Agg.Event.Codec, %Agg.ID{})` в `lib/` рядом с
    `Core.Es.Aggregate.Test`: `[Es.Event]` всего потока через фасад по возрастанию версии, ошибка `load` — `raise`;
    `page_stream` в тестах и публичное чтение потока после версии отвергнуты;
  - место норм в своде решает [«Раскладка сводов `docs/rules` под event sourcing»](22-grilling-rules-layout.md), здесь —
    только содержание; ограничение для него: страница потока нужна и state-stored потребителю;
  - в библиотеке — «страница потока» / «чтение потока»; «история» — имя экрана потребителя (`CONTEXT.md`: у «Поток
    событий» _Avoid_ «история»); `CONTEXT.md` не меняется, термин «История агрегата» отвергнут;
  - `context` — последний аргумент из данных, в функции не используется, как у чтений ReadRepo; `opts`, span и telemetry
    нет — как у чтений `Repo.Pg` и восстановления агрегата; сигнатура без `context` и span `Core.Otel.Es` отвергнуты.
