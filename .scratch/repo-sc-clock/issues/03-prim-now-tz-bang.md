# 03: `now/0` / `today/0`: конфигурационная ошибка перестаёт быть доменной

**What to build:** генерируемые `Prim.DateTime.now/0` и `Prim.Date.today/0` больше не выдают
доменную ошибку `:invalid_datetime` / `:invalid_date` с `detail: tz`, когда `DateTime.shift_zone`
не может привести доменное время к поясу. Эта ветка достижима только при неверном
`config :core, tz:` (или сломанной реализации часов) — ошибке конфигурации, а не отказе домена;
её уже ловит `Core.Config.validate!/0` на старте приложения-потребителя. Приведение к поясу
становится bang (`shift_zone!`), как в прецеденте `Core.Codec.shift_tz/1`; `Result` у `now/0` /
`today/0` остаётся и несёт только доменные отказы `new/1` (в том числе bounds `after:` /
`before:`). `now!/0` приводится к общему с `from!/1` виду через `Result.unwrap!`.

**Blocked by:** None (can start immediately). Файлы (`lib/core/prim/date_time.ex`,
`lib/core/prim/date.ex`) с тикетами 01/02/04 не пересекаются.

**Status:** resolved

- [ ] `now/0` (`Prim.DateTime`) и `today/0` (`Prim.Date`): `DateTime.shift_zone(Core.Clock.now(), tz)`
      → `DateTime.shift_zone!/2`, ветка `{:error, _}` с `Prim.wrap_error(..., tz)` удалена.
- [ ] `now!/0` вместо инлайнового `case` + `raise Core.Exc` — `Result.unwrap!` (как `from!/1`);
      `today!/0` — то же.
- [ ] `@doc` функций и moduledoc билдеров: `Result`-ошибка — только доменные отказы `new/1`;
      неверный `tz:` — `ArgumentError` (`Core.Config.validate!/0` его отсекает на старте).
- [ ] Тесты `test/core/prim/date_time_test.exs`, `test/core/prim/date_test.exs`: существующие
      `now/0` / `today/0` / bang-тесты зелены; новых тестов на удалённую ветку не нужно
      (недостижима при валидном конфиге). Тесты bounds через `now/0` (если есть) — `Result`
      сохранён.
- [ ] `mix test test/core/clock_test.exs` зелен: `Clock.Test.freeze` + `At.now/0` + `Day.today/0`
      не затронуты.

## CHANGELOG

Текст пункта волны (в `CHANGELOG.md` вносит сводный тикет/слияние), раздел «Ломающие изменения
контракта»:

- **`now/0` / `today/0` у Prim даты и времени: конфигурационная ошибка больше не доменная.**
  Ветка `{:error, %Error{code: :invalid_datetime | :invalid_date}}` при неприводимом `tz:` была
  достижима только на неверном `config :core, tz:`, который `Core.Config.validate!/0` отсекает на
  старте: было — доменная ошибка с `detail: tz`; стало — `ArgumentError` от `shift_zone!`.
  Формы результата на валидной конфигурации не меняются: `{:ok, _}` и доменные отказы `new/1`
  (bounds) как были. Правка потребителя не требуется; сопоставление с `:invalid_datetime` на
  результате `now/0`/`today/0` теряет мёртвую ветку.

## Answer

Сделано в `prim: shift domain time with shift_zone! in now/today` (ветка `repo-sc-clock`):
`now/0` / `today/0` приводят время через `DateTime.shift_zone!/2`, ветка `{:error, _}` с
`:invalid_datetime` / `:invalid_date` удалена, `Result` несёт только отказы `new/1`. Отступление от
подпункта «`now!/0` через `Result.unwrap!`»: code review нашёл конфликт со сводом
(`20-agreements.md`, «Генерируемые функции» — bang MUST делать `raise Core.Exc` сама, `DEBT.md`
числит `now!/0` / `today!/0` соответствующими); по решению пользователя `now!/0` / `today!/0`
оставлены в форме `case` + `raise Core.Exc` внутри `quote generated: true`. Контракт исключения тот
же. Тесты `test/core/prim` и `test/core/clock_test.exs` зелены.

## Приёмка

`make` целиком (минимум: `mix test test/core/prim test/core/clock_test.exs`,
`compile --warnings-as-errors`, `format-check`, `credo --strict`).
