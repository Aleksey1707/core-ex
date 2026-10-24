# Связи event-sourced агрегата: цепочка владельцев «агрегат → кодек → семейство»

Type: spec
Status: ready-for-agent

Решение и отвергнутые варианты — ADR-0084 (`docs/adr/0084-aggregate-wiring.md`); термины — `CONTEXT.md`, «Семейство
событий агрегата» и «Владелец потока». Решения и замеры — `.scratch/aggregate-wiring/issues/`.

## Problem Statement

Автор агрегата на `Core.*` называет одни и те же связи много раз. У агрегата счёта фикстуры-потребителя `Account.ID`
назван 9 раз: `aggregate_id:` в пяти событиях и `id:` в `Repo`, `Repo.Pg` и двух модулях ключа. Семейство названо
4 раза, модуль агрегата — дважды. Новое событие повторяет `aggregate_id:` / `by:`, новый ключ — `event:` / `id:`.

Библиотека держит эти повторы тремя способами, и у каждого своя цена:

- **сверки задним числом** (`derive!` кодека, `ensure_aggregate_id!`, сверки ключа в `Repo.Pg`) существуют только
  ради того, чтобы поймать расхождение копий;
- **дыры**: принадлежность событий кодека семейству не сверял никто; `aggregate:` / `id:` у `Repo.Pg` не сверялись
  с behaviour, а `id:` у behaviour — с кодеком; модуль ключа без репозитория не проверялся вовсе;
- **соглашение об именах**: `Projection` находит кодек как `<Family>.Codec`, а агрегат для `await` — как
  `Module.split(codec) -- 2`. Связь, которую не видят ни xref, ни автор, ломается переименованием.

## Solution

У каждого факта один владелец (ADR-0084):

- семейство `use Core.Es.Event.Family` владеет `aggregate_id` и `by` и называет владельца потока (`aggregate:`) и
  кодек (`codec:`) — атомами без загрузки;
- событие ссылается на семейство `family:`; кодек и `Outbox` — тоже `family:`;
- агрегат называет кодек (`event_codec:`, как сейчас);
- `Repo` указывает на агрегат, `Repo.Pg` — на behaviour, модуль ключа — на агрегат. Остальное билдеры берут
  рефлексией при раскрытии `use` и запекают литералами, как требует ADR-0014.

Опции-копии уходят одним выпуском, старая форма — `CompileError`. Сверки задним числом заменяют сверки ссылок: кодек
сверяет события и ссылку семейства на себя, билдеры записи — владельца потока, `@after_verify` семейства — обе его
ссылки. `Projection.await` не меняется.

## User Stories

1. As an автор агрегата, I want объявить идентификатор и автора событий один раз на семействе, so that новое событие
   не повторяло `aggregate_id:` / `by:`.
2. As an автор события, I want сослаться на семейство одной опцией `family:`, so that событие не знало Prim агрегата и
   автора по отдельности.
3. As an автор агрегата, I want, чтобы чужой ID или автор в `Event.X.new` по-прежнему давал предупреждение при сборке,
   so that перенос объявления на семейство не ослаблял литеральные головы (ADR-0014).
4. As an автор кодека, I want получать `CompileError`, если событие из `tags:` не из семейства `family:`, so that
   событие чужого агрегата не попадало в кодек молча.
5. As an автор семейства, I want получать `CompileError`, если `codec:` семейства не тот кодек, который на него
   ссылается, so that связь кодек ↔ семейство не расходилась.
6. As an автор семейства, I want получать `CompileError` при сборке, если не объявлен `@type t`, so that `Outbox` и
   кодек могли сослаться на тип семейства.
7. As an автор семейства, I want получать предупреждение сборки, если `aggregate:` или `codec:` указывает на
   несуществующий модуль или на модуль чужого семейства, so that опечатка ловилась и у агрегата без репозитория.
8. As an автор репозитория, I want объявить `use Core.Es.Aggregate.Repo` одной опцией `aggregate:`, so that ID
   агрегата не повторялся рядом с кодеком, который его уже знает.
9. As an автор репозитория, I want объявить `use Core.Es.Aggregate.Repo.Pg` без `aggregate:` / `id:`, so that
   реализация брала их из своего behaviour, а не из копии.
10. As an автор репозитория, I want, чтобы чужой ID в `get` / `get_decision` / `append` / `refresh` / `page_stream`
    по-прежнему давал предупреждение при сборке, so that снятие опций не ослабляло головы.
