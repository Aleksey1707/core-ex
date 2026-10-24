# 12: Прототип `aggregate:` у семейства

Type: prototype
Status: resolved

Blocked by: 07, 09

## Question

Собирается ли обязательная `aggregate:` у `use Core.Es.Event.Family` (пересмотр тикета 07) без взаимного ожидания,
и правильна ли перекомпиляция проекции? Проверка на ветке от `prototype/projection-wiring`, копия `fixtures/consumer`.

Что проверить:
- `aggregate:` — атом без загрузки, раскрытие как у `codec:` (вариант Б тикета 09, runtime-ссылка). Есть ли
  compile-цикл семейство ↔ агрегат в варианте А, и пропадает ли он в Б.
- Проекция берёт литерал головы `await` из `event.__es_family__().__es_aggregate__()` вместо `Module.split(codec)`;
  формы `await(Agg, %ID{}, …)` прежние, общий ID двух кодеков в `events:` собирается без `CompileError`
  (`streams_by_id!` прототипа 09 уходит).
- Сверка `family.__es_aggregate__() == <агрегат>`: в `Es.Aggregate.Repo` и `Repo.Pg.StateStored` (тикет 07) или в
  ином билдере, который уже ждёт и агрегат, и кодек. Кто ловит опечатку в `aggregate:` у агрегата без репозитория
  и у семейства `Core.Es.Personal.Event` (владелец — `Core.Es.Personal`). Текст `CompileError`.
- `consumer-check` и маркеры `# expect:` сценария `await`: предупреждение на агрегат не из `events:` и на чужой ID.
- `mix xref graph --label compile` и `mix compile --verbose` против `prototype/projection-wiring`: правка агрегата,
  `Agg.ID`, семейства и кодека — перекомпилирует ли проекцию.

## Answer

Проверено 2026-10-24. Прототип — ветка `prototype/family-aggregate` (от `prototype/projection-wiring` `65a6269`), не
сливается. Коммиты: `38fc3b4` — вариант А (`aggregate:` — compile-ссылка), `585abdd` — вариант Б (runtime-ссылка) и
сверки, `e8a8c9b` — скрипт замера `.prototype/recompile-12.sh` и сценарий общего ID `.prototype/shared_id_scenario.ex`.

**Что в прототипе.**
- `Es.Event.Family`: обязательная `aggregate:` — `Helper.Opts.atom!`, без загрузки; `__es_aggregate__/0`. В варианте Б
  раскрывается вместе с `codec:` через `%{__CALLER__ | function: …}`.
- `Es.Projection`: формы `await(Agg, %ID{}, t)` / `await(Agg, %ID{}, %Version{}, t)` вернулись. Литерал агрегата —
  `codec.__codec_union__().__es_aggregate__()`, у семейства без `Family` — прежний `Module.split`. `streams_by_id!` ушёл.
- Фикстура: `aggregate: Account` / `aggregate: Order` у семейств, вызовы `await` и `scenarios/await.ex` — как до
  прототипа 09. `Core.Es.Personal.Event` — `aggregate: Core.Es.Personal`.
- Сверки — ниже. `test/support`: `EventFixture.Event` переведено на `Family`, у репозиториев сняты `id:` / `aggregate:`
  (долг прототипа 05). `mix test` не запускался, test-сборка не доведена.

**Компиляция и xref.**
- `make consumer-check` — ok в обоих вариантах, 126 ожидаемых предупреждений (как до прототипа 09), лишних нет.
  G4 / G4v (ID другого агрегата), G4b (агрегат не из `events:`), G4s (`await(Core.Es.Personal, %Account.ID{})`) и G4w
  (скопированный хелпер с чужим агрегатом) снова дают `incompatible types given to …await/3` / `/4`.
- Вариант А: новое compile-ребро семейство → агрегат. Цикл заказа становится целиком compile (5 из 5 рёбер вместо 4).
  В библиотеке цикл `Core.Es.Personal` — 3 compile вместо 2. Правка агрегата и кодека заказа тянет семейство
  (+1 файл).
- Вариант Б: `mix xref graph --label compile`, циклы и перекомпиляция совпадают с `prototype/projection-wiring` один в
  один. Ребро `order/event.ex → order.ex` — runtime.

