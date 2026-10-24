# 16: `family:` у кодека и `Outbox`, сверка владельца потока

**What to build:** автор кодека и `Outbox` ссылается на семейство `family:`, как событие. Событие из `tags:` не из
семейства кодека и `codec:` семейства на чужой кодек — `CompileError` на строке `use` кодека; семейство кодека,
называющее владельцем не агрегат `Repo.Pg` и не сущность `StateStored`, — `CompileError` на строке `use`
репозитория. Сверка задним числом `derive!` уходит. Старая форма `event:` — `CompileError` с недостающими и
неизвестными опциями. Спека — `../spec.md`, «`Core.Es.Event.Codec`», «`Core.Es.Outbox`», «`Core.Es.Store.Opts`»,
«`Core.Repo.Pg.StateStored`», «Порядок работ», срез 2; ADR-0084. Образцы — `prototype/family-declaration`,
`prototype/family-aggregate`.

**Blocked by:** 15.

**Status:** resolved

- [x] `Core.Es.Event.Codec`: `event:` → `family:`, `@es_aggregate_id` / `@es_by` — у семейства. Сверки —
  `CompileError` на строке `use`: `событие <E> не из семейства <F>`; `семейство <F> объявляет codec: <C>, а не <кодек>`.
- [x] `derive!` и его тест на разные `__es_aggregate_id__` удалены; `__es_aggregate_id__/0` и `__codec_union__/0`
  кодека остались, `__es_by__` наружу не отдаётся.
- [x] `Core.Es.Outbox`: `event:` → `family:`, `@type event` — тип семейства; `__es_event__/0` и
  `ensure_outbox_event!` остались; работает и у state-stored.
- [x] `Es.Store.Opts.ensure_family_aggregate!/3` — `CompileError` с файлом и строкой `use`; вызов в
  `Es.Aggregate.Repo.Pg` (против его текущей `aggregate:`) и в `Repo.Pg.StateStored`; `ensure_aggregate_id!` остался.
- [x] Все `use Core.Es.Event.Codec` и `use Core.Es.Outbox` в `lib/`, `test/`, фикстуре переведены.
- [x] Тесты библиотеки: событие из `tags:` не из семейства; `codec:` семейства на чужой кодек; семейство кодека
  называет владельцем не агрегат `Repo.Pg` и не сущность `StateStored`; старая форма опций кодека — одно сообщение.
- [x] `@moduledoc` `Core.Es.Event.Codec`, `Core.Es.Outbox`.
- [x] Свод `14-events-outbox.md` (`Outbox` и кодек `family:`, примеры «Совместимость событий»). `make rules-check`.
- [x] CHANGELOG: строки `use Core.Es.Event.Codec`, `use Core.Es.Outbox` и сверки кодека и владельца потока в пункте
  тикета 15; строка 2 «Версии библиотеки».
- [x] Приёмка: `make` целиком; `make consumer-check` без новых предупреждений.
- [ ] После влития удаляется ветка `prototype/family-declaration`.

## Comments

- Ветка `prototype/family-declaration` не удалена: её удаляет оркестратор после влития.
- `LabelsFixture`: события больше не делятся между кодеками. `WebEvent.Codec` слит в `Event.Codec` (он же теперь в
  фасадах `Core.CodecFixture.*`); события с нагрузкой без плагина (`Tagged`, `OriginChanged`, `TagsChanged`) ушли в
  семейство `Event.ManualFamily` со своим кодеком вне фасада, ратчет полноты берёт оба кодека.
- Сверка `codec:` семейства идёт в теле `use` после `tags:` / `upcasts:`: тесты сверок тегов и апкастов собирают
  кодек на чужом семействе и получают свою ошибку раньше. Кодеку, которому нужна успешная сборка или
  `__before_compile__`, тест заводит семейство `Core.EventFixture.family_ast/2`.
- `CompileError` сверок кодека и `ensure_family_aggregate!/3` поднимается при раскрытии `use`: файл и строку `use`
  называет стек ошибки, отдельных `file:` / `line:` нет (как у остальных сверок `Es.Store.Opts`).
- `__es_family__/0` у кодека оставлен: его читают `Es.Store.Opts` и `Projection` (тикет 19).
