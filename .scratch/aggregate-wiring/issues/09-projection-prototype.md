# 09: Прототип проекции с кодеком из семейства и `await` по ID

Type: prototype
Status: resolved

Blocked by: 07

## Question

Собирается ли `use Core.Es.Projection`, если кодек берётся через `event.__es_family__().__es_codec__()`, а у
`await` нет агрегата (тикет 07), на копии `fixtures/consumer`? Правильна ли перекомпиляция с атомом `codec:` в
`use Core.Es.Event.Family`?

- `make consumer-check` проходит, вызов с ID не из `events:` даёт предупреждение у вызывающего, как сейчас с
  агрегатом;
- `codec:` у семейства не равен кодеку, который на него ссылается, — `CompileError` в кодеке;
- два кодека в `events:` с одним `__es_aggregate_id__` — `CompileError` в проекции;
- `Personal`: `await(%SubjectID{}, timeout)`;
- разница `mix xref graph --label compile`: не добавил ли атом `codec:` в `use` семейства ребро компиляции
  семейство → кодек и не вырос ли цикл перекомпиляции агрегата (тикет 03: 8 модулей);
- правка кодека перекомпилирует проекцию.

Прототип — от ветки `prototype/repo-wiring` (или `prototype/key-reservation`, если тикет 08 уже закрыт), ссылка на
него — в ответе.

## Answer

Проверено 2026-10-23. Прототип — ветка `prototype/projection-wiring` (от `prototype/repo-wiring` `670f7c9`; тикет 08 ещё
в работе), не сливается. Коммиты: `0eec3b5` — вариант А (`codec:` — compile-ссылка), `65a6269` — вариант Б
(`codec:` — runtime-ссылка), HEAD = Б.

**Что в прототипе.**
- `Es.Event.Family`: обязательная `codec:` — `Helper.Opts.atom!`, без загрузки; `__es_codec__/0`.
- `Es.Event.Codec.family_subjects!/3`: у семейства с `use Core.Es.Event.Family` сверяет `__es_codec__() == __MODULE__`.
- `Es.Projection`: кодек — `event.__es_family__().__es_codec__()`, у семейства без `Family` — прежний `<Family>.Codec`
  (агрегаты фикстуры, не переведённые на `Family`). Агрегат и `Module.split` из `await` ушли: `await(%ID{}, timeout)`,
  `await(%ID{}, %Version{}, timeout)`; `streams_by_id!` — `CompileError` на общем ID.
- `Core.Es.Personal.Event` — семейство (`SubjectID`, `ActorID`, `codec: Core.Es.Personal.Event.Codec`), `KeyDestroyed` —
  `family:`. В фикстуре семейство заказа переведено на `Family`, `codec:` — у счёта и заказа; вызовы `await` — без
  агрегата.

**Результат.**
- `make consumer-check` — ok, 124 ожидаемых предупреждения, лишних нет. В `scenarios/await.ex`:
  - G4 и G4v (`%Ping.ID{}` — ID не из `events:`) — `incompatible types given to …Projection.await/2` и `/3`;
  - G4vi (версия целым) — `await/3`;
  - G4a (прежняя форма с модулем агрегата) — `await/3`;
  - G4c не изменился.

  Два маркера ушли, класс ошибки исчез: G4s — `await(%SubjectID{}, t)` без предупреждения, G4w — у скопированного
  хелпера `wait:` нет агрегата, ошибиться нечем.
- `codec:` семейства на чужой кодек — `CompileError` в кодеке: «семейство … объявляет codec: …, а не …».
- Два кодека с одним ID в `events:` — `CompileError` в проекции: «кодеки [...] с одним ID … — await/2 не различит
  потоки».

**`mix xref graph --label compile`, разница с `prototype/repo-wiring`.**

```
+ order/event.ex → order/id.ex, values/user_id.ex   # заказ переведён на Family (эффект тикета 03)
+ order/event/{placed,cancelled}.ex → order/event.ex
- order/event/{placed,cancelled}.ex → order/id.ex, values/user_id.ex
+ {account,order}/event.ex → <agg>/event/codec.ex   # только вариант А: атом codec: в use семейства
```

В варианте А `Macro.expand_literals(opts, __CALLER__)` раскрывает алиас `codec:` в теле модуля, и выходит compile-ребро.
Получается цикл семейство ↔ кодек. У счёта цикл остаётся 8: семейство уже было в нём через `Account.ID`. У заказа (ID
в отдельном файле) цикл 3 → 5: туда входят семейство и `Cancelled`. Вариант Б раскрывает `codec:` с
`%{__CALLER__ | function: {:__es_codec__, 0}}` (так Phoenix обходит compile-ребро алиаса). Ребро становится
runtime, цикл заказа снова 3, у счёта 8.

**Перекомпиляция** (`mix compile --verbose`, число файлов; во всех случаях проекция перекомпилируется):

| Правка | База | А | Б |
|---|---|---|---|
| кодек счёта — public / private fn, `type:` | 39 | 39 | 39 |
| кодек заказа — `type:` | 13 | 16 | 15 (без семейства) |
| семейство заказа — public fn | 15 | 16 | 16 |
| `Order.ID` — public fn | 22 | 24 | 24 |
| отдельные семейство + событие + кодек + проекция без агрегата — `type:` / public fn кодека | — | 4 | 3 (без семейства) |

У заказа прирост относительно базы — в основном перевод на `Family` (тикет 03). Связь проекции с кодеком не опирается
на агрегат. Mix перекомпилирует зависимое по compile-ребру и по всем runtime-рёбрам за ним:
`проекция →(compile) событие →(compile) семейство →(runtime) кодек`. Последний случай таблицы это подтверждает: у
проекции без агрегата правка кодека, включая `type:`, перекомпилирует проекцию, и clauses `await` не устаревают.

**Рекомендация — вариант Б.** Перекомпиляция проекции та же, а compile-цикла семейство ↔ кодек нет. Опечатка в
`codec:` всё равно ловится: каждое семейство имеет кодек (`event:`), а он сверяет `__es_codec__()`.

**Для реализации.**
- Ошибочный `codec:` иногда первой ловит проекция, а не кодек — зависит от порядка параллельной сборки. Текст тогда
  ложный: «… не объявлен в tags: <чужой кодек>». `codec!/2` проекции должен сверять `codec.__codec_union__() == family`
  и называть `codec:` семейства.
- Семейство с `codec:` на несуществующий модуль и без кодека собирается молча. Ловит это только проекция («кодек …
  не найден»).
- Запасной `<Family>.Codec` и `event_family!/1` уходят: все семейства переводятся на `Family` одним выпуском (тикет 02).
  Семейство state-stored событий (`test/support`, `EventFixture`) тоже получает `use Core.Es.Event.Family … codec:`.
- В прототипе не правились: `await(Agg, …)` в тестах библиотеки (`test/core/es/projection_test.exs`,
  `projection/await_test.exs`, `projection/await_commit_test.exs`, `personal/projection_test.exs`), `@moduledoc`
  `Core.Es.Projection` («Ожидание», `await/3` / `await/4`). `mix test` не запускался.
