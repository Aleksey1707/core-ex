# 04: Usecase ждёт проекцию по `wait:`

**What to build:** изменяющий usecase event-sourced агрегата принимает `wait: :none | pos_integer()`, после commit
ждёт проекцию литеральным `Projection.await/3` и возвращает `{:projected, view}` или `{:accepted, id, version}`.
`MyAppWeb.Accepted` переводит `Prefer` в `wait:` и результат — в 200 или 202, без колбэка ожидания. Ответы API не
меняются; воркер и подписчик получают ожидание тем же вызовом.

**Blocked by:** 01

**Status:** done

**Spec:** [Контекст — граница Boundary, раскладка — вертикаль по агрегату](../spec.md) — «`wait:`»

- [x] `rules/22`, «Read-after-write»: MUST NOT ожидания в usecase снят; ожидание — после commit, вне транзакции,
      литеральным вызовом с ID, суженным до `%Agg.ID{}`
- [x] `rules/20`, «Разделение изменения и чтения»: исключение «изменяющий usecase с `wait:` MAY вернуть представление»
- [x] `app/10`, «Usecases»: возвраты команды и создания при `wait:`; `:projection_timeout` и
      `:projection_rebuilding` → `:accepted`; создание отдаёт `{id, version}` в обоих случаях
- [x] `app/15`, «Ожидание проекции»: экшен передаёт `wait:`, `MyAppWeb.Accepted` без колбэка; схемы ответов и
      `Preference-Applied` прежние
- [x] `app/19`: тест ветки `:accepted` — тест usecase через `Core.Es.Projection.Test.with_rebuilding/2`
- [x] фикстура: usecase с `wait:` и сценарий на неверный агрегат или ID в его `await` (prior art —
      `scenarios/await.ex`)
- [x] ADR вместо ADR-0030 в части «usecase не ждёт» и формы хелпера; в ADR-0030 — пометка о замене
- [x] `CONTEXT.md`: «Usecase», «Ожидание проекции»
- [x] `app/00`, таблица устаревших форм: колбэк в `MyAppWeb.Accepted` → `wait:`
- [x] CHANGELOG, «Ломающие изменения контракта»: `MyAppWeb.Accepted` и сигнатуры команд, «было → стало»
- [x] `make` зелёный

## Comments

- Уточнено с мейнтейнером: `wait:` — опция `opts \\ []` последним аргументом (`rules/20`, «Context —
  последний из данных»), по умолчанию `:none`; тест ветки `:accepted` — один на модуль usecases с
  ожиданием, а не на приложение: ветка живёт в хелпере ожидания каждого модуля; хелпер web —
  `MyAppWeb.Accepted.wait/1` + `respond/3` + `written/2`, `render` — `(conn, view -> conn)`.
- Создание отдаёт `{:ok, {:projected | :accepted, id, version}}`: тег несёт исход ожидания, тело — то
  же, что прежде (ADR-0027).
- Хелпер ожидания usecase — `defp awaited/2` с ID, суженным в голове: `:none` → `:accepted`,
  иначе литеральный `Projection.await/3` и `:projection_timeout` / `:projection_rebuilding` →
  `:accepted`; команда при `:projected` читает представление ReadRepo.
- Фикстура: `Account.Client.Usecases.open/4` — корректная форма без предупреждений; сценарий G4w в
  `scenarios/await.ex` — хелпер ожидания usecase заказа, скопированный у счёта: агрегат в `await` —
  `Account`, ID — `Order.ID`; сборка ловит (`incompatible types given to …Projection.await/3`) —
  сначала красный «лишний», затем маркер.
- ADR — `0039-usecase-awaits-projection-by-wait.md`; в ADR-0027 — пометка о пересмотре формы хелпера,
  wire создания прежний.
- После ревью: `wait:` — MUST у каждой команды event-sourced агрегата с read-моделью (агрегат без
  read-модели `wait:` не принимает, исход — `:accepted`); `:projection_timeout` /
  `:projection_rebuilding` → `:accepted` — MUST (`rules/22`); исключение CQS особого имени не требует.
  Не принято: разбор исхода `await` функцией библиотеки (вне тикета) и перевод ошибки чтения
  представления после commit в `:accepted` (прежнее поведение экшена — ошибка).
- `Core.Es.Projection.Test.with_rebuilding/2`: в `@doc` ветка — `:accepted` usecase, а не 202 HTTP.
