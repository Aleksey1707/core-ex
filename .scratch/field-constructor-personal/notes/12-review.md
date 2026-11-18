# Тикет 12 — закрытие замечаний code-review

Ветка `fcp/12` от `field-constructor-personal`; правки только по замечаниям осей Standards и Spec.

## Исправлено

1. **`%Destroyed{}` на записи нагрузки-сущности.** `dump` нагрузки `:plugin`/`:prim` перед дампом
   зовёт `Core.Es.Personal.Plan.assert_writable!/3` по плану значения (`runtime_places/1`):
   уничтоженное значение на вложенном месте даёт `ArgumentError`, а не маркер с телом `{}`.
   Покрыто `payload_personal_test` (нагрузка-сущность `Itinerary.Step`) и `plan_test`
   (места `union:`/`type: :map`).
2. **Типы записи у события.** `@spec draft`/`@spec new` и тип `draft/1` — `Core.Field.write_type/1`
   (`write_t()`, если он есть, иначе `t()`); выбор отложен в `__before_compile__`, потому что при
   раскрытии `use` вложенная нагрузка ещё не собрана. `Payload.new/N` и `ValueChanged.new/2`
   возвращают `write_t()`.
3. **`ProjectionCase` ловит забытое `%Destroyed{}`.** После успешного `project/1` на уничтоженном
   варианте результат обходится по term'у; найденное место — `{:destroyed_left, путь}` в
   `destroyed_failed`. Покрыто `projection_case_test` (маскирование — `:ok`, оставленное значение —
   провал).
4. **`union:` в ПДн-обходчике — fail-closed.** Варианты читаются `Core.Union.variants/1`: если
   декларативный вариант или Prim-вариант несёт ПДн, поле требует `personal: true`; без флага и с
   `personal: false` — `CompileError` с путём. Семейство без реестра (`types/0`) остаётся
   непрозрачным, как раньше. Покрыто `payload_personal_test` и `plan_test`.
5. **`Core.Es.Personal.State.dump/1` / `load/1`.** Рекурсивный маппинг `%Destroyed{}` ↔
   `{"$pd": null}`; живое ПДн открыто, порт не зовётся. Фикстура `state_stored` переведена на него,
   тест без вызова порта — `state_test.exs`. Свод — `23-personal-data.md`, «Состояние в памяти».
6. **Абсолютные пути** в `notes/01-design.md` заменены относительными; новых абсолютных путей
   нет.
7. **Комментарии у `String.to_atom/1`** в `Plan.wire_step/1` и `Payload.wire_step/1`: wire-ключи
   объявления, не данные границы.
8. **`EventCompatCase`** переиспользует `Core.Field.hide_personal/2`; `hide_places/hide_at` удалены,
   в `hide_place/2` добавлен спуск в поле struct'а (пути `Inspect` его не используют).
9. **`Core.Es.Cmd`** ищет место одним обходом `Core.Field.personal_places/3`; текст пути собирается
   из него (контейнер назван видом), владелец — модуль, где поле стало местом. Явная ПДн-граница
   (`personal: true`) по-прежнему отличается от Prim, персонального по своей декларации.
10. **`Core.Web.Event.dump_open/dump_plain`** — одна клауза `personal`/`personal_false` с
    `when tag in [...]`.
11. **`Core.Union.variants!/2`** — второй аргумент убран из `@doc false` функции и `__using__`.

## Оставлено в `docs/rules/DEBT.md`

- `payload` в OpenAPI-схеме — открытая схема с описанием маркера: у `Web.Event` нет объявления
  формы нагрузки.
- Четыре обхода значения по пути (`Field.hide_place`, `Plan.mark_at`, `Wire.collect/traverse`,
  `Web.Event.dump_value`): один обход потребовал бы одного представления пути.
- `Web.Event` дампит нагрузку по IR вторым путём: фасад не дампит `%Destroyed{}`.
- `ValueChanged`/`Struct` зовут `Payload.new_guard/new_body/inspect` — общий конструктор вне спеки.
- `Field.Meta`-обработчики принимают `map()` контекста, а не `%Field{}`.
- `kind: :domain` у `Core.Union.Variant` против `:entity` в грамматике полей.

## Проверка

`mix test` (без `:rabbit_stream`/`:kafka`, `MIX_TEST_PARTITION=3`) — 3505 passed, 10 excluded.

Полный `make DOCKER=true MIX_TEST_PARTITION=3` — зелёный: boundary-check, rules-check,
layout-check, spec-check, format-check, compile, compile-no-optional, consumer-check, deps-clean,
xref, dialyzer (`Total errors: 0`), test (3505 passed, 10 excluded), credo (`--strict` и
`-C consumer`), audit.
