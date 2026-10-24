# 19: Проекция по ссылкам семейства

**What to build:** автор проекции не зависит от имён модулей: кодек события находится как
`event.__es_family__().__es_codec__()`, литерал агрегата в головах `await/3,4` — `family.__es_aggregate__()`.
Переименование кодека не ломает проекцию; проекция на событиях двух владельцев с общим ID собирается, `await`
различает потоки агрегатом. Формы `Projection.await` прежние. Спека — `../spec.md`, «`Core.Es.Projection`», «Порядок
работ», срез 5; ADR-0084. Образцы — `prototype/projection-wiring` (формы `await` без агрегата не переносятся),
`prototype/family-aggregate` (сценарий общего ID).

**Blocked by:** 15.

**Status:** ready-for-agent

- [ ] Кодек события — по ссылке семейства + `ensure_compiled`; сверка `codec.__codec_union__() == family` называет
  `codec:` семейства.
- [ ] Литерал агрегата `await/3,4` — `family.__es_aggregate__()`; общий ID у двух кодеков из `events:` собирается.
- [ ] `codec_name/1`, `event_family!/1`, `aggregate_name` по `Module.split` и их `credo:disable` (`UnsafeToAtom`)
  удалены; проверка «событие вне семейства» — по `__es_family__/0`.
- [ ] `make consumer-check`: сценарий `await.ex` (агрегат не из `events:`, чужой ID, `Core.Es.Personal` с чужим ID)
  даёт те же предупреждения; сценарий общего ID собирается.
- [ ] Тесты `await` без изменений и зелёные.
- [ ] `@moduledoc` `Core.Es.Projection` («Ожидание»).
- [ ] Свод `22-projections.md` («Объявление», «Read-after-write»: кодек и агрегат — ссылками семейства), описание
  skill `projections` (уходит «кодек `<Aggregate>.Event.Codec`» как способ поиска). `make rules-check`.
- [ ] CHANGELOG: новых строк таблицы нет; пункт сверен с итоговым текстом спеки.
- [ ] Приёмка: `make` целиком.
- [ ] После влития удаляются ветки `prototype/projection-wiring` и `prototype/family-aggregate` (если 16 уже влит).