11. As an автор репозитория, I want получать `CompileError`, если семейство кодека называет владельцем другой агрегат,
    so that поток не писали два владельца.
12. As an автор state-stored сущности, I want ту же сверку владельца потока в `use Core.Repo.Pg.StateStored` без новых
    опций, so that state-stored путь сверялся так же.
13. As an автор модуля ключа, I want сослаться на агрегат одной опцией `aggregate:`, so that ключ не повторял
    семейство и ID.
14. As an автор модуля ключа, I want получать предупреждение о неполном `reservation/1` на строке `use` ключа, so that
    ошибка указывала на ключ и ловилась без репозитория.
15. As an автор модуля ключа, I want, чтобы чужой ID в `find/2` по-прежнему давал предупреждение, so that литерал
    ключа сохранился.
16. As an автор репозитория, I want получать `CompileError`, если в `key_reservations:` ключ другого агрегата, so that
    чужой резерв не попадал в репозиторий.
17. As an автор `Outbox`, I want сослаться на семейство `family:`, so that имя опции было одним у события, кодека и
    `Outbox`.
18. As an автор проекции, I want, чтобы кодек события находился по ссылке семейства, а не по имени модуля, so that
    переименование кодека не ломало проекцию.
19. As an автор usecase, I want звать `Projection.await(Agg, id, timeout)` и `await(Agg, id, version, timeout)` как
    раньше, so that переход не трогал вызовы ожидания.
20. As an автор проекции на событиях двух владельцев с одним ID, I want, чтобы проекция собиралась и `await` различал
    потоки агрегатом, so that соседний агрегат с общим ID не ломал сборку.
21. As an потребитель, I want получать `CompileError` на старую форму опций с недостающими и неизвестными опциями в
    одном сообщении, so that переименованная опция была видна рядом с заменой.
22. As an потребитель, I want найти каждую устаревшую форму в таблице «Версия библиотеки» и пункт «было → стало» в
    `CHANGELOG.md`, so that перевод шёл по одному списку.
23. As an мейнтейнер библиотеки, I want, чтобы событие уничтожения ключа `Core.Es.Personal.Event.KeyDestroyed` шло через
    объявленное семейство с владельцем `Core.Es.Personal`, so that в библиотеке не оставалось двух форм события.
24. As an мейнтейнер библиотеки, I want, чтобы регресс литеральных голов ловил `make consumer-check`, so that снятие
    опций не ослабило вывод типов незаметно.

## Implementation Decisions

### `Core.Helper.Opts.validate!`

- Недостающие и неизвестные опции собираются до `raise`, ошибка одна:
  `<label>: нет обязательных опций: [:family]; неизвестные опции: [:event]`. Если непуст один список — текст прежний.
- `require!` (открытый список опций) не меняется. Внутренняя правка, в CHANGELOG не идёт.

### `Core.Es.Event.Family` (новый)

- Опции, все обязательны, проверка `Opts.validate!`:
  - `aggregate_id:`, `by:` — Prim, `Helper.Opts.module!`: семейство ждёт оба при раскрытии;
  - `aggregate:` — владелец потока, `codec:` — кодек. Оба — `Helper.Opts.atom!`, без загрузки. Алиас раскрывается в
    контексте функции (`%{__CALLER__ | function: {:__es_codec__, 0}}`), а не тела модуля: ребро xref — runtime, цикла
    семейство ↔ кодек / агрегат нет.
- Генерирует `__es_aggregate__/0`, `__es_aggregate_id__/0`, `__es_by__/0`, `__es_codec__/0`.
- `@before_compile`: `@type t` объявлен, иначе `CompileError`. `@type t` пишет автор.
- `@after_verify` — после сборки всех модулей, без ожидания и compile-ребра. Нарушение — `IO.warn` с файлом семейства
  (`└─ <file>: (file)`), не `raise`: `raise` роняет процесс проверки, а под `mix run` не печатает кириллицу.
  - `aggregate:` существует: `Es.Event.Family: <Family>: aggregate: <X> не найден`;
  - `codec:` существует и его `__codec_union__/0` — это семейство: `Es.Event.Family: <Family>: codec: <C> не кодек
    этого семейства`;
  - у event-sourced владельца (экспорт `__es_event_codec__/0`) кодек — `codec:`: `Es.Event.Family: <Family>:
    aggregate: <X> объявляет event_codec: <C2>, а не <C>`. У state-stored сущности и `Core.Es.Personal` — только
    существование.
