# 32: Проекции: событие уничтожения ключа и чистка read-модели

**What to build:**
- **Сборка.** Проекция, чьи события несут поля `subject:`, объявляет событие уничтожения ключа (тогда по нему чистит
  ПДн субъекта) или `personal: false`; это проверяет сборка.
- **Case.** `Core.Es.ProjectionCase` ловит проекцию, которая падает на `%Destroyed{}` или оставляет открытое ПДн
  после события уничтожения ключа.
- **Сквозной путь.** После `destroy_key/3` → `run_until_idle` в read-модели нет ПДн субъекта, в том числе после
  пересборки.

**Blocked by:**
- [23: ПДн-значение в `es_events` и outbox: шифрование и расшифровка](23-personal-value-in-events-and-outbox.md)
- [24: Golden-фикстуры: уничтоженный вариант и построители тестов](24-golden-fixture-destroyed-variant.md)

**Status:** ready-for-agent

**Spec:** [Crypto-shredding: ПДн в событиях под ключом субъекта](../spec.md) — «Проекции и read-модель»,
«Тестовая поддержка в `lib/`»; ADR-0079

- [ ] Проверка `use Core.Es.Projection`: если у события из `events:` есть поле `subject:`, проекция MUST объявить
      `Core.Es.Personal.Event.KeyDestroyed` (его clause в `project/1` проверяет `Es.Check`) или `personal: false`.
      Ни того, ни другого или оба сразу — `CompileError`.
- [ ] Проекция с событием уничтожения ключа читает поток `"core.subject"`, и `await/3` получает clause на него.
- [ ] `Core.Es.Personal.Test.key_destroyed(subject_id, by:, at:)` — событие в той форме, в какой его пишет операция.
- [ ] `Core.Es.ProjectionCase`:
      - `project/1` на уничтоженном варианте — в откатываемом savepoint перед открытым: открытый прошёл, а
        уничтоженный дал исключение или `{:error, _}` — провал;
      - на каждой открытой фикстуре с полями `subject:` — `project/1`, затем `key_destroyed` каждого её субъекта,
        затем поиск открытых строковых wire-значений ПДн-полей в строках затронутых таблиц; находка — провал с
        таблицей и полем;
      - у `personal: false` поиск идёт сразу после фикстуры.
- [ ] Фикстуры:
      - `Core.EsFixture.Projection` объявляет `HolderSet` и событие уничтожения ключа и чистит ПДн;
      - сломанная пара в `test/support` их оставляет — case проверяется в обе стороны.
- [ ] Сквозной тест: `destroy_key/3` → `run_until_idle` → ReadRepo без ПДн субъекта; пересборка подъёмом `version:` —
      тоже без ПДн.
- [ ] Фикстура-потребитель: событие уничтожения ключа в `events:` проекции `activity`, маркеры `# expect:` — по
      факту.
- [ ] Свод:
      - `22-projections.md` «Объявление» — `personal:` ссылкой;
      - новая H2 «Персональные данные» после «Read-модели»: идентификатор субъекта рядом с ПДн, чистка по событию,
        заглушка SHOULD NOT, `personal: false`, отставание, пересборка;
      - `19-testing.md` «Проекции» — что делает `ProjectionCase` и предел поиска, `key_destroyed/2`, путь
        `destroy_key/3` → `run_until_idle`;
      - app/16 «Чек-лист перед включением» — кеш View с ПДн без TTL MUST NOT;
      - app/23 «Usecase уничтожения» — read-модель MUST NOT трогать, проекцию не ждать;
      - 23 — чек-лист «добавляю ПДн», часть про проекцию.
- [ ] `CHANGELOG.md`:
      - «Изменения контракта макросов» — `personal:` у `Projection`, `CompileError` проекции, новые проверки
        `ProjectionCase`;
      - сквозной пункт — `key_destroyed/2`.
- [ ] `make` зелёный.
