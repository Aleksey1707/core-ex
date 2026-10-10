# 03: Виды поля `enum:` / `entity:` / `list:` / `type:` и `default:`

**Status:** ready-for-agent

**Blocked by:** 02.

**What to build:** плагин по полям покрывает типы, где кроме Prim есть enum, вложенные сущности, списки и сырые
значения, а строка jsonb, записанная до появления поля, загружается с `default:`. Спека — `../spec.md`, «Спека полей
плагина»; ADR-0056.

- [ ] `enum:` — модуль `Core.Enum` (иначе `CompileError`); дамп — атом как есть, голова `is_atom`; загрузка —
      `cast`, при `optional:` — `cast_optional`; отказ `cast` — ошибка загрузки.
- [ ] `entity:` — дамп `codec.dump/1`, загрузка `codec.load(Mod, raw)` через фасад; голова `%Mod{}`.
- [ ] `list:` — вложенная спека элемента любого вида, поэлементно в обе стороны; голова `is_list`; `optional:`
      внутри `list:` — `CompileError` (как у View).
- [ ] `type:` — скаляры `Core.View` плюс `:map`; значение как есть в обе стороны.
- [ ] `default:` — литерал при загрузке, если ключа нет или он `nil`; дамп поля обычный. `default:` с
      `optional: true` и `default:` при `loadable: false` — `CompileError`.
- [ ] Тесты фасада на каждый вид и на `default:`; тесты сборки на каждый новый `CompileError`.
- [ ] `fixtures/consumer`: плагин с `enum:` / `entity:` / `list:` без предупреждений.
- [ ] `docs/rules/11-domain.md`: виды поля и `default:` (только в плагине — развитие строки jsonb).
- [ ] `CHANGELOG.md`: дополняется пункт «Новое» о плагине по полям, нового пункта не заводится.
- [ ] `make` зелёный.
