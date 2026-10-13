# 04: Изменение «было → стало»

**Status:** resolved

**Blocked by:** 03.

**What to build:** нагрузка «было → стало» объявляет одну подпись изменения (`use Core.Labels.Fields, change:`) и
выходит в сведения одним сведением `change` со сторонами `old` и `new`. Вид значения у `Core.Es.ValueChanged` —
из его `type:`, у ручного struct'а с полями `old_value` / `new_value` — из `value:` на языке спеки `fields:`.
Спека — `../spec.md`, «Модули домена», user stories 15–17; ADR-0063.

- [x] `Details.build/1`: изменение — `%{label, kind: :change, old, new}`, стороны — `%{kind, value}` без подписи;
      сторона без значения — `value: nil`.
- [x] Отказы сборки: `labels:` вместе с `change:`; ручной struct изменения без `value:`; `value:` у
      `Core.Es.ValueChanged`; `value:` без `change:`; struct без `old_value` / `new_value` под `change:`.
- [x] Тесты: изменение `Core.Es.ValueChanged` с Prim и с Enum, ручной struct с `value: [text: …]` и
      `value: [list: …]`, отказы сборки.
- [x] Фикстура-потребитель: нагрузка `Core.Es.ValueChanged` с подписью изменения; `make consumer-check` зелёный.
- [x] Свод: механизм `change:` / `value:` — `docs/rules/11-domain.md`, «Подписи».
- [x] `CHANGELOG.md` — дополняется пункт подсистемы подписей.
- [x] `make` зелёный.