- `@moduledoc`: опции, интроспекция, сверки, «одно семейство — один владелец потока».

### `Core.Es.Event`

- `family:` обязательна: `Helper.Opts.module!` с `exports: [__es_aggregate_id__: 0, __es_by__: 0]`. `aggregate_id:` и
  `by:` из опций уходят.
- Значения семейства запекаются в те же места, что сейчас: головы `new/5,6`, `@type t`, `@spec`, проверка
  `subject: :aggregate_id` (`check_subject!`).
- Интроспекция `__es_aggregate_id__/0`, `__es_by__/0` остаётся (читают `Core.Labels.CompletenessCase` и
  `check_subject!`), добавляется `__es_family__/0`.

### `Core.Es.Event.Codec`

- `event:` → `family:`. `@es_aggregate_id` / `@es_by` берутся у семейства.
- Сверки — `CompileError` на строке `use` кодека:
  - у каждого события из `tags:` `__es_family__() == family`: `событие <E> не из семейства <F>`;
  - `family.__es_codec__() == __MODULE__`: `семейство <F> объявляет codec: <C>, а не <кодек>`.
- `derive!` и его тест на разные `__es_aggregate_id__` удаляются. `__es_aggregate_id__/0` и `__codec_union__/0` кодека
  остаются; `__es_by__` наружу не отдаётся.

### `Core.Es.Outbox`

- `event:` → `family:`; `@type event` — тип семейства. `__es_event__/0` и сверка `Es.Store.Opts.ensure_outbox_event!`
  остаются. Работает и у state-stored.

### `Core.Es.Store.Opts`

- Новая `ensure_family_aggregate!/3`: `<label>: event_codec: семейство <F> объявляет aggregate: <X>, а не <Agg>` —
  `CompileError` с файлом и строкой `use`.
- `ensure_aggregate_id!` остаётся: её зовёт `Repo.Pg.StateStored`. Сверка владельца и сверка ID — соседние сверки
  одного кодека.

### `Core.Repo.Pg.StateStored`

- Опции не меняются. Добавляется вызов `ensure_family_aggregate!(event_codec, entity, label)`.

### `Core.Es.Aggregate.Repo`

- Обязательна только `aggregate:` (`exports: [__es_event_codec__: 0]`). `id` —
  `Es.Store.Opts.event_codec!(aggregate.__es_event_codec__(), label).__es_aggregate_id__()`; новой загрузки нет: кодек
  уже грузится для полноты `evolve/2`.
- `@callback`, `__es_aggregate_repo__/0` (`%{aggregate, id}`) и функции-проверки `evolve/2` — прежние.

### `Core.Es.Aggregate.Repo.Pg`

- Обязательны `behaviour:` (`exports: [__es_aggregate_repo__: 0]`), `errors:`, `outbox:`; опциональные — прежние
  (`key_reservations:`, `repo:`, `codec:`, `snapshot:`). `aggregate:` / `id:` уходят: `%{aggregate, id}` — из
  `behaviour.__es_aggregate_repo__()`, головы `%Id{}` / `%Agg{}` — из него же.
- Вызов `ensure_aggregate_id!` уходит; добавляется `ensure_family_aggregate!(event_codec, aggregate, label)`.
- Ключи (`KeyReservation.declarations!`): агрегат ключа равен агрегату репозитория — `key_reservations: aggregate: <X>
  у <Key> не равен агрегату репозитория <Agg>`; clause `code:` в `errors:` и уникальность `scope` — как сейчас.
  `KeyReservation.checks/3` и `reservation: 1` в `exports:` модуля ключа уходят.

### `Core.Es.KeyReservation`

- Опции: `scope:`, `aggregate:`, `code:` — обязательны, `personal:` — опциональна. `event:` / `id:` уходят.
- `aggregate:` — `Helper.Opts.module!` с `exports: [__es_event_codec__: 0]`; кодек — `Es.Store.Opts.event_codec!`; id —
  `__es_aggregate_id__/0` кодека, литерал в `find/2` и его `@spec`.
- Функции-проверки `"reservation/1 принимает <Event>"` генерирует `use` ключа по `__es_mods__/0` кодека, тело —
  локальный вызов `reservation(event)`. Предупреждение — на строке `use` ключа.
- `declaration` ключа несёт `aggregate`, `event_codec`, `id`; `event` уходит.

