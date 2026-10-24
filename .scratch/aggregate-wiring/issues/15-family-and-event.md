# 15: Семейство событий и `family:` у события

**What to build:** автор агрегата объявляет идентификатор и автора событий один раз — на семействе
`use Core.Es.Event.Family, aggregate:, aggregate_id:, by:, codec:` (и `@type t`), а событие ссылается на него одной
опцией `family:`. Чужой ID или автор в `Event.X.new` по-прежнему даёт предупреждение сборки; семейство без `@type t` —
`CompileError`; `aggregate:` / `codec:` семейства на несуществующий или чужой модуль — предупреждение сборки
семейства. Старая форма `use Core.Es.Event, aggregate_id:, by:` — `CompileError` с недостающими и неизвестными
опциями. Кодек и `Outbox` пока остаются на `event:` (это тикет 16): `event:` указывает на модуль семейства, `derive!`
продолжает работать. Спека — `../spec.md`, «`Core.Es.Event.Family` (новый)», «`Core.Es.Event`»,
«`Core.Es.Personal.Event`», «Порядок работ», срез 2; ADR-0084. Образцы — ветки `prototype/family-declaration`,
`prototype/family-aggregate`, `prototype/projection-wiring` (`codec:` у семейства), не источник истины.

**Blocked by:** 14.

**Status:** resolved

- [x] `Core.Es.Event.Family`: опции обязательны, `Opts.validate!`; `aggregate_id:` / `by:` — `Helper.Opts.module!`;
  `aggregate:` / `codec:` — `Helper.Opts.atom!` без загрузки, алиас раскрывается в контексте функции (ребро xref —
  runtime, цикла семейство ↔ кодек / агрегат нет). Генерирует `__es_aggregate__/0`, `__es_aggregate_id__/0`,
  `__es_by__/0`, `__es_codec__/0`.
- [x] `@before_compile`: нет `@type t` — `CompileError`.
- [x] `@after_verify` — `IO.warn` с файлом семейства, не `raise`: `aggregate:` не найден; `codec:` не кодек этого
  семейства (`__codec_union__/0`); у event-sourced владельца `event_codec:` не равен `codec:`. У state-stored сущности
  и `Core.Es.Personal` — только существование.
- [x] `Core.Es.Event`: `family:` обязательна (`module!` с `exports: [__es_aggregate_id__: 0, __es_by__: 0]`),
  `aggregate_id:` / `by:` ушли. Значения семейства запекаются в головы `new/5,6`, `@type t`, `@spec`, `check_subject!`.
  `__es_aggregate_id__/0`, `__es_by__/0` остались, добавлен `__es_family__/0`.
- [x] `Core.Es.Personal.Event` — семейство с владельцем `Core.Es.Personal`, `KeyDestroyed` — `family:`;
  `await(Core.Es.Personal, %SubjectID{}, timeout)` не изменился.
- [x] Все `use Core.Es.Event` и модули семейств в `lib/`, `test/`, фикстуре переведены, включая семейства без
  проекций (`Ping`, `Grants`, `Parcel`).
- [x] `test/support`: у кодека `Core.EventFixture.Event.Codec` один владелец потока — `Core.EsFixture.Catalog` получает
  своё семейство, кодек и события; `MacroConfigTest` (тест «без dao») переходит на `StateStoredFixture.Entity`.
- [x] Тесты библиотеки: семейство без `@type t` — `CompileError`; старая форма опций события — одно сообщение с
  недостающими и неизвестными. Предупреждение `@after_verify` — тестом, если `Code.compile_string` его вызывает, иначе
  сценарием фикстуры с маркером `# expect:`.
- [x] `make consumer-check`: сценарий `event_new.ex` (чужой ID и автор в `new`) даёт те же предупреждения.
- [x] `@moduledoc` `Core.Es.Event.Family` (опции, интроспекция, сверки, «одно семейство — один владелец потока») и
  `Core.Es.Event`.
- [x] Своды: `11-domain.md` («Es.Event»: семейство, `family:`), `19-testing.md` (примеры с `aggregate_id:`),
  `23-personal-data.md` (`subject: :aggregate_id` — по `aggregate_id:` семейства), `app/11-domain.md`,
  `app/13-repos.md` (раскладка семейства). `make rules-check`.
- [x] CHANGELOG: пункт «Связи event-sourced агрегата называет один владелец…» в «Не выпущено» → «Изменения контракта
  макросов» (текст — спека) со строками семейства и `use Core.Es.Event`; строка 1 таблицы «Версия библиотеки» в
  `docs/rules/app/00-index.md` тем же коммитом.
- [x] Приёмка: `make` целиком.

## Comments

- Семейство `Core.Es.Personal.Event` даёт первый цикл библиотеки (семейство ⇢ владелец / кодек → событие →
  семейство): храповик `xref` поднят до `--fail-above 1` (решение пользователя), строка — ADR-0084, «Цена».
- Семейства `test/support` без владельца потока (`LabelsFixture`, `LabelsBrokenFixture`, `WebEventFixture`,
  `DerivedFixture`, `PersonalBrokenFixture`) называют `aggregate:` корневой модуль фикстуры. События,
  вложенные в модуль-контейнер `Event`, ссылаются на вложенное семейство `Event.Family`: контейнер
  собирается после своих событий. У `LabelsFixture.Event.Family` два кодека (`Event.Codec` и
  `WebEvent.Codec` с общими событиями) — тикету 16 (сверка `__es_codec__`) нужно их развести.
