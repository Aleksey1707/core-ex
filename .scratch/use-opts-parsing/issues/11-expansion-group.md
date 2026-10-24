# 11: Пролог группы «раскрытие»

**What to build:** builder'ы, которые уже проверяют опции при раскрытии, переходят на общий пролог `expand!` →
`validate!` → `literal!` и дают ошибки опций в форме `<метка>: <ключ>…` через `reject!/2`: `Es.Aggregate`,
`Es.Aggregate.Process`, `Es.Cmd`, `Repo.Pg.Schema`, `View` (`View.Opts`) и шесть case-модулей (`Enum.DocsCase`,
`Es.EventCompatCase`, `Es.ProjectionCase`, `Es.Personal.KeyStoreCase`, `Labels.CompletenessCase`,
`Repo.ConstraintErrorsCase`). Контракт не ломается. Спека — `../spec.md`, «S1 — пролог группы «раскрытие»»;
ADR-0085.

**Blocked by:** 10.

**Status:** ready-for-agent

- [ ] `Macro.expand_literals` в прологе заменён на `expand!` + `validate!` + `literal!` у всех builder'ов тикета.
- [ ] Тексты через `reject!`; `View.Opts.where/2` (`", поле <name>"`) удалён, путь идёт через `: `.
- [ ] Мёртвые `required_keys/0` / `optional_keys/0` у `Repo.Pg.Schema` удалены.
- [ ] Проверки по модулям (`module!`) остались при раскрытии; хуки `@before_compile` / `@after_compile` (`Es.Cmd`,
  `Es.Aggregate`, `Repo.Pg.Schema`) не тронуты.
- [ ] Тесты builder'ов: опечатка в ключе — при раскрытии, с меткой; нелитерал в опции — «ожидается литерал». Тесты,
  где список опций передаётся выражением целиком, переписаны.
- [ ] Если `literal!` нашёл ранее принятый нелитерал — строка накопительного пункта CHANGELOG (как в тикетах 12–18,
  20); иначе CHANGELOG не трогается.
- [ ] Файлы тикета сняты с храповика `excluded`; список опустел — `files: %{excluded: …}` удалён.
- [ ] Приёмка: `make` целиком; `make consumer-check` без новых предупреждений; `mix xref graph --label compile`
  фикстуры не изменился, у библиотеки compile-рёбра только уходят.
