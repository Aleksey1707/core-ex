# 19: Проекция по ссылкам семейства

**What to build:** автор проекции не зависит от имён модулей: кодек события находится как
`event.__es_family__().__es_codec__()`, литерал агрегата в головах `await/3,4` — `family.__es_aggregate__()`.
Переименование кодека не ломает проекцию; проекция на событиях двух владельцев с общим ID собирается, `await`
различает потоки агрегатом. Формы `Projection.await` прежние. Спека — `../spec.md`, «`Core.Es.Projection`», «Порядок
работ», срез 5; ADR-0084. Образцы — `prototype/projection-wiring` (формы `await` без агрегата не переносятся),
`prototype/family-aggregate` (сценарий общего ID).

**Blocked by:** 15.

**Status:** resolved

- [x] Кодек события — по ссылке семейства + `ensure_compiled`; сверка `codec.__codec_union__() == family` называет
  `codec:` семейства.
- [x] Литерал агрегата `await/3,4` — `family.__es_aggregate__()`; общий ID у двух кодеков из `events:` собирается.
- [x] `codec_name/1`, `event_family!/1`, `aggregate_name` по `Module.split` и их `credo:disable` (`UnsafeToAtom`)
  удалены; проверка «событие вне семейства» — по `__es_family__/0`.
- [x] `make consumer-check`: сценарий `await.ex` (агрегат не из `events:`, чужой ID, `Core.Es.Personal` с чужим ID)
  даёт те же предупреждения; сценарий общего ID собирается.
- [x] Тесты `await` без изменений и зелёные.
- [x] `@moduledoc` `Core.Es.Projection` («Ожидание»).
- [x] Свод `22-projections.md` («Объявление», «Read-after-write»: кодек и агрегат — ссылками семейства), описание
  skill `projections` (уходит «кодек `<Aggregate>.Event.Codec`» как способ поиска). `make rules-check`.
- [x] CHANGELOG: новых строк таблицы нет; пункт сверен с итоговым текстом спеки.
- [x] Приёмка: `make` целиком.
- [ ] После влития удаляются ветки `prototype/projection-wiring` и `prototype/family-aggregate` (если 16 уже влит).

## Comments

- «Событие вне семейства» теперь — `family:` события указывает не на `use Core.Es.Event.Family`: опцию
  `use Core.Es.Event` проходит любой модуль с `__es_aggregate_id__/0` и `__es_by__/0`, например другое событие.
  Проверка «семейство в `events:`» — по `__es_codec__/0` модуля.
- Тесты `await`: одна строка `await_test.exs` — `await(EventFixture, …)` → `await(Entity, …)`. Владелец потока
  семейства `Core.EventFixture.Event` — `Core.StateStoredFixture.Entity` (тикет 15), а прежний литерал
  `Core.EventFixture` выводился по имени кодека; фикстура не следует раскладке потребителя. У потребителя с
  раскладкой `<Aggregate>.Event.Codec` литерал не меняется.
- `projection_test.exs`: у `Twin` и `Loose` свои семейства (`Twin.Family`, `Loose.Family`), `event:` их кодеков —
  на них. Тест «вне семейства `<Aggregate>.Event`» стал положительным: `Loose.Events.Codec` вне раскладки
  собирается, а `Loose.Family` с `aggregate_id: Account.ID` даёт сценарий общего ID. Семейства с битым `codec:`
  (`Lone`, `Untyped`, `Alien`) собираются в тесте под `capture_io`: их сверка `@after_verify` иначе печатала бы
  предупреждения в выводе `mix test`.
- `fixtures/consumer/scenarios/await.ex`: сценарий общего ID — владелец `ConsumerTest.Shipment` с `Order.ID`, его
  семейство, событие и кодек, проекция `ConsumerTest.SharedID.Projection` и вызовы `await` (G4g без
  предупреждений, G4ga — агрегат не из `events:`). Кодек `Shipment` объявлен с `event:`: при влитии после
  тикета 16 его переводят на `family:` вместе с остальными.
- CHANGELOG не правился: часть итогового текста о проекции уже в пункте («проекция находила кодек и агрегат по
  имени модуля», «`Projection.await` не меняется»); «кодек — семейством, агрегат — кодеком; остальное билдеры
  берут рефлексией» дописывают срезы 16–17 вместе со своими строками таблицы.
- Удаление веток `prototype/*` — после влития, у оркестратора.