### `Core.Es.Projection`

- Кодек события — `event.__es_family__().__es_codec__()` + `ensure_compiled`. Сверка `codec.__codec_union__() ==
  family` называет `codec:` семейства: неверную ссылку проекция может встретить раньше кодека, и текст «не объявлен в
  `tags:` <чужой кодек>» был бы ложным.
- Литерал агрегата в головах `await/3,4` — `family.__es_aggregate__()`. Формы `await` прежние. Общий ID у двух кодеков
  из `events:` собирается: clauses различаются агрегатом.
- `codec_name/1`, `event_family!/1`, `aggregate_name` по `Module.split` и их `credo:disable` (`UnsafeToAtom`) уходят.
- Проверка «событие вне семейства `<Aggregate>.Event`» — по `__es_family__/0`, а не по имени модуля.

### `Core.Es.Personal.Event`

- Семейство: `use Core.Es.Event.Family, aggregate: Core.Es.Personal, aggregate_id: SubjectID, by: ActorID, codec:
  Core.Es.Personal.Event.Codec`. `KeyDestroyed` — `family: Core.Es.Personal.Event`.
  `await(Core.Es.Personal, %SubjectID{}, timeout)` — как сейчас.

### Порядок работ

`make` зелёный после каждого среза. Срез сам переводит свою часть `test/support`, `fixtures/consumer`, сводов,
moduledoc и дополняет пункт CHANGELOG.

1. **`Opts.validate!`** — одна ошибка с обоими списками.
2. **Семейство целиком.** `Core.Es.Event.Family` с `@after_verify`; `family:` у событий, кодека и `Outbox`; сверки
   кодека; `ensure_family_aggregate!` в `Repo.Pg` (пока против его `aggregate:`) и `StateStored`; удаление `derive!`;
   `Core.Es.Personal.Event`. Переводятся все `use Core.Es.Event` / `Event.Codec` / `Outbox` в `lib/`, `test/` и
   фикстуре, включая семейства без проекций (`Ping`, `Grants`, `Parcel`).
   - `test/support`: у кодека `Core.EventFixture.Event.Codec` три владельца потока (`Core.EsFixture.Catalog`,
     `StateStoredFixture.Entity`, `MacroConfigTest.Entity`). `Catalog` получает своё семейство, кодек и события;
     `MacroConfigTest` (тест «без dao») переходит на `StateStoredFixture.Entity`.
3. **Репозиторий** — `Repo` с одной `aggregate:`, `Repo.Pg` без `aggregate:` / `id:`.
4. **Ключ** — `aggregate:`, полнота `reservation/1` в ключе, сверка агрегата ключа в `Repo.Pg`.
5. **Проекция** — кодек и литерал агрегата из семейства, снятие соглашения об именах.

Срезы 3–5 идут параллельно после 2. Срезы 3 и 4 оба правят `lib/core/es/aggregate/repo/pg.ex` (опции и
`declarations!`): вливаемый вторым перестраивается на первый. Сверка агрегата ключа в срезе 4 сравнивает с агрегатом,
который `Repo.Pg` знает на момент вливания.

### Документация, свод, CHANGELOG

- **ADR** — ADR-0084 и строка «Уточнён ADR-0084» в шапке ADR-0014 уже записаны картой. ADR об `await` (0027, 0030, 0039,
  0080) не уточняются.
- **Своды правит каждый срез в своей части**, отдельного среза документации нет:
  - срез 2 — `11-domain.md` («Es.Event»: семейство, `family:`), `14-events-outbox.md` (`Outbox` и кодек `family:`,
    примеры «Совместимость событий»), `19-testing.md` (примеры с `event:` / `aggregate_id:`), `23-personal-data.md`
    (`subject: :aggregate_id` проверяется по `aggregate_id:` семейства), `app/11-domain.md`, `app/13-repos.md`
    (раскладка семейства);
  - срез 3 — `13-repos.md` («Write event-sourced агрегата», «Снапшоты», «DI»: примеры без `id:` / `aggregate:`);
  - срез 4 — `13-repos.md` («Резервы ключей»), `app/13-repos.md` («Уникальность без индекса состояния»);
  - срез 5 — `22-projections.md` («Объявление», «Read-after-write»: кодек и агрегат — ссылками семейства), описание
    skill `projections` (уходит «кодек `<Aggregate>.Event.Codec`» как способ поиска). Имя `<Aggregate>.Event.Codec`
    остаётся нормой раскладки яруса `app/`.
