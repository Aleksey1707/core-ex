# Тестовая поддержка event-sourced агрегата: given / when / then и полнота `evolve`

Type: grilling
Status: resolved
Blocked by: 05
Map: [Event-sourced агрегат в :core](../map.md)

## Question

Как потребитель тестирует event-sourced агрегат без БД:

- форма given / when / then: given — события или результаты `decide`, when — команда, then — результат `decide`
  или доменная ошибка; case-модуль или функции-помощники; как given получает `id`, версии, `by` и `at`;
- проверка полноты `evolve`: у каждого модуля событий из `event_codec:` есть clause — генерируемый тест,
  помощник или контрактный тест behaviour;
- место в `docs/rules/19-testing.md` и связь с golden-фикстурами событий;
- где живёт `EventCompatCase` и имена интроспекции кодека для его инвариантов (модули событий, источники `upcasts:`) —
  забрано из «Not yet specified» карты.

Контракт агрегата — [«Контракт event-sourced агрегата»](05-prototype-aggregate-contract.md). Инварианты golden-фикстур —
[«Эволюция событий: где апкастится история»](09-grilling-event-evolution.md).

## Answer

- **Given / when / then — функции, не DSL.** `Core.Es.Aggregate.Test.given(state, results, by:, at:)` → состояние:
  `results` — результаты `decide` (`{Event.Mod, payload}` / `Event.Mod`), `id` — из состояния, версии — от
  `state.version`, `by` / `at` — обязательные опции без значений по умолчанию; разные авторы — цепочкой от `%Agg{id: id}`.
  When — `Agg.decide(cmd, state)`; then — короткая форма `decide`: `{:ok, [{Mod, payload}]}`, `{:ok, []}`,
  `{:error, %Error{kind: :domain, code: …}}` без `message` / `detail`. Состояние — тестами `evolve` через `fold`. ExUnit в
  `lib/` помощники не используют.
- **Отвергнуто:** case-модуль и DSL given / when / then (прячет diff `assert`, настраивать нечего); given из
  `%Es.Event{}` (ручная нумерация версий) и из команд через `execute/2` (не воспроизводит событие удалённого типа, тест
  одной команды зависит от `decide` другой); `given`, генерируемый в агрегате (тестовая функция в прод-API); then по
  `execute/2` или состоянию после команды (`event_id` и `at` в каждом тесте); значения `by` / `at` по умолчанию (свод
  «Время», у Prim автора может не быть генератора).
- **`use Core.Es.EventCompatCase`** — в `lib/`, ExUnit только внутри `quote`; один тест-модуль на агрегат вместо
  `MyApp.EventCompatCase`. Опции: ровно одна из `aggregate:` (event-sourced, кодек — `__es_event_codec__/0` из
  `use Core.Es.Aggregate`) или `event_codec:` (state-stored), обе или ни одной — `CompileError`; `fixtures:` —
  необязательная, по умолчанию `test/support/fixtures/events/<тип агрегата>/`; фасад — `Core.Config.codec/0`. Семейство
  событий, `aggregate_id` и тип агрегата выводятся из кодека. Генерирует инварианты golden-фикстур 1–4 и при
  `aggregate:` — полноту `evolve`. Свой case у потребителя и чистые функции проверок отвергнуты: инварианты — контракт
  кодека библиотеки, копии case в приложениях расходятся молча.
- **Полнота `evolve`** — `evolve(%Agg{id: aggregate_id}, событие)` на фикстуре каждого тега из `tags:` (инвариант 1
  покрывает все модули кодека); провал — только `FunctionClauseError` самой `Agg.evolve/2`, прочие исключения пропуском
  клаузы не считаются. Опирается на норму «голова `evolve` матчит только событие, не значения состояния». Разбор clause
  из debug_info (хрупок к guard'ам) и проверка на компиляции (цикл агрегат → кодек → события → `Agg.ID`) отвергнуты.
- **Интроспекция кодека** — `__es_mods__/0` (модули из `tags:`) и `__es_upcasts__/0` (карта как объявлена), в одном
  ряду с `__es_aggregate_id__/0`: API механизмов библиотеки (`EventCompatCase`, фильтр проекции, guard `fold/3`, маркер
  снапшота), не приложения; `types/0` и `mod_by_tag/1` остаются; конец цепочки апкастов наружу не выносится.
- **Свод** — `19-testing.md`: «Совместимость событий» → `use Core.Es.EventCompatCase` (инварианты 1–4 и полнота
  `evolve`), оговорка «в библиотеке их аналогов нет» для `EventCompatCase` снимается; новый раздел «Event-sourced
  агрегат» (given, then, `evolve` через `fold`). Норма головы `evolve` — к контракту агрегата, пункт «Своды» карты.
- Термины `CONTEXT.md` и ADR не заводятся: тестовая поддержка откатывается дёшево.

## Comments

- 2026-09-13 — раунд 1:
  - библиотека даёт чистые функции-помощники в `lib/` без ExUnit, `assert` — у потребителя; DSL given / when / then
    и case-модуль отвергнуты: DSL прячет diff `assert`, настраивать case-модулю нечего (`async: true`, без БД);
  - given — результаты `decide` (`{Event.Mod, payload}` / `Event.Mod`), `id`, версии, `by`, `at` проставляет
    библиотека; полные `%Es.Event{}` и команды через `execute/2` отвергнуты: команда не воспроизводит событие
    удалённого типа, а тест одной команды зависел бы от `decide` другой;
  - then — результат `decide/2` в короткой форме; состояние — тестами `evolve` через `fold`; сравнение `%Es.Event{}` и
    состояния после команды отвергнуты;
  - полнота `evolve` — вызов `evolve/2` на событии каждого модуля из golden-фикстур, пропуск — только
    `FunctionClauseError` самой `Agg.evolve/2`; норма: голова `evolve` матчит только событие; разбор clause из debug_info
    и проверка на компиляции отвергнуты;
  - место `EventCompatCase` и интроспекция источников `upcasts:` забраны в тикет из «Not yet specified».
- 2026-09-13 — раунд 2:
  - `Core.Es.Aggregate.Test.given(state, results, by:, at:)` → состояние, цепочкой; `events(Agg, id, …)` и `given` в
    агрегате отвергнуты;
  - `by` / `at` — обязательные опции; значения по умолчанию и `{cmd, results}` отвергнуты;
  - `use Core.Es.EventCompatCase` в `lib/` генерирует инварианты 1–4 и полноту `evolve`; ExUnit только внутри `quote`;
  - интроспекция кодека — `__es_mods__/0`, `__es_upcasts__/0`;
  - прочие исключения `evolve/2` в проверке полноты — не пропуск клаузы.
- 2026-09-13 — раунд 3:
  - опции `EventCompatCase`: `aggregate:` | `event_codec:`, `fixtures:` по умолчанию по типу агрегата, фасад —
    `Core.Config.codec/0`; `__es_event_codec__/0` генерирует `use Core.Es.Aggregate`;
  - `19-testing.md` — «Совместимость событий» и раздел «Event-sourced агрегат»; норма головы `evolve` — в «Своды» карты;
  - then для ошибки — `kind` и `code`, без `message` / `detail`;
  - ответ подтверждён пользователем.