| Правка (фикстура) | База 09 | А | Б | Проекция |
|---|---|---|---|---|
| агрегат заказа — public fn | 17 | 18 | 17 | да |
| `Order.ID` — public fn | 24 | 24 | 24 | да |
| семейство заказа — public fn | 16 | 16 | 16 | да |
| кодек заказа — `type:` | 15 | 16 | 15 | да |
| агрегат / семейство / кодек счёта | 40 / 39 / 39 | то же | то же | да |

Проекция перекомпилируется при любой из правок. Если в семействе меняется `aggregate:`, перекомпилируется семейство,
за ним события, за ними проекция, и литерал головы `await` не устаревает. **Рекомендация — вариант Б.**

**Общий ID у двух кодеков в `events:`.** Проекция на `Order.Event.Placed` и событии второго семейства с
`aggregate_id: Order.ID` собирается без `CompileError`. `await(Order, id, t)` и `await(<второй владелец>, id, t)`
различаются агрегатом, чужой агрегат даёт предупреждение типов (`.prototype/shared_id_scenario.ex`).

**Сверки: кто ловит.** Владелец потока — тот, кто его пишет. Поэтому обратная сверка стоит в билдерах записи.
- `Es.Aggregate.Repo.Pg` и `Repo.Pg.StateStored`: `Es.Store.Opts.ensure_family_aggregate!/3`, `CompileError` с файлом
  и строкой `use`. Новых ожиданий нет: оба билдера уже ждут агрегат (сущность) и кодек. Текст:
  `Es.Aggregate.Repo.Pg: event_codec: семейство <Family> объявляет aggregate: <X>, а не <Agg>`.
- Не в `Es.Aggregate.Repo` (behaviour): сценарий C1 (`scenarios/evolve.ex`) строит его на агрегате-однодневке с чужим
  кодеком, а behaviour ничего не пишет.
- Не в `Es.Aggregate`: «один агрегат на семейство» нарушают 9 мест. В фикстуре это `NeverFails` / `AlwaysFails` на
  кодеке заказа и 4 сценария на кодеке счёта, в тестах — `aggregate_test.exs` на `EsFixture.Account`, плюс `Catalog`
  (ниже). У агрегата без репозитория потока нет: его можно ни с чем не сверять.
- Семейство само — `@after_verify Core.Es.Event.Family` после сборки всех модулей, без ожидания и без compile-ребра.
  Проверяет: `aggregate:` существует; `codec:` — кодек этого семейства; у event-sourced `aggregate:`
  `__es_event_codec__() == codec`. Так ловится опечатка в `aggregate:` у семейства без репозитория и у
  `Core.Es.Personal.Event` (`Core.Es.Personal` не агрегат: проверяется только существование). Заодно закрыт долг
  тикета 09: `codec:` на несуществующий модуль больше не собирается молча.
- В `@after_verify` — `IO.warn` с файлом семейства, а не `raise`. `raise` роняет процесс проверки
  (`** (EXIT from #PID…)`), а под `mix run` (`consumer-check`) не печатает кириллицу (`badarg`, crash dump). С
  предупреждением `mix compile` проходит, `--warnings-as-errors` и `consumer-check` падают. Текст:
  `Es.Event.Family: <Family>: aggregate: <X> не найден` (`└─ <file>: (file)`).
- Опечатка короткого имени без `alias` (`aggregate: Account` в файле заказа) — корневой атом, ловится как «не найден».

**Для реализации.**
- `test/support`: семейство `Core.EventFixture.Event` делят event-sourced `Core.EsFixture.Catalog` (с `Repo.Pg`) и
  state-stored сущности (`StateStoredFixture.Entity`, `MacroConfigTest.Entity` в `macro_config_test.exs`). С любым
  `aggregate:` одна сторона даёт `CompileError` (проверено в обе стороны). Нужно своё семейство и кодек `Catalog` либо
  отдельное семейство state-stored фикстуры.
- Запасные ветки `Module.split` в `stream_aggregate/1` и `<Family>.Codec` в `family_codec/1` уходят: все семейства
  переходят на `Family` одним выпуском (тикет 02). Семейства без `Family` в фикстуре (`Ping`, `Grants`, `Parcel`) —
  тоже.
- `ensure_aggregate_id!` у `StateStored` и новая `ensure_family_aggregate!` — соседние сверки одного кодека.
- В прототипе не правились moduledoc `Es.Event.Family` / `Es.Projection` («Ожидание»). Тесты библиотеки на `await`
  не трогались, формы прежние.
