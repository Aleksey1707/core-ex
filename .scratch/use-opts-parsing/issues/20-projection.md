# 20: Проекция — опции литералом при раскрытии

**What to build:** автор проекции получает ошибки `name:` / `events:` / `version:` / `personal:` при раскрытии
`use Core.Es.Projection`, а атрибут в них (`name: @name`) — `CompileError` «ожидается литерал». Спека —
`../spec.md`, «Проекция»; ADR-0085. Состав опций — по коду после `aggregate-wiring` 19.

**Blocked by:** 10; `.scratch/aggregate-wiring/issues/19-projection-by-family.md`.

**Status:** ready-for-agent

- [ ] `name:` / `events:` / `version:` / `personal:` — литералы при раскрытии; `declaration!/4` разобран на проверки
  при раскрытии.
- [ ] `repo:` / `codec:` — по состоянию после `aggregate-wiring` 19.
- [ ] Тесты: опечатка в ключе — при раскрытии, с меткой; `name: @name` — «ожидается литерал».
- [ ] CHANGELOG: накопительный пункт (текст — спека). Нет — завести вместе со строкой «Версия библиотеки» в
  `docs/rules/app/00-index.md`; есть — дописать фразу про `use Core.Es.Projection`.
- [ ] Файлы тикета сняты с храповика `excluded`; список опустел — `files: %{excluded: …}` удалён.
- [ ] Приёмка: `make` целиком; `make consumer-check` без новых предупреждений; `mix xref graph --label compile`
  фикстуры не изменился, у библиотеки compile-рёбра только уходят.
