# 19: Персональный Prim: `personal: true`

**What to build:** автор домена помечает Prim `personal: true`. Значение, как у `sensitive:`, не печатается ни в
`inspect/1`, ни в `detail` отказа, но, в отличие от `sensitive:`, проходит read-путь (`Core.View`, Redump) и
показывается клиенту.

Это первый срез механизма ПДн: с ним появляется свод 23 в обоих ярусах со skill `personal-data`.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

**Spec:** [Crypto-shredding: ПДн в событиях под ключом субъекта](../spec.md) — «Разметка» (`personal: true`),
«Кодек событий: маркер и уничтоженное значение» (`load_composite/3`), «Своды, README, skills, CHANGELOG»; ADR-0073

- [ ] Опция `personal:` есть у всех Prim-обёрток: булева, по умолчанию `false`. Интроспекция — `__domain_personal__/0`
      рядом с `__domain_sensitive__/0`.
- [ ] Значение скрывается так же, как у `sensitive:`: `inspect/1` его не показывает, а `detail` отказа `new` и вся
      cause-цепочка дают `{:redacted, n}` / `:redacted`.
- [ ] `Prim.Compose` наследует `personal` от базы. Понижение — `CompileError`, как у `sensitive:`.
- [ ] `Core.View` и Redump принимают персональный Prim. Флаги независимы, оба вместе допустимы.
- [ ] `Core.Codec.load_composite/3` редактирует ошибку базы по флагу композита (`sensitive` или `personal`).
      `sensitive`-композит над обычной базой больше не отдаёт сырое значение в `detail`.
- [ ] Тесты:
      - `refute inspect(...) =~` — фикстура персонального Prim в `test/support`;
      - `detail` отказа;
      - наследование и запрет понижения;
      - View и Redump;
      - `load_composite/3` для обоих флагов.
- [ ] Свод:
      - `docs/rules/23-personal-data.md` — H1 «Персональные данные», раздел «Разметка» (пока о `personal: true`);
      - `docs/rules/app/23-personal-data.md` — раздел «Вывод»: извлечённое ПДн-значение не попадает в `raise`,
        `Logger.*` и атрибуты span'а;
      - доставка: skill `personal-data`, строки карт `CLAUDE.md` и `00-index.md`, строка `23` таблицы «Нумерация»
        `app/00-index.md`;
      - `make rules-check` зелёный.
- [ ] Слоевые своды:
      - `11-domain.md` — `personal:` в листинге и таблице эффектов Prim;
      - `12-errors.md` — H3 «Prim: `personal: true`»; перенос ПДн из списка `sensitive:` делает тикет 23;
      - `21-observability.md` — новая H2 «Персональные данные в выводе» с Prim.
- [ ] `CHANGELOG.md` — заводится раздел «Не выпущено»:
      - «Новое» — сквозной пункт «ПДн в событиях: шифрование под ключом субъекта и уничтожение ключа» с первой
        частью (`personal: true`);
      - «Изменения контракта макросов» — пункт с `personal:` у Prim;
      - «Ломающие изменения контракта» — новая тема 23 (skill и строка в `AGENTS.md` потребителя, иначе падает
        `rules_lint --consumer`) и `load_composite/3`.
- [ ] `make` зелёный.
