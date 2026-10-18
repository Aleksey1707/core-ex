# 24: Golden-фикстуры: уничтоженный вариант и построители тестов

**What to build:** `Core.Es.EventCompatCase` требует у текущего тега с полем `subject:` уничтоженный вариант
`destroyed/<тег>.json` и проверяет, что апкаст и `load` переживают `{"$pd": null}`. Тела фикстур и нагрузку с
`%Destroyed{}` для тестов `evolve` / `decide` / `project/1` отдаёт `Core.Es.Personal.Test`. Тикет не требует ни
БД, ни хранилища ключей.

**Blocked by:**
- [21: ПДн-поле нагрузки: `subject:`, маркер и уничтоженное значение в кодеке](21-payload-subject-marker.md)

**Status:** resolved

**Spec:** [Crypto-shredding: ПДн в событиях под ключом субъекта](../spec.md) — «Тестовая поддержка в `lib/`»;
ADR-0078

- [x] Требования к `destroyed/<тег>.json`:
      - у текущего тега с `subject:` вариант — MUST: проверяются тег в `type`, загрузка и `%Destroyed{}` в каждом
        поле `subject:`;
      - у источника `upcasts:` — загрузка апкастом, без требования уничтоженного значения в результате;
      - фикстура тега, которого нет в кодеке, или текущего тега без `subject:` — провал;
      - вариант один на тег.
- [x] Пятый инвариант: персональный Prim в загруженной фикстуре текущего тега лежит только в поле верхнего уровня с
      `subject:`.
- [x] Шифротекст в фикстуре даёт провал с кодом `:sealed_personal_value`. Case остаётся `ExUnit.Case` без БД и без
      хранилища ключей.
- [x] `Core.Es.Personal.Test`:
      - `destroyed(payload | %Es.Event{}, fields \\ :all)` — поле без `subject:` даёт `ArgumentError`;
      - `fixtures(event)` → `%{open: map(), destroyed: map() | nil}`, дамп через фасад.
- [x] Уничтоженные варианты `HolderSet` и `ContactSet`.
- [x] Тест `Account`:
      - `evolve` через `fold/2` на результате `destroyed/2`;
      - `decide` команды, которой нужно уничтоженное значение, — доменная ошибка.
- [x] Функции проверок case-модуля — на сломанных фикстурах `test/support`: нет варианта, посторонний вариант,
      персональный Prim вне `subject:`.
- [x] Свод:
      - `14-events-outbox.md` «Совместимость событий» — три строки: `subject:` на существующем поле — тег прежний;
        снятие `subject:` — MUST NOT; смена субъекта — новый тег;
      - `14-events-outbox.md` «Golden-фикстуры» — форма после расшифровки, уничтоженный вариант, пятый инвариант,
        заполненная вложенная сущность с ПДн, `fixtures/1`;
      - `11-domain.md` «Event-sourced» — `evolve/2` MUST принимать `%Destroyed{}`, а `decide/2` отвечает доменной
        ошибкой;
      - `19-testing.md` «Event-sourced агрегат» — `evolve` на `destroyed/2` MUST, `decide` SHOULD;
      - 23 — чек-лист «добавляю ПДн», части про фикстуры и тесты.
- [x] `CHANGELOG.md`:
      - «Изменения контракта макросов» — новые проверки `EventCompatCase`;
      - сквозной пункт — `Core.Es.Personal.Test`.
- [x] `make` зелёный.
