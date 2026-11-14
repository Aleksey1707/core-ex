# 04: `Core.Clock.Test.start/0` проверяет конфигурацию часов

**What to build:** потребитель, который подключил тестовые часы строкой
`:ok = Core.Clock.Test.start()` в `test_helper.exs`, но забыл
`config :core, clock: Core.Clock.Test` в `config/test.exs`, получает немедленный отказ при
старте тестов вместо молчаливого фолбэка на реальное время (сегодня `freeze/1` пишет владение,
но `Core.Clock.now/0` идёт в `Core.Clock.System`, и тесты на истечение срока становятся
флейки). `start/0` зовётся только из `test_helper.exs` — ложных срабатываний в prod нет.

**Blocked by:** None (can start immediately). Файлы (`lib/core/clock/test.ex`) с тикетами
01–03 не пересекаются.

**Status:** resolved

- [ ] `start/0`: при `Core.Config.clock() != __MODULE__` — raise с текстом про недостающую
      строку `config :core, clock: Core.Clock.Test` (в `config/test.exs`); при совпадении —
      прежняя идемпотентная семантика (`:ok`, повторный вызов — `:ok`).
- [ ] Moduledoc `Core.Clock.Test`: подключение — обе строки (конфиг + старт), старт без конфига —
      отказ.
- [ ] Тест `test/core/clock_test.exs`: guard срабатывает при подменённом ключе `:clock`
      (`Application.put_env` + `on_exit` восстановление), штатный `start/0` в тестовой
      конфигурации — `:ok` и идемпотентен.
- [ ] `docs/rules/19-testing.md` («Время») и `docs/rules/app/19-testing.md` («Доменное время»):
      подключение уже описано обеими строками — проверить, что текст не обещает молчаливого
      фолбэка; правки только при расхождении. `make rules-check`. Правка `app/**` — пункт
      CHANGELOG тем же коммитом.

## CHANGELOG

Текст пункта волны (в `CHANGELOG.md` вносит сводный тикет/слияние), раздел «Новое»:

- **`Core.Clock.Test.start/0` проверяет `config :core, clock:`.** Забытая строка конфигурации
  раньше означала тихий фолбэк на системное время и флейки-тесты вместо падения: было — `start/0`
  молча запускал сервер владения при любой конфигурации; стало — raise с текстом про недостающий
  ключ. Правка потребителя: добавить `config :core, clock: Core.Clock.Test` в `config/test.exs`,
  если её нет.

## Answer

Сделано в `clock-test: refuse start without test clock config` (ветка `repo-sc-clock`):
`Core.Clock.Test.start/0` при `Core.Config.clock() != __MODULE__` бросает `ArgumentError` с текстом
про недостающую строку `config :core, clock: Core.Clock.Test`; на совпадении — прежняя
идемпотентная семантика. Moduledoc, `@doc`, `docs/rules/19-testing.md` («Время») и
`docs/rules/app/19-testing.md` («Доменное время») описывают отказ вместо молчаливого фолбэка. Тест
`Core.ClockStartTest` (`async: false`, восстановление `:clock` в `on_exit`).

## Приёмка

`make` целиком (минимум: `mix test test/core/clock_test.exs`, `rules-check`,
`compile --warnings-as-errors`, `format-check`, `credo --strict`).
