# 02: Трассирующий тикет — плагин по полям с `prim:`

**Status:** resolved

**Blocked by:** 01.

**What to build:** автор объявляет однотиповый Codec-плагин опцией `fields: [{Type, spec}]` с видами `prim:`,
`optional:` и `wire:` — и получает `dump/2` и `load/3` без ручного кода: `InCodec.dump(entity)` даёт wire-map,
`InCodec.load(Type, wire)` — `{:ok, %Type{}}` или первую ошибку поля. Сборка сверяет спеку со struct. Спека —
`../spec.md`, «Спека полей плагина», «`use Core.Codec.Plugin, fields:`»; ADR-0056.

- [x] Опция `fields:` у `use Core.Codec.Plugin`: список пар `{Type, spec}`; ключ вне `types:` или повтор типа —
      `CompileError`.
- [x] Спека плагина: `prim:` (любой Prim, включая composite, кастомный kind и sensitive), `optional:`, `wire:`
      (строка; по умолчанию имя поля строкой); не Prim в `prim:` и неизвестный ключ — `CompileError` с именем
      плагина, типа и поля.
- [x] Ключи спеки строго равны полям struct без `__struct__` и `events`; расхождение в любую сторону —
      `CompileError` со списком лишних и недостающих.
- [x] `dump/2`: голова закрывает struct и каждое поле `%Prim{}` (с `nil` при `optional:`), код в
      `quote generated: true`; значения — `codec.dump/1`.
- [x] `load/3`: чтение через `field/2` (строковый и атомарный ключ), `codec.load(Prim, raw)`, первая ошибка — итог,
      лишние ключи игнорируются, struct собирается литералом; результат сужен до `{:ok, %Type{}} | {:error, _}`.
- [x] Плагин, все типы которого объявлены по полям, не требует ручных `dump/2` / `load/3`.
- [x] Тесты фасада: round-trip, `optional:` (`nil` и отсутствующий ключ), чтение по `wire:`, первая ошибка, игнор
      лишних ключей.
- [x] Тесты сборки (`Code.eval_quoted`): поле struct без спеки, поле спеки без struct, ключ вне `types:`, не Prim.
- [x] `fixtures/consumer`: плагин по полям без предупреждений; `# expect:` на опечатку в поле результата
      `InCodec.load` и на поле не того Prim в `dump`.
- [x] `docs/rules/11-domain.md`, «Codec (Prim и Entity)»: опция `fields:`, `prim:` / `optional:` / `wire:`, сверка
      со struct, загрузка литералом; `@moduledoc` `Core.Codec.Plugin`.
- [x] `CHANGELOG.md`, «Не выпущено»: «Новое» — плагин по полям; «Изменения контракта макросов» — опция `fields:`.
- [x] `make` зелёный, включая `consumer-check`.
