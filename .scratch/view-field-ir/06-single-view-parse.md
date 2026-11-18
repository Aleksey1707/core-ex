Status: resolved

# 06: View — один разбор поля

**What to build:** `use Core.View` разбирает декларацию полей один раз: `View.Opts.fields!` строит
`%Core.View.Field{}` с AST типа, формы и дампа, `Core.View` проецирует из него `__core_fields__/0`
и генерирует struct/new/type/Codec. Round-trip `%View.Field{} → %Core.Field{} → %View.Field{}` и
вторая сборка AST исчезают. Публичный контракт `use Core.View`, значения `new/1`, wire-форма дампа
и тексты `CompileError` не меняются. Спека — `.scratch/view-field-ir/spec.md`; кандидат 01
архитектурного обзора.

## Problem Statement

`Core.View.__using__` зовёт `Core.Field.declare!(fields, :view, …)`, который через
`View.Opts.fields!` уже построил полный `%View.Field{}` с проекциями, затем конвертирует его в
`%Core.Field{}` и теряет kind Prim (`Core.Field.view_spec/1`), а `Core.View.view_fields/1` строит
`%View.Field{}` заново и восстанавливает kind через `Core.Prim.leaf/1`. Первый набор AST
выбрасывается; `view_spec/1` существует в двух модулях в противоположных направлениях; `Meta`
прогоняет по View тождественную нормализацию. Новый вид требует 7–9 правок в 4–5 файлах, а
забытая конверсия даёт `FunctionClauseError` вместо `CompileError`.

## Решения

- **Один разбор в `Core.View`.** Приватные `core_fields/1` и `core_spec/1` проецируют
  `%View.Field{}` в `%Core.Field{}`: `spec: {:prim, Mod}`, `wire: Atom.to_string(name)`,
  `default: :none`, `subject: nil`, `personal: nil`. Новый модуль не заводится.
- **Роль `:view` уходит из `Core.Field`.** Удаляются клауза `declare!(spec, :view, …)`,
  `parse_view!/3`, `view_spec/1` и `:view` из `@type role`. `Core.Field` больше не знает View;
  `Spec.kinds(:view)` остаётся allowlist'ом грамматики View.
- **View больше не проходит через `Field.Meta`.** `View.Opts` сам проверяет `optional:`;
  `wire`/`default`/`personal`/`subject` у View отсутствуют. Из `Meta.Optional/Wire/Default`
  убирается роль `view`, матрица `meta_test` обновляется.
- **Мёртвый `View.Opts.prim_type_ast/1` удаляется.** `used_forms/1` + `reachable_forms/2`
  остаются как есть: к двойному разбору не относятся.
- **`__core_fields__/0` не меняет форму:** вид Prim без kind, те же `wire`/`optional?`/
  `default`/`subject`/`personal`. Тексты `CompileError` View и порядок полей — контракт.
- **Вне тикета:** `Core.Field`-фасад (`check_keys!`, делегаты, `inspect_hidden`),
  подписи на View (`@core_fields`, `Details`/`Walk`), общий нормализатор View и плагина
  (ADR-0056, OOS `field-spec-shared-normalizer.md`).
- **CHANGELOG не меняется:** изменение внутреннее; ADR-0097/0056 не пересматриваются.

## Тесты

- `use Core.View` остаётся единственным швом: `test/core/view_test.exs` (объявление, `new/1`,
  dump, `CompileError`) проходит без смысловых правок.
- `test/core/view_test.exs:82` проверяет `__core_fields__` без kind Prim — остаётся.
- `test/core/view/field_test.exs` (вид × проекция) и `test/core/field/spec_test.exs` (вид × хост)
  не меняются.
- Из `test/core/field_test.exs` удаляются проверки роли `:view` (`declare!(:view)`), поведение
  остаётся покрытым `use Core.View`.
- `test/core/field/meta_test.exs`: `view` уходит из `@roles`/`@matrix`; добавляется проверка
  «у View нет метаданных».
- `make consumer-check` обязателен: сборка всех View потребителей.

## Acceptance

- [x] `View.Opts.fields!` вызывается один раз; `View.Field.build` — один раз на поле.
- [x] `Core.Field.declare!(:view)`, `Core.Field.parse_view!/3`, оба `view_spec/1` удалены.
- [x] `__core_fields__/0`, `new/1` и dump дают прежние значения; тексты отказов прежние.
- [x] `Core.Field` не ссылается на `Core.View.*`; `Meta` не знает роль `view`.
- [x] `mix format --check-formatted`, `mix compile --warnings-as-errors`, целевые тесты и
  `make consumer-check` зелёные.

## Сделано

- `lib/core/view.ex`: `Opts.fields!` — единственный разбор; `core_fields/1` + `core_spec/1`
  проецируют `%View.Field{}` в `__core_fields__/0`; `view_fields/1` и `view_spec/1` удалены.
- `lib/core/field.ex`: удалены клауза `declare!(:view)`, `parse_view!/3`, `view_spec/1` и `:view`
  из `@type role`; ссылок на `Core.View.*` больше нет.
- `lib/core/view/opts.ex`: удалён мёртвый `prim_type_ast/1`.
- `lib/core/field/meta/{optional,wire,default}.ex`: роль `view` убрана из матрицы.
- Тесты: `field_test` больше не зовёт `declare!(:view)`; `meta_test` проверяет, что у View нет
  метаданных; `view_test` и `view/field_test` прошли без правок.

Проверка: `make format-check boundary-check spec-check layout-check rules-check xref
consumer-check` — зелёные; `mix credo --strict`, `mix dialyzer` — без замечаний;
`mix test` — 3506 passed, 10 excluded.
