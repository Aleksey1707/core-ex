# Связи event-sourced агрегата

Type: wayfinder:map

## Destination

Новый ADR «Связи event-sourced агрегата» и `.scratch/aggregate-wiring/spec.md`, готовый к `/to-tickets`.
- ADR фиксирует единственный источник связей «агрегат → кодек → id / by / тип / семейство», направление
  ссылок и опции `use`, которые уходят.
- Спек содержит пункт CHANGELOG «было → стало».
- Кода в карте нет.

Источник — тикеты ревью «Связи агрегата вычисляются один раз» (`.scratch/builders-review/issues/07-aggregate-wiring.md`)
и «Событие: `aggregate_id`/`by` на семейство» (`.scratch/builders-review/issues/08-event-family-id-by.md`).

## Notes

- В рамках восемь билдеров: `Es.Aggregate.Repo`, `Repo.Pg`, `Process`, `KeyReservation`, `Es.Outbox`, `Projection`,
  `EventCompatCase`, `Es.Event.Codec` (`derive!`); плюс `Es.Event` (`aggregate_id:` / `by:`).
- Ломка разрешена одним выпуском. Режим перехода выбирает отдельный тикет.
- Жёсткие ограничения:
  - литеральные головы, `@callback` и `@type` с id агрегата остаются (ADR-0014). Билдер с такой головой
    знает id при раскрытии `use` — из опции или из модуля, который грузится без взаимного ожидания;
  - связанный модуль задаётся только явной ссылкой: опцией `use` или функцией загружаемого модуля. Не
    соглашением об именах (`Module.split` / `Module.concat`). DI `<Behaviour>.Pg` во время выполнения
    вне рамок;
  - `Core.Es.Outbox` общий со state-stored путём: решение для него работает у обоих, опции
    `Repo.Pg.StateStored` не меняются.
- Своды каждой сессии: skills `domain`, `repos`, `events-outbox`, `projections`. ADR-0014, разделы
  «Полнота» и «Результат `decide`».
- Новое ребро компиляции проверяется прототипом на копии `fixtures/consumer` (временная ветка или
  копия), а не рассуждением. Основное дерево `lib/` в рамках карты не правится.
- О потребителях — только обезличенно («потребитель A»).

## Decisions so far

- [Граф связей и компиляции сейчас](issues/01-wiring-inventory.md): кодек — единственный, кто знает id, семейство,
  тип и события; связи держатся на сверках задним числом и рефлексии, которую xref не видит. Ожидания
  нет только из-за `Account` → кодек атомом; цикл перекомпиляции агрегат ↔ кодек ↔ события уже есть.
- [Где семейство объявляет `aggregate_id` и `by`](issues/02-family-declaration.md): на семействе —
  `use Core.Es.Event.Family, aggregate_id:, by:`; событие ссылается `family:`, кодек берёт значения у
  семейства и сверяет принадлежность событий, `derive!` уходит. Все события одним выпуском.
- [Прототип объявления семейства на копии фикстуры](issues/03-family-prototype.md): собирается без взаимного
  ожидания, `consumer-check` проходит, головы `new` ловят чужой id; новое xref-ребро событие → семейство,
  семейство вошло в цикл перекомпиляции агрегата (7 → 8). Ветка `prototype/family-declaration`.
- [Единственный источник связей и направление ссылок](issues/04-wiring-source.md): хаба нет — цепочка
  агрегат → кодек → семейство, у каждого факта один владелец; `Repo` теряет `id:`, `Repo.Pg` — `aggregate:` и
  `id:`; у кодека и `Outbox` `event:` → `family:`; `Process`, `EventCompatCase`, агрегат не меняются.
- [Прототип репозитория без `id:` / `aggregate:`](issues/05-repo-prototype.md): собирается, `consumer-check`
  проходит, головы ловят чужой id; из xref ушло только `repo/pg.ex → <agg>.ex`, перекомпиляция та же, и при ID
  в отдельном файле. `ensure_aggregate_id!` остаётся у `StateStored`. Ветка `prototype/repo-wiring`.
