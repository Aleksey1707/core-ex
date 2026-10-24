# 18: Es-кодек — `Es.Event.Codec`, `Es.Outbox`, `Es.Event.TagsCase`

**What to build:** автор кодека событий, outbox и теста тегов получает ошибки опций при раскрытии; `tags: @tag_by_mod`
и `upcasts: @upcasts` остаются законными, `type:`, `except_tags:` / `except_types:` — только литералы. Спека —
`../spec.md`, «Es-кодек»; ADR-0085. Состав опций — по коду после `aggregate-wiring` 16.

**Blocked by:** 15; `.scratch/aggregate-wiring/issues/16-family-codec-outbox.md`.

**Status:** ready-for-agent

- [ ] `Es.Event.Codec`: выражения — `tags:`, `upcasts:`; `type:` — литерал. `tags!` / `upcasts!` остались `<key>!`,
  `mods!` — по состоянию после `aggregate-wiring` 16 (`derive!` там удаляется). Мёртвые `required_keys/0` /
  `optional_keys/0` удалены.
- [ ] `Es.Outbox`: мёртвые `required_keys/0` / `optional_keys/0` удалены, пролог на `expand!` / `literal!`.
- [ ] `Es.Event.TagsCase`: `except_tags:` / `except_types:` — литералы при раскрытии; `except_tags!/1` /
  `except_types!/1` остаются функциями проверки (если их зовёт тест) или уходят — по коду.
- [ ] `@moduledoc` `Es.Event.Codec` называет опции-выражения.
- [ ] Тесты: опечатка в ключе — при раскрытии, с меткой; нелитерал в опции-литерале — «ожидается литерал»; неверное
  выражение — в теле, с меткой.
- [ ] CHANGELOG: накопительный пункт (текст — спека). Нет — завести вместе со строкой «Версия библиотеки» в
  `docs/rules/app/00-index.md`; есть — дописать строку `use Core.Es.Event.Codec` и фразу про
  `use Core.Es.Event.TagsCase`.
- [ ] Файлы тикета сняты с храповика `excluded`; список опустел — `files: %{excluded: …}` удалён.
- [ ] Приёмка: `make` целиком; `make consumer-check` без новых предупреждений; `mix xref graph --label compile`
  фикстуры не изменился, у библиотеки compile-рёбра только уходят.
