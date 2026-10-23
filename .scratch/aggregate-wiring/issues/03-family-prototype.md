# 03: Прототип объявления семейства на копии фикстуры

Type: prototype
Status: resolved

Blocked by: 02

## Question

Собирается ли объявление `aggregate_id` / `by` на семействе, выбранное в тикете 02, без взаимного ожидания
компиляции? Проверка на копии `fixtures/consumer` (агрегат счёта):

- `make consumer-check` проходит;
- литеральные головы событий сохраняются: неверный id в `new` даёт предупреждение компилятора, как
  сейчас;
- `mix xref graph --label compile` — какие рёбра добавились и какие ушли.

Прототип делается на временной ветке или копии, ссылка на него — в ответе.

## Answer

Проверено 2026-10-23. Прототип — ветка `prototype/family-declaration` (коммит `2374b70`, от `f8cf70c`), не
сливается.

**Что в прототипе.**
- `Core.Es.Event.Family` (`lib/core/es/event/family.ex`): `aggregate_id:`, `by:` через `Helper.Opts.module!`,
  `__es_aggregate_id__/0`, `__es_by__/0`, `@before_compile` требует `@type t`.
- `Core.Es.Event`: опция `family:` — `Code.ensure_compiled!` семейства в теле модуля, значения запекаются в
  те же головы `new/5,6`, `@type t`, `@spec`; новая `__es_family__/0`. Старая форма `aggregate_id:` / `by:`
  оставлена, чтобы остальные агрегаты фикстуры собирались.
- Кодек: у семейства с `__es_aggregate_id__/0` берёт значения у него и сверяет `__es_family__() == event:` у
  каждого события `tags:`; иначе — прежний `derive!`.
- Фикстура: семейство счёта объявлено, пять событий — `family: Account.Event`.

**Результат.**
- `make consumer-check` — ok, 126 ожидаемых предупреждений, лишних нет. Сборка `--force` проходит:
  взаимного ожидания нет (семейство → `Account.ID`, `UserID`; событие → семейство; кодек → семейство и
  события).
- Литеральные головы сохранились: сценарии `scenarios/event_new.ex` D2, D2b, D2c (чужой id) и D3, D3b
  (чужой `by`) по-прежнему дают `incompatible types given to …Opened.new/5`.
- Негативные проверки: событие `Order.Event.Cancelled` в `tags:` кодека счёта → `CompileError` «событие … не
  из семейства …»; семейство без `@type t` → `CompileError` из `@before_compile`.

**`mix xref graph --label compile`, разница.**

```
+ account/event.ex          → account.ex, values/user_id.ex     # опции use семейства
+ account/event/<X>.ex ×5   → account/event.ex                  # family:
- account/event/<X>.ex ×5   → values/user_id.ex                 # by: ушёл
- account/event/{closed,frozen}.ex → account.ex                 # у остальных трёх ребро остаётся: Account.Name в нагрузке
```

Цикл перекомпиляции счёта: 7 → 8 файлов, семейство вошло в него
(`account.ex → codec → <X> → event.ex → account.ex`). Это цикл перекомпиляции, не ожидания: агрегат кодек
по-прежнему не грузит.

**Для реализации.**
- Событие с `family:` на модуль без `use Core.Es.Event.Family` в прототипе падает `UndefinedFunctionError`
  при раскрытии: в коде — `Helper.Opts.module!` с `exports: [__es_aggregate_id__: 0, __es_by__: 0]`.
- Семейство теперь — узел с compile-рёбрами: правка `Account.ID` или `UserID` перекомпилирует семейство и
  через него все события, как и раньше напрямую.