- **moduledoc** — `Core.Es.Event.Family` (новый), `Core.Es.Event`, `Core.Es.Event.Codec`, `Core.Es.Outbox`,
  `Core.Es.Aggregate.Repo`, `Core.Es.Aggregate.Repo.Pg`, `Core.Es.KeyReservation`, `Core.Es.Projection` («Ожидание»).
- **CHANGELOG** — один пункт в «Не выпущено» → «Изменения контракта макросов». «Ломающие изменения контракта» не
  трогаются: `await` и публичные функции не меняются. Срез 2 заводит пункт со строками семейства, события, кодека и
  `Outbox`; срезы 3 и 4 дополняют таблицу и сверки. Итоговый текст:

  > - **Связи event-sourced агрегата называет один владелец: новое семейство `use Core.Es.Event.Family`, опции-копии
  >   уходят** (решение — ADR-0084; норма — `docs/rules/11-domain.md`, «Es.Event»). Раньше один и тот же ID агрегата
  >   повторялся в каждом событии, репозитории и модуле ключа, семейство — в кодеке, `Outbox` и ключах, а сборка
  >   держала копии сверками задним числом; принадлежность событий кодека семейству не сверял никто, проекция
  >   находила кодек и агрегат по имени модуля. Теперь семейство владеет `aggregate_id` и `by` и называет владельца
  >   потока и кодек, кодек — семейством, агрегат — кодеком; остальное билдеры берут рефлексией. Старая форма —
  >   `CompileError` «нет обязательных опций: …; неизвестные опции: …». Правка потребителя:
  >
  >   | Билдер | Было | Стало |
  >   |---|---|---|
  >   | семейство `<Aggregate>.Event` | модуль с `@type t` | `use Core.Es.Event.Family, aggregate:, aggregate_id:, by:, codec:` и `@type t` |
  >   | `use Core.Es.Event` | `aggregate_id:`, `by:` | `family:` |
  >   | `use Core.Es.Event.Codec` | `event:` | `family:` |
  >   | `use Core.Es.Outbox` | `event:` | `family:` |
  >   | `use Core.Es.Aggregate.Repo` | `aggregate:`, `id:` | `aggregate:` |
  >   | `use Core.Es.Aggregate.Repo.Pg` | `behaviour:`, `aggregate:`, `id:`, … | `behaviour:`, … |
  >   | `use Core.Es.KeyReservation` | `event:`, `id:` | `aggregate:` |
  >
  >   Новые проверки сборки: событие из `tags:` не из семейства кодека и `codec:` семейства на чужой кодек —
  >   `CompileError` в кодеке; семейство кодека называет владельцем не агрегат репозитория — `CompileError` в
  >   `Repo.Pg` и `Repo.Pg.StateStored`; ключ чужого агрегата в `key_reservations:` — `CompileError` в `Repo.Pg`;
  >   `aggregate:` / `codec:` семейства на несуществующий или чужой модуль — предупреждение сборки семейства. Неполный
  >   `reservation/1` предупреждает на строке `use` ключа, а не репозитория. Семейство с одним владельцем потока:
  >   общее семейство двух агрегатов с репозиториями разделяется. `Projection.await` не меняется.

- **«Версия библиотеки»** (`docs/rules/app/00-index.md`) — четыре строки, каждую добавляет срез своей части (1–2 — срез
  2, 3 — срез 3, 4 — срез 4); правка `app/**` идёт тем же коммитом, что пункт CHANGELOG:

  | Устаревшая форма | Текущая |
  |---|---|
  | `use Core.Es.Event, aggregate_id:, by:`; семейство `<Aggregate>.Event` — модуль с `@type t` | `use Core.Es.Event, family:` и `use Core.Es.Event.Family, aggregate:, aggregate_id:, by:, codec:` (`deps/core/docs/rules/11-domain.md`, «Es.Event») |
  | `event:` у `use Core.Es.Event.Codec` и `use Core.Es.Outbox` | `family:` (`deps/core/docs/rules/14-events-outbox.md`) |
  | `id:` у `use Core.Es.Aggregate.Repo`; `aggregate:` / `id:` у `use Core.Es.Aggregate.Repo.Pg` | `aggregate:` у `Repo`, у `Repo.Pg` — `behaviour:` (`deps/core/docs/rules/13-repos.md`, «Write event-sourced агрегата») |
  | `event:` / `id:` у `use Core.Es.KeyReservation` | `aggregate:` (`deps/core/docs/rules/13-repos.md`, «Резервы ключей») |

