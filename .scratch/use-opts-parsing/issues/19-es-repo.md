# 19: Es-репозиторий — пролог `expand!` / `literal!`

**What to build:** `Es.Aggregate.Repo`, `Es.Aggregate.Repo.Pg` и `Es.KeyReservation` разбирают опции общим прологом
и дают ошибки в форме `<метка>: <ключ>…` через `reject!/2`. Контракт не ломается. Спека — `../spec.md`,
«Es-репозиторий»; ADR-0085. Состав опций — по коду после `aggregate-wiring` 17 и 18.

**Blocked by:** 10; `.scratch/aggregate-wiring/issues/17-repo-without-copies.md`,
`.scratch/aggregate-wiring/issues/18-key-reservation-aggregate.md`.

**Status:** ready-for-agent

- [ ] Пролог на `expand!` → `validate!` → `literal!`, тексты через `reject!`; `module!` остался при раскрытии.
- [ ] Тесты: опечатка в ключе — при раскрытии, с меткой; нелитерал в опции — «ожидается литерал».
- [ ] Если `literal!` нашёл ранее принятый нелитерал — строка накопительного пункта CHANGELOG; иначе CHANGELOG не
  трогается.
- [ ] Файлы тикета сняты с храповика `excluded`; список опустел — `files: %{excluded: …}` удалён.
- [ ] Приёмка: `make` целиком; `make consumer-check` без новых предупреждений; `mix xref graph --label compile`
  фикстуры не изменился, у библиотеки compile-рёбра только уходят.
