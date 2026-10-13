# 04: Изменение «было → стало»

**Status:** ready-for-agent

**Blocked by:** 03.

**What to build:** нагрузка «было → стало» объявляет одну подпись изменения (`use Core.Labels.Fields, change:`) и
выходит в сведения одним сведением `change` со сторонами `old` и `new`. Вид значения у `Core.Es.ValueChanged` —
из его `type:`, у ручного struct'а с полями `old_value` / `new_value` — из `value:` на языке спеки `fields:`.
Спека — `../spec.md`, «Модули домена», user stories 15–17; ADR-0063.

- [ ] `Details.build/1`: изменение — `%{label, kind: :change, old, new}`, стороны — `%{kind, value}` без подписи;
      сторона без значения — `value: nil`.
- [ ] Отказы сборки: `labels:` вместе с `change:`; ручной struct изменения без `value:`; `value:` у
      `Core.Es.ValueChanged`; `value:` без `change:`; struct без `old_value` / `new_value` под `change:`.
- [ ] Тесты: изменение `Core.Es.ValueChanged` с Prim и с Enum, ручной struct с `value: [text: …]` и
      `value: [list: …]`, отказы сборки.
- [ ] Фикстура-потребитель: нагрузка `Core.Es.ValueChanged` с подписью изменения; `make consumer-check` зелёный.
- [ ] Свод: механизм `change:` / `value:` — `docs/rules/11-domain.md`, «Подписи».
- [ ] `CHANGELOG.md` — дополняется пункт подсистемы подписей.
- [ ] `make` зелёный.
