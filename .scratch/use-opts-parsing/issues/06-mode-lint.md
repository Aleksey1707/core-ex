# 06: Механическая проверка канонического режима

Type: grilling
Status: resolved

Blocked by: 03

## Question

Какие нормы канонического режима проверяются механически, чем именно, а какие остаются ревью?

`literal!/3` и `validate!` ловят нелитерал и опечатку в ключе у вызова, но не нарушение в самом builder'е.
Кандидаты:

- `quote bind_quoted` внутри `defmacro __using__` в `lib/` (MUST NOT);
- `__using__` без `Macro.expand_literals` + `validate!` + `literal!/3` при раскрытии;
- опция из `@expression_keys` без своего `<key>!` в теле, опция-модуль в `@expression_keys`.

Решить: Credo-check в `scripts/credo_checks.exs` (по образцу `CredoChecks.FunctionExported`), скрипт по образцу
`layout_lint` с шагом `make`, или только ревью. Также — как проверка различает `__using__`, которые пересылают
открытый список (`DAO`).

## Comments

- Из «Ключи опций при композиции builder'ов»: кандидат — `def required_keys` / `optional_keys` в `lib/` вне
  протокола `Prim.Wrapper`.
- Из «Общие тексты `CompileError` опций»: кандидат — `raise CompileError` в коде разбора опций мимо
  `Helper.Opts.reject!/2` (локальные `where` / `reject!` / `fail!`); проверка должна отличать хуки
  `@before_compile` / `@after_compile`, где `fail!` с `file:` / `line:` остаётся.

## Answer

Механически проверяет один Credo-check `CredoChecks.UseOpts` в `scripts/credo_checks.exs` (по образцу
`FunctionExported`, шаг `credo`). Охват — только `lib/` библиотеки: `credo_checks.exs` в ярус `app/**` не
доставляется, у потребителя те же нормы проверяет ревью.

Проверяется:

- **`bind_quoted`**: `quote` с `bind_quoted:` в любом модуле, где определён `defmacro __using__`, а не только в теле
  `__using__`, чтобы проверку не обходили вынесением в `defp`.
- **Пролог разбора**: если параметр `__using__(opts)` используется (не `_opts`), первое его употребление — аргумент
  разрешённого входа (`Helper.Opts.expand!/3`, `Prim.Opts.prepare!`). Пролог стоит в самом `__using__`, а не в
  хелпере. Что `validate!` / `literal!` идут следом, проверяют ревью и тесты builder'а: без них нечего передать дальше.
  `DAO` (открытый список уходит в `use Ecto.Repo`) исключается `# credo:disable-for-next-line CredoChecks.UseOpts` с
  комментарием, почему; в проверку исключение не вшивается.
- **Функции ключей**: `def required_keys` / `optional_keys` / `expression_keys` в `lib/` вне протокола `Prim.Wrapper`
  (`lib/core/prim/wrapper.ex`).

Остаётся ревью:

- у опции из `@expression_keys` есть свой `<key>!` в теле: у обёрток `Prim` выражения объявлены протоколом, а
  проверяет их владелец (`Core.Prim` или обёртка); связь `unquote(ast)` с `<key>!` по AST не проследить;
- опция-модуль не объявлена выражением: это вопрос смысла опции, а не синтаксиса;
- `raise CompileError` мимо `Helper.Opts.reject!/2` и другие классы исключений. Признак «без `file:`» даёт около 220
  срабатываний, в том числе в `Guard` / `Bind` / `Error` вне нормы. Признак «модуль с `__using__`» не видит вынесенные
  `*.Opts`. `raise ArgumentError` в разборе опций от законного не отличить.

Включение — **храповиком**: проверка входит в первый срез (с `expand!` / `literal!` / `reject!`). Непереведённые
модули перечислены в `files: %{excluded: [...]}` проверки в `.credo.exs`, каждый срез вычёркивает свои, последний
удаляет пустой список. Отвергнуто: проверка последним срезом — переведённые builder'ы и новые модули до конца
перевода остались бы без защиты.

Где записано: `20-agreements.md` — у нормы о `__using__` строка «Проверяется: `mix credo --strict`
(`CredoChecks.UseOpts`)» с перечнем того, что проверяется; нормы, оставленные ревью, без «Проверяется». ADR — одна
строка: что ловится механически и почему остальное — ревью. Храповик — только в спеке (первый срез): он временный.
