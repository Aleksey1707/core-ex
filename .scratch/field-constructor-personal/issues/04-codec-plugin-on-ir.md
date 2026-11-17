# 04: Core.Codec.Plugin на общей декларации

**What to build:** Codec-плагин регистрирует типы (`types:`) и читает их общую декларацию
`__core_fields__`, а не объявляет поля повторно. Декларативный тип получает сгенерированные
`dump/2`/`load/3` и redump-спеку; тип без декларации требует ручные клаузы; `Core.Union` получает
семейную загрузку по адресу автоматически. `fields:`/`variants:` как способ объявить поля/адреса
удаляются. Смешанный плагин (часть типов декларативные, часть ручные) допустим; `loadable: false`
и запрет ручной клаузы на декларативный тип сохраняются.

**Blocked by:** 02, 03

**Status:** resolved

- [x] `use Core.Codec.Plugin, types:` читает `__core_fields__` декларативных типов и порождает dump/load; поля не объявляются в плагине повторно.
- [x] Тип без декларации требует ручные `dump/2`/`load/3`; ручная клауза на декларативный тип — `CompileError` «never match».
- [x] `Core.Union`-тип получает семейную загрузку по адресу автоматически; `fields:`/`variants:` как опции объявления удалены.
- [x] Redump-спека выводится из общей декларации; ручные типы объявляют её как раньше.
- [x] Round-trip через фасад по всем видам, включая `union:` с Prim-вариантами и вариантами с ручным Codec, проходит; `loadable: false` даёт только dump.

## CHANGELOG

### Ломающие изменения контракта

- `use Core.Codec.Plugin` больше не принимает `fields:` и `variants:` — неизвестная опция даёт
  `CompileError`. Тип объявляется декларацией (`use Core.Struct`, `use Core.Es.Event.Payload`,
  `use Core.Es.ValueChanged`), а плагин регистрирует его в `types:`; состав семейства объявляет
  модуль семейства (`use Core.Union`, `union:` у плагина). Было:
  `use Core.Codec.Plugin, fields: [{T, a: [prim: P]}]` → стало: `use Core.Struct, fields: [a: [prim: P]]`
  у `T` и `use Core.Codec.Plugin, types: [T]`; было `union: F, variants: [{V, "v", a: [prim: P]}]` →
  стало `use Core.Union, variants: [{V, "v"}]` у `F` и `use Core.Codec.Plugin, union: F`.
- Декларативный тип получает `dump/2`/`load/3` и redump-спеку из одной декларации. `default:` при
  загрузке — типизированное значение поля, а не wire-литерал: отсутствующий wire-ключ подставляет
  его без dump/load, явный `null` не заменяет (у `optional: true` это `nil`, у обязательного поля —
  ошибка загрузки). Прежний wire-литерал в `default:` надо заменить типизированным значением.
- Тип без `__core_fields__/0` требует ручных `dump/2`/`load/3` (и `redump_spec/1` для пере-дампа);
  ручная клауза на декларативный тип, вариант или семейство с выведенной загрузкой — `CompileError`
  «never match». `__codec_variants__/0` удалён: реестр вариантов — `Core.Union.variants/1`.
- `Core.Outbox.Record` и `Core.Outbox.RecordError` объявлены через `Core.Struct`; `t()` у них
  генерируется (у `Record` `payload`/`headers` — `map()`). Wire-форма и функции не изменились.
