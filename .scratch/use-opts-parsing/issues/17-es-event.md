# 17: Es-событие — `payload:` с громким отказом

**What to build:** автор события с `Payload`, вложенным ниже `use Core.Es.Event`, получает проверку
`subject: :aggregate_id` и интроспекцию `Payload` в теле, а несобранный `Payload` — громкий `CompileError`, а не тихий
пропуск; ошибки опций `use Core.Es.Event.Payload` — при раскрытии. Спека — `../spec.md`, «Es-событие»; ADR-0085.

**Blocked by:** 10; `.scratch/aggregate-wiring/issues/15-family-and-event.md`; тикет-баг
`.scratch/es-event-nested-payload/issues/01-check-subject-silent-skip.md`.

**Status:** ready-for-agent

- [ ] `Es.Event` `payload:` — опция с вложенным модулем: форма при раскрытии, проверки по модулю (`check_subject!`,
  интроспекция `Payload`) — в теле через `<key>!`, отказ на несобранном модуле громкий.
- [ ] `Es.Event.Payload`: `bind_quoted` → пролог при раскрытии, `fields!/2` — валидатор тела.
- [ ] `@moduledoc` `Es.Event` называет `payload:` опцией, чей модуль MAY быть вложен в вызывающего.
- [ ] Тесты: опечатка в ключе — при раскрытии, с меткой; нелитерал в опции-литерале — «ожидается литерал»; вложенный
  модуль ниже `use` — «модуль недоступен»; тест тикета-бага на вложенный `Payload` с `subject: :aggregate_id` зелёный.
- [ ] CHANGELOG: накопительный пункт (текст — спека). Нет — завести вместе со строкой «Версия библиотеки» в
  `docs/rules/app/00-index.md`; есть — дописать то, что меняется для `Es.Event` / `Es.Event.Payload`.
- [ ] Файлы тикета сняты с храповика `excluded`; список опустел — `files: %{excluded: …}` удалён.
- [ ] Приёмка: `make` целиком; `make consumer-check` без новых предупреждений; `mix xref graph --label compile`
  фикстуры не изменился, у библиотеки compile-рёбра только уходят.
