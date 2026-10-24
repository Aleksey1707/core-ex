# 13: Labels — пролог при раскрытии и общий префикс

**What to build:** автор меток получает ошибки опций `use Core.Labels.*` и `use Core.Web.Event` при раскрытии, в
форме `<метка>: <ключ>…` вместо `"<label> <Module>:"`, а захваты (`with: &Mod.fun/1`, `text: &Mod.fun/1` внутри
`fields:` / `value:`, `user_ref: [dump: &Mod.fun/2, …]`) по-прежнему законны. Переводятся `Labels.Event` / `.ID` /
`.Values` / `.Text` / `.Fields` и `Web.Event`. Спека — `../spec.md`, «Labels»; ADR-0085.

**Blocked by:** 10.

**Status:** ready-for-agent

- [ ] `quote bind_quoted` → пролог при раскрытии. Выражения: `Labels.Text` `with:`, `Labels.Fields` `fields:` /
  `value:`, `Web.Event` `user_ref:` — уходят AST-ом в `<key>!`.
- [ ] `required_keys/0` / `optional_keys/0` удалены.
- [ ] Локальные `where/1` и `reject!` удалены, тексты через `Helper.Opts.reject!/2`; `fail!` хуков `@after_compile` с
  `file:` / `line:` не тронут.
- [ ] `@moduledoc` builder'ов называют опции-выражения.
- [ ] Тесты: опечатка в ключе — при раскрытии, с меткой; нелитерал в опции-литерале — «ожидается литерал»; неверное
  выражение — в теле, с меткой.
- [ ] CHANGELOG: накопительный пункт (текст — спека). Нет — завести вместе со строкой «Версия библиотеки» в
  `docs/rules/app/00-index.md`; есть — дописать строки `use Core.Labels.Text`, `use Core.Labels.Fields`,
  `use Core.Web.Event`.
- [ ] Файлы тикета сняты с храповика `excluded`; список опустел — `files: %{excluded: …}` удалён.
- [ ] Приёмка: `make` целиком; `make consumer-check` без новых предупреждений; `mix xref graph --label compile`
  фикстуры не изменился, у библиотеки compile-рёбра только уходят.
