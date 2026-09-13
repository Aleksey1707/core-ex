# 29: `Core.Es.EventCompatCase` для кодека событий

**What to build:** автор домена пишет один тест-модуль `use Core.Es.EventCompatCase, event_codec: Agg.Event.Codec` и
получает проверку golden-фикстур событий: у каждого тега есть фикстура, каждая грузится, у каждого источника апкаста
есть фикстура, и она грузится в модуль конца цепочки. Case живёт в библиотеке, а не копируется в каждое приложение.

**Blocked by:** [24: Обязательный `type:` у кодека событий](24-event-codec-mandatory-type.md),
[25: Апкаст событий](25-event-upcasts.md)

**Status:** ready-for-agent

**Spec:** [Event-sourced агрегат в :core](../spec.md) — «Тестовая поддержка в `lib/`»

- [ ] `use Core.Es.EventCompatCase` в `lib/`, ExUnit только внутри `quote`. Опции: ровно одна из `aggregate:` /
      `event_codec:`, обе или ни одной — `CompileError`; здесь реализуется `event_codec:`, `aggregate:` — тикет 30.
- [ ] `fixtures:` необязательна, по умолчанию `test/support/fixtures/events/<тип агрегата>/`, файл — `<тег>.json`;
      фасад — `Core.Config.codec/0`; семейство событий, `aggregate_id` и тип агрегата выводятся из кодека.
- [ ] Генерируемые тесты: (1) у каждого тега `types/0` есть фикстура; (2) каждая грузится через
      `InCodec.load(Agg.Event, _)`; (3) у каждого источника `upcasts:` есть фикстура; (4) фикстура источника грузится в
      модуль конца цепочки.
- [ ] Логика каждой проверки — функция `@doc false` → `:ok | {:error, detail}`; сгенерированный `test` делает
      `assert :ok = …`.
- [ ] Библиотека вызывает проверки на сломанных модулях `test/support`: тег без фикстуры, источник апкаста без
      фикстуры, фикстура, которая не грузится.
- [ ] Golden-фикстуры `Core.EventFixture` и кодека с апкастом из тикета 25; тест-модули `use Core.Es.EventCompatCase,
      event_codec:` на обоих.
- [ ] `19-testing.md`: «Case-модули» + `Core.Es.EventCompatCase`; «Совместимость событий» →
      `use Core.Es.EventCompatCase`, оговорка «в библиотеке их аналогов нет» снята. `14-events-outbox.md`,
      «Golden-фикстуры» — инварианты 1–4. `description` skill `testing`. `CHANGELOG.md`, «Новое».
- [ ] `make` зелёный.
