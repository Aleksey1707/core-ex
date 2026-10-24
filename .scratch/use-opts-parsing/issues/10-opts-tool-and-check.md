# 10: `Helper.Opts` и `CredoChecks.UseOpts` на примере `Core.Repo`

**What to build:** автор builder'а библиотеки получает общий пролог разбора опций `use`:
`Core.Helper.Opts.expand!/3` → `validate!` → `literal!/3` и `reject!/2` с одним префиксом. `mix credo --strict`
предупреждает на `quote bind_quoted:` в модуле с `__using__`, на пролог мимо `expand!` / `Prim.Opts.prepare!` и на
функции ключей вне `Prim.Wrapper`; непереведённые builder'ы перечислены в храповике `files: %{excluded: …}`. Сквозной
пример — `Core.Repo`: `only: ~w(…)a` раскрывает `expand!` вместо отдельного `Macro.expand`, ошибки опций идут через
`reject!`. Норма «Опции `use`» входит в свод тем же коммитом. Спека — `../spec.md`, «`Core.Helper.Opts` (S1)»,
«`CredoChecks.UseOpts` (S1)», «S1 — пролог группы «раскрытие»», «Документация, свод, CHANGELOG»; ADR-0085. Образец —
ветка `prototype/use-opts-mode` (`1e1cd7d`), не источник истины.

**Blocked by:** `.scratch/aggregate-wiring/issues/14-opts-validate-one-error.md` (`Opts.validate!`): оба правят
`Core.Helper.Opts`.

**Status:** ready-for-agent

- [ ] `expand!/3`: список опций не литеральным keyword-AST — `CompileError` «ожидается литеральный keyword, получено
  <`Macro.to_string`>»; значения раскрываются `Macro.expand_literals`, сигилы `~w()a` / `~D[]` / `~U[]` —
  `Macro.expand`, унарный минус над числом сворачивается, обход идёт в списки и пары.
- [ ] `literal!/3`: опции из `expression_keys` возвращаются AST, остальные вычислены; нелитерал — «<метка>: <ключ>:
  ожидается литерал, получено <`Macro.to_string`>».
- [ ] `reject!/2` — `CompileError` «<where>: <message>»; через него идут все `raise` самого `Helper.Opts`, хвост
  «задано» сменён на «получено». Value-вариант `binary_value!/3` для `<key>!` в теле.
- [ ] `@moduledoc` `Helper.Opts` описывает пролог, опцию-литерал, канал выражения и формат текстов.
- [ ] Тесты `Helper.Opts`: `expand!` (сигилы, унарный минус, список выражением), `literal!` (кортеж, struct, захват,
  атрибут), `reject!/2` — формат текста.
- [ ] `CredoChecks.UseOpts` — по образцу `CredoChecks.FunctionExported`, включён только для `lib/`; тест по образцу
  теста `FunctionExported`: `bind_quoted` в `defp` модуля с `__using__`, пролог мимо `expand!`, `_opts`, функции ключей
  вне `Prim.Wrapper`, `credo:disable`.
- [ ] Храповик `excluded` — файлы builder'ов тикетов 11–20; `Core.Repo` в нём нет.
- [ ] `DAO` исключён `# credo:disable-for-next-line CredoChecks.UseOpts` с комментарием (открытый список уходит в
  `use Ecto.Repo`); в саму проверку исключение не вшито.
- [ ] `Core.Repo`: пролог `expand!` → `validate!` → `literal!`, тексты через `reject!`, мёртвые `required_keys/0` /
  `optional_keys/0` удалены. Тесты builder'а: опечатка в ключе — при раскрытии, с меткой; нелитерал в опции —
  «ожидается литерал».
- [ ] Свод: абзац «Параметры __using__ макроса…» в `docs/rules/20-agreements.md`, «Стиль кодирования», заменён
  подразделом «Опции `use`» по тексту спеки; строки про `use` построчно и `~w()a` остаются. Строка про
  `Helper.Opts.validate!` в `docs/rules/12-errors.md` сверена. `make rules-check`.
- [ ] CHANGELOG не трогается: контракт не ломается. Если `literal!` нашёл ранее принятый нелитерал — это строка
  накопительного пункта (как в тикетах 12–18, 20).
- [ ] Приёмка: `make` целиком; `make consumer-check` без новых предупреждений; `mix xref graph --label compile`
  фикстуры не изменился, у библиотеки compile-рёбра только уходят.