- [Откуда модуль ключа берёт семейство и id](issues/06-key-reservation-source.md): ключ ссылается `aggregate:`,
  `event:` / `id:` уходят; полноту `reservation/1` проверяет сам ключ, `Repo.Pg` сверяет только агрегат ключа,
  `code:` и области. Ревью 10 поглощено.
- [Агрегат и кодек проекции без соглашения об именах](issues/07-projection-source.md): кодек и агрегат — ссылками
  семейства `codec:` / `aggregate:` (атомы, сверяют кодек и билдер репозитория); `await` прежний — агрегат первым
  аргументом во всех формах, литерал из `aggregate:` семейства (пересмотр 2026-10-24: формы без агрегата отменены).
- [Прототип проекции с кодеком из семейства и `await` по ID](issues/09-projection-prototype.md): собирается,
  `consumer-check` проходит, обе сверки дают `CompileError`; формы `await` без агрегата отменены пересмотром тикета 07.
  Правка кодека перекомпилирует проекцию и без агрегата. `codec:` раскрывается как runtime-ссылка (иначе цикл
  семейство ↔ кодек). Ветка `prototype/projection-wiring`.
- [Прототип модуля ключа с `aggregate:`](issues/08-key-reservation-prototype.md): собирается, `consumer-check`
  проходит, `find/2` ловит чужой id; неполный `reservation/1` — предупреждение на `use` ключа, ключ чужого агрегата
  в `Repo.Pg` — `CompileError`; из xref ушло ключ → семейство, перекомпиляция та же. Ветка
  `prototype/key-reservation-wiring`.
- [Режим перехода на новые опции](issues/10-transition-mode.md): сразу `CompileError` одним выпуском, текст общий —
  переход описывают CHANGELOG и «Версия библиотеки»; `Opts.validate!` сообщает недостающие и неизвестные опции одной
  ошибкой; `await` не ломается.
- [Прототип `aggregate:` у семейства](issues/12-family-aggregate-prototype.md): вариант Б (runtime-ссылка) — xref и
  перекомпиляция как у базы; `await` с агрегатом из семейства, общий ID собирается. Владельца сверяют `Repo.Pg` и
  `StateStored` (`CompileError`), семейство — `@after_verify` с `IO.warn`; `Es.Aggregate` не сверяет. `Catalog` в
  `test/support` придётся отделить от state-stored. Ветка `prototype/family-aggregate`.
- [Форма ADR и спека](issues/11-adr-spec-shape.md): ADR-0084 самодостаточен, ADR-0014 уточняется строкой в шапке;
  один пункт CHANGELOG в «Изменениях контракта макросов», четыре строки «Версии библиотеки»; срезы `Opts` → семейство
  → репозиторий / ключ / проекция, каждый правит свои своды; `@after_verify` — только для ссылок семейства. В
  `CONTEXT.md` — «Владелец потока».
- [Запись ADR-0084 и спека](issues/13-write-adr-spec.md): ADR-0084 (`docs/adr/0084-aggregate-wiring.md`) и строка в
  шапке ADR-0014 записаны; `spec.md` готов к `/to-tickets` — пять срезов, текст пункта CHANGELOG, строки «Версии
  библиотеки».

## Not yet specified

## Out of scope

- Одна ветка `quote` в шаблоне события (`Es.Event`, `if is_nil(payload_mod)`): внутренний рефакторинг без
  ломки, отдельный тикет ревью `.scratch/builders-review/issues/14-event-template-one-branch.md`.
- Сверки `id:` / `aggregate:` у репозитория в текущем контракте: отдельный тикет ревью
  `.scratch/builders-review/issues/13-aggregate-wiring-checks.md`, выпускается независимо.
- Отказ от литеральных голов (ADR-0014).
- Опции `Repo.Pg.StateStored`, DI `<Behaviour>.Pg`.
