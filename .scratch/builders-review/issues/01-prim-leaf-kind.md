# 01: Prim сам отдаёт leaf и kind

**Status:** needs-triage

**Blocked by:** None (can start immediately)

**Сила:** Strong. Правка небольшая, и, вероятно, закрывает баг.

**Файлы:**
- `lib/core/codec.ex` — `prim_chain` (~360);
- `lib/core/codec/plugin/fields.ex` — `leaf` (~168);
- `lib/core/labels/details.ex` — `plain_kind` (~169);
- `lib/core/labels/refs.ex` — `prim_role`;
- `lib/core/labels/completeness_case.ex` — `unkinded?` (~312);
- `lib/core/view/opts.ex` — `prim_kind!` (~233).

**Проблема.** В `Core.Prim` нет функции «leaf-модуль композита и его действующий kind». Есть только `unwrap/1` по значению. Поэтому пять вызывающих сами спускаются по `__domain_base__`.

`View.Opts.prim_kind!` композит не разворачивает: берёт `mod.__domain_kind__()` и получает `:composite`, которого нет в приводимых kind'ах. Судя по коду, `prim:` с композитом во View даёт `CompileError`, хотя `Codec.coercible?/1` и Redump композит разворачивают. Тестом это не проверено — первый шаг проработки.

**Что изменилось бы.** `Core.Prim` сам отвечает на вопрос «leaf и kind». Вызывающие перестают знать про `Prim.Compose`.

**Выигрыш.** Locality: знание о композите в одном module. Расхождение View закрывается. Leverage на пяти местах.

**ADR:** конфликта нет.
