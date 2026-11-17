# 05: Нагрузка события и ValueChanged на IR + ПДн-план

**What to build:** `Core.Es.Event.Payload` и `Core.Es.ValueChanged` переходят на общий IR и
порождают интроспекцию ПДн-плана `__es_personal__/0` (места и субъекты по модулям событий) вместо
`__es_subjects__/0`. План строится рекурсивным обходом декларации: `personal:` у Prim/поля,
`subject:` (`:aggregate_id`, `{:payload, field}`, локальное поле), эскалация границы для `set:` и
ключа `map:`. `Payload.new/N`, `draft/1` и guard `dump` отвергают `%Destroyed{}` на любом месте
записи по плану. Шифрование на этом шаге ещё не включается — только декларация, план и защита
записи.

**Blocked by:** 04

**Status:** ready-for-agent

- [ ] `Payload`/`ValueChanged` на IR; `Core.Es.Event.Codec` порождает `__es_personal__/0` с путями и субъектами вместо `__es_subjects__/0`.
- [ ] Обходчик находит ПДн-места рекурсивно: `personal:` у Prim/поля, `subject:`-ссылки трёх видов, default `:aggregate_id`.
- [ ] `subject:` в поддереве без ПДн и переопределение `subject:` под `personal: true` — `CompileError`; непрозрачный тип требует `personal: true/false`.
- [ ] `Payload.new/N`, `draft/1` и guard `dump` отвергают `%Destroyed{}` на любой глубине записи; `ValueChanged` применяет план к `old_value` и `new_value`.
- [ ] Тесты нагрузки события и `ValueChanged` обновлены; план проверяется через поведение, а не как публичный контракт формы.
