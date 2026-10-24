# 19: Es-репозиторий — пролог `expand!` / `literal!`

**What to build:** `Es.Aggregate.Repo`, `Es.Aggregate.Repo.Pg` и `Es.KeyReservation` разбирают опции общим прологом
и дают ошибки в форме `<метка>: <ключ>…` через `reject!/2`. Контракт не ломается. Спека — `../spec.md`,
«Es-репозиторий»; ADR-0085. Состав опций — по коду после `aggregate-wiring` 17 и 18.

**Blocked by:** 10; `.scratch/aggregate-wiring/issues/17-repo-without-copies.md`,
`.scratch/aggregate-wiring/issues/18-key-reservation-aggregate.md`.

**Status:** resolved

- [x] Пролог на `expand!` → `validate!` → `literal!`, тексты через `reject!`; `module!` остался при раскрытии.
  Тексты `Es.Aggregate.Repo.Pg.Snapshot` тоже через `reject!`. Отступление: `reraise` в `ensure_code!` (rescue
  `FunctionClauseError`, как у `Repo.Pg`) и общий `Es.Store.Opts` (его зовёт и `StateStored` среза 16) не тронуты.
- [x] Тесты: опечатка в ключе — при раскрытии, с меткой; нелитерал в опции — «ожидается литерал».
- [x] Если `literal!` нашёл ранее принятый нелитерал — строка накопительного пункта CHANGELOG; иначе CHANGELOG не
  трогается. Не нашёл: атрибут или вызов и раньше падали на проверке формы (`module!`, `binary!`, `atom!`,
  boolean, keyword `snapshot:`, список `key_reservations:`) — CHANGELOG не тронут.
- [x] Файлы тикета сняты с храповика `excluded`; список не опустел (срезы 17, 20) — `excluded` остаётся.
- [x] Приёмка: `make` целиком; `make consumer-check` без новых предупреждений; `mix xref graph --label compile`
  фикстуры не изменился, у библиотеки compile-рёбра только уходят (граф библиотеки не изменился).
