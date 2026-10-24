# 16: `Repo.Pg` и `StateStored` — одна проверка ключа

**What to build:** автор `use Core.Repo.Pg.StateStored` получает одну ошибку на неизвестный ключ, а не две, и все
ошибки опций `Repo.Pg` — при раскрытии с меткой `Repo.Pg:`; `query: from(…)` и захваты `to_entity:` / `to_model:` /
`to_view:` / `to_id:` / `default_filters:` остаются законными. Спека — `../spec.md`, «Repo.Pg»; ADR-0085.

**Blocked by:** 10; `.scratch/aggregate-wiring/issues/16-family-codec-outbox.md` (`ensure_family_aggregate!` в обоих
модулях).

**Status:** ready-for-agent

- [ ] `Repo.Pg`: `bind_quoted` → пролог при раскрытии. Выражения: `query:`, `to_entity:` / `to_model:` / `to_view:` /
  `to_id:` / `default_filters:`. Тексты без метки получили `Repo.Pg:`. `required_keys/0` / `optional_keys/0` удалены.
- [ ] `StateStored` при раскрытии проверяет свои ключи (`event_codec`, `outbox`, `children`) и обязательность
  усиленных (`to_entity`, `to_model`, `entity`, `id`), остаток отдаёт `use Core.Repo.Pg` как есть; неизвестные ключи и
  выражения остатка проверяет `Repo.Pg`. `own_keys/0` стал атрибутом.
- [ ] Проверка `exports: [domain: 3]` у `errors:` в `StateStored` ушла (её делает `validate_errors_module!` `Repo.Pg`);
  `ensure_version_mismatch!` и `ensure_aggregate_id!` остались.
- [ ] Длинный `quote` `Repo.Pg` (`docs/rules/DEBT.md`) не тронут.
- [ ] `@moduledoc` `Repo.Pg` называет опции-выражения; `@moduledoc` `StateStored` — «опции `Repo.Pg` плюс свои
  ключи».
- [ ] Тесты: опечатка в ключе `StateStored` — одна ошибка, при раскрытии, с меткой; нелитерал в опции-литерале —
  «ожидается литерал»; неверное выражение — в теле, с меткой.
- [ ] CHANGELOG: накопительный пункт (текст — спека). Нет — завести вместе со строкой «Версия библиотеки» в
  `docs/rules/app/00-index.md`; есть — дописать строку `use Core.Repo.Pg`, `use Core.Repo.Pg.StateStored`.
- [ ] Файлы тикета сняты с храповика `excluded`; список опустел — `files: %{excluded: …}` удалён.
- [ ] Приёмка: `make` целиком; `make consumer-check` без новых предупреждений; `mix xref graph --label compile`
  фикстуры не изменился, у библиотеки compile-рёбра только уходят.
