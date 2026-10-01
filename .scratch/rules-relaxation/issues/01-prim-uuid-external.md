# 01: `version: :external` у `Core.Prim.UUID` и MAY «внешний идентификатор»

**What to build:** автор event-sourced агрегата, чей неизменяемый естественный ключ — UUID внешнего
источника, объявляет id потока `use Core.Prim.UUID, version: :external` и использует UUID источника
как есть. У такого Prim нет `new/0` и `from_key/1` — выпустить id в обход источника нельзя, вызов
`new/0` ловится на сборке; разбор принимает UUID любой версии; `check_version:`, `namespace:`,
`scope:` рядом с `:external` дают `CompileError`. Свод разрешает эту форму условием «UUID уникален на
все виды, которые грузятся из источника»; в остальных случаях правило UUIDv5 от ключа (ADR-0017)
прежнее.

**Blocked by:** None (can start immediately)

**Status:** done

**Spec:** [Ослабление свода по отступлениям потребителя](../spec.md)

**ADR:** [0036 — идентификатор потока — UUID источника](../../../docs/adr/0036-stream-id-external-uuid.md)

- [x] `version:` принимает `:external`; `new/0` и `from_key/1` не генерируются
- [x] `new/1` принимает UUID версий 1, 4, 5, 7
- [x] `CompileError` на `check_version:`, `namespace:`, `scope:` при `:external` — сообщения в стиле
      существующих
- [x] round-trip через профиль кодека, как у остальных версий
- [x] `@moduledoc` билдера описывает форму
- [x] свод: форма — в `11-domain.md`, «Типизированные обёртки»; MAY — в `app/13-repos.md`,
      «Уникальность без индекса состояния», со ссылкой на ADR-0036
- [x] CHANGELOG, «Изменения контракта макросов»: новая опция, «было → стало» для Prim с
      `version: <N>, check_version: false` над UUID источника
- [x] тем же коммитом — ADR-0036 и термин «Внешний идентификатор» в `CONTEXT.md` (уже написаны,
      не закоммичены)
- [x] `make` зелёный
