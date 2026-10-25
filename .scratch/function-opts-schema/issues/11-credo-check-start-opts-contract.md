# 11: Включение `CredoChecks.OptsSchema` и свёртка `StartOpts`

**What to build:** новая функция библиотеки, читающая свои опции мимо схемы, валит `make` на
Credo; `StartOpts` больше не второй язык проверки опций — в нём остались только custom-валидаторы
и проверки элементов дерева.

Спека — «Правило свода и проверка», «Custom-валидаторы вместо `Core.Helper.StartOpts`».

**Blocked by:** 03, 04, 05, 06, 08, 09, 10

**Status:** ready-for-agent

- [ ] `CredoChecks.OptsSchema` (только `lib/`): срабатывает на `Keyword.validate!(opts, …)` и на
      чтение `Keyword.get/fetch/fetch!(opts, …)` / `opts[:…]` в публичной функции без
      `@opts_schema`.
- [ ] Исключения проверки: обратные вызовы с `@impl` (протоколы, behaviour, PromEx), модули
      разбора опций (`Helper.Opts`, `Prim.Opts`, `Store.Opts`, `Codec.Plugin.Opts`, `Snapshot`,
      `Prim.Wrapper`), функции, передающие `opts` целиком в вызов.
- [ ] Тесты проверки в `test/scripts/credo_checks_test.exs`: срабатывания и каждое исключение.
- [ ] Проверка подключена в `.credo.exs`; `mix credo --strict` на `lib/` зелёный без исключений по
      файлам.
- [ ] `StartOpts`: функции, заменённые встроенными типами NimbleOptions, удалены; остаются
      custom-валидаторы, `process!/3`, `unique!/4`; `@moduledoc` обновлён.
- [ ] `20-agreements.md`: в разделе о схеме опций — «Проверяется: `mix credo --strict`
      (`CredoChecks.OptsSchema`)»; `make rules-check` зелёный.
- [ ] `make` зелёный.