- **Глоссарий** — «Владелец потока» и уточнённое «Семейство событий агрегата» в `CONTEXT.md` записаны картой.

## Testing Decisions

Хороший тест проверяет то, что видит автор кода на `Core.*`: какой `CompileError` или предупреждение он получил, на
какой строке, и что литеральные головы по-прежнему ловят чужой ID. Устройство рефлексии и порядок вызовов не
проверяются.

- **`CompileError` — тестами библиотеки** (`Code.eval_quoted` / `Code.compile_string`): событие из `tags:` не из
  семейства; `codec:` семейства на чужой кодек; семейство без `@type t`; семейство кодека называет владельцем не агрегат
  `Repo.Pg` и не сущность `StateStored`; ключ чужого агрегата в `key_reservations:`; `aggregate:` ключа — не агрегат;
  старая форма опций — одно сообщение с недостающими и неизвестными (`Opts.validate!`). Образцы —
  `test/core/es/event/codec_test.exs`, `test/core/es/aggregate/repo/pg_test.exs`,
  `test/core/es/key_reservation_test.exs`.
- **Предупреждение `@after_verify`** — тестом библиотеки, если `Code.compile_string` его вызывает (проверяет срез 2);
  иначе сценарием `fixtures/consumer` с маркером `# expect:`.
- **Вывод типов у потребителя** — `make consumer-check`: сценарии `event_new.ex` (чужой ID и автор в `new`), `repo.ex`
  (чужой ID в функциях `Repo.Pg`), `key_reservation.ex` (чужой ID в `find/2`, неполный `reservation/1` и опечатка в
  поле нагрузки — маркер на строке `use` ключа), `await.ex` (агрегат не из `events:`, чужой ID, `Core.Es.Personal` с
  чужим ID) дают те же предупреждения. Сценарии `BadKey.Repo.Pg` / `BadKeyPayload.Repo.Pg` удаляются.
- **Удаляются** тест `derive!` на разные `__es_aggregate_id__` и тесты сверок `id:` / `aggregate:` / `event:` в
  `Repo.Pg` и ключе; тесты сверок ключа переписываются на сверку агрегата.
- **Без изменений** тесты `await` (`test/core/es/projection_test.exs`, `projection/await_test.exs`,
  `projection/await_commit_test.exs`, `personal/projection_test.exs`): формы прежние.
- Перекомпиляцию тест не проверяет: она замерена прототипами (ADR-0084, «Цена»).

## Out of Scope

- Одна ветка `quote` в шаблоне события — отдельный тикет ревью
  `.scratch/builders-review/issues/14-event-template-one-branch.md`.
- Сверки `id:` / `aggregate:` у репозитория в текущем контракте — тикет ревью
  `.scratch/builders-review/issues/13-aggregate-wiring-checks.md`; после этого выпуска сверять нечего.
- Отказ от литеральных голов (ADR-0014).
- Опции `Repo.Pg.StateStored`, DI `<Behaviour>.Pg` во время выполнения.
- Формы `Projection.await`.
- `@after_verify` с `IO.warn` как норма сводов — до второго случая (ADR-0084).
- Перевод кода потребителей.

## Further Notes

- Образцы реализации — ветки прототипов карты, не источник истины; удаляются после реализации:
  - `prototype/family-declaration` — семейство, `family:` у события, сверки кодека (срез 2);
  - `prototype/repo-wiring` — `Repo` / `Repo.Pg` без опций-копий (срез 3);
  - `prototype/key-reservation-wiring` — ключ с `aggregate:`, полнота в ключе, скрипт замера перекомпиляции (срез 4);
  - `prototype/projection-wiring` — `codec:` у семейства, вариант runtime-ссылки (срезы 2 и 5; формы `await` без
    агрегата оттуда не переносятся);
  - `prototype/family-aggregate` — `aggregate:` у семейства, `ensure_family_aggregate!`, `@after_verify`, сценарий
    общего ID (срезы 2 и 5).
- Прототипы правили только фикстуру; тесты библиотеки и moduledoc в них не переводились, `mix test` не запускался.
- Новый приём `@after_verify` + `IO.warn`: если `Code.compile_string` предупреждение не вызывает, проверка остаётся
  только в `consumer-check`.
