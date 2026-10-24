# 16: `family:` у кодека и `Outbox`, сверка владельца потока

**What to build:** автор кодека и `Outbox` ссылается на семейство `family:`, как событие. Событие из `tags:` не из
семейства кодека и `codec:` семейства на чужой кодек — `CompileError` на строке `use` кодека; семейство кодека,
называющее владельцем не агрегат `Repo.Pg` и не сущность `StateStored`, — `CompileError` на строке `use`
репозитория. Сверка задним числом `derive!` уходит. Старая форма `event:` — `CompileError` с недостающими и
неизвестными опциями. Спека — `../spec.md`, «`Core.Es.Event.Codec`», «`Core.Es.Outbox`», «`Core.Es.Store.Opts`»,
«`Core.Repo.Pg.StateStored`», «Порядок работ», срез 2; ADR-0084. Образцы — `prototype/family-declaration`,
`prototype/family-aggregate`.

**Blocked by:** 15.

**Status:** ready-for-agent

- [ ] `Core.Es.Event.Codec`: `event:` → `family:`, `@es_aggregate_id` / `@es_by` — у семейства. Сверки —
  `CompileError` на строке `use`: `событие <E> не из семейства <F>`; `семейство <F> объявляет codec: <C>, а не <кодек>`.
- [ ] `derive!` и его тест на разные `__es_aggregate_id__` удалены; `__es_aggregate_id__/0` и `__codec_union__/0`
  кодека остались, `__es_by__` наружу не отдаётся.
- [ ] `Core.Es.Outbox`: `event:` → `family:`, `@type event` — тип семейства; `__es_event__/0` и
  `ensure_outbox_event!` остались; работает и у state-stored.
- [ ] `Es.Store.Opts.ensure_family_aggregate!/3` — `CompileError` с файлом и строкой `use`; вызов в
  `Es.Aggregate.Repo.Pg` (против его текущей `aggregate:`) и в `Repo.Pg.StateStored`; `ensure_aggregate_id!` остался.
- [ ] Все `use Core.Es.Event.Codec` и `use Core.Es.Outbox` в `lib/`, `test/`, фикстуре переведены.
- [ ] Тесты библиотеки: событие из `tags:` не из семейства; `codec:` семейства на чужой кодек; семейство кодека
  называет владельцем не агрегат `Repo.Pg` и не сущность `StateStored`; старая форма опций кодека — одно сообщение.
- [ ] `@moduledoc` `Core.Es.Event.Codec`, `Core.Es.Outbox`.
- [ ] Свод `14-events-outbox.md` (`Outbox` и кодек `family:`, примеры «Совместимость событий»). `make rules-check`.
- [ ] CHANGELOG: строки `use Core.Es.Event.Codec`, `use Core.Es.Outbox` и сверки кодека и владельца потока в пункте
  тикета 15; строка 2 «Версии библиотеки».
- [ ] Приёмка: `make` целиком; `make consumer-check` без новых предупреждений.
- [ ] После влития удаляется ветка `prototype/family-declaration`.
