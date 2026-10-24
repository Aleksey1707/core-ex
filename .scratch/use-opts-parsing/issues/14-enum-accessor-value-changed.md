# 14: `Enum`, `Context.Accessor`, `Es.ValueChanged` — пролог при раскрытии

**What to build:** автор enum, аксессора контекста и события изменения значения получает ошибки опций при раскрытии
`use`; `values: @values` у `Enum` даёт `CompileError` «ожидается литерал», `name: first_line(@moduledoc)` остаётся
законным. Спека — `../spec.md`, «Тело-мелкие»; ADR-0085.

**Blocked by:** 10.

**Status:** ready-for-agent

- [ ] `quote bind_quoted` → пролог при раскрытии у `Enum`, `Context.Accessor`, `Es.ValueChanged`.
- [ ] Выражение — только `Enum` `name:`; `values:` (`~w()a`) и остальные опции — литералы.
- [ ] `required_keys/0` / `optional_keys/0` удалены.
- [ ] `@moduledoc` `Enum` называет `name:` опцией-выражением.
- [ ] Тесты: опечатка в ключе — при раскрытии, с меткой; `values: @values` — «ожидается литерал»; `name: @n` при
  `@n 1` — в теле, с меткой. Вызовы с нелитеральным `values:` в `test/` и фикстуре переведены на литерал.
- [ ] CHANGELOG: накопительный пункт (текст — спека). Нет — завести вместе со строкой «Версия библиотеки» в
  `docs/rules/app/00-index.md`; есть — дописать строку `use Core.Enum`.
- [ ] Файлы тикета сняты с храповика `excluded`; список опустел — `files: %{excluded: …}` удалён.
- [ ] Приёмка: `make` целиком; `make consumer-check` без новых предупреждений; `mix xref graph --label compile`
  фикстуры не изменился, у библиотеки compile-рёбра только уходят.
