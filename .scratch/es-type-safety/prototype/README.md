# PROTOTYPE · Типобезопасность `Core.Es` у потребителя

Одноразовый код: в `lib/` переносится только ответ, не эта реализация. Исследования —
`../research/01-elixir-1-20-type-system.md`, `../research/02-core-es-blind-spots.md` (коды сценариев A1, B1, C1…).

## Вопрос

Ловит ли компилятор Elixir 1.20.3 ошибки потребителя `Core.Es` предупреждениями, если прототипировать принятые
решения 1–5 на настоящих макросах:

- **P0** — генерируемые функции как граница типов (закрытые головы, сужение результата, `quote generated: true`) и
  локальный `decide(command, state)` в `Agg.execute/2`;
- **P1** — форма конструктора элемента результата `decide/2` (имя, место, возврат, циклы, дубли нагрузки);
- **P2** — функции-проверки полноты `evolve/2`, `project/1`, `dump_payload/2` / `load_payload/3` с литеральными
  вызовами;
- **P3** — формат эталона и скрипт-сверка храповика предупреждений фикстуры.

Ответы с выводом компилятора — `RESULTS.md`.

## Запуск

Правки макросов прототипа — `lib.diff` (снят с core-ex `47f692f`, затрагивает `lib/` и `test/support/`). Фикстура
зависит от core-ex по пути `../../../..`, поэтому запускать её надо в отдельном worktree с применённым патчем:

```bash
git worktree add ../core-ex-proto 47f692f
cp -r .scratch/es-type-safety ../core-ex-proto/.scratch/
cd ../core-ex-proto && git apply .scratch/es-type-safety/prototype/lib.diff
```

```bash
cd .scratch/es-type-safety/prototype/consumer
HEX_OFFLINE=1 mix deps.get                                   # офлайн из ~/.hex, первая сборка зависимостей ~40 с
mix compile --force                                          # все предупреждения фикстуры
mix run --no-start --no-compile ../ratchet/check_warnings.exs          # храповик: маркеры против диагностик
mix run --no-start --no-compile ../ratchet/check_warnings.exs --dump   # эталон строками file:line
bash ../ratchet/selftest.sh                                  # пропавшее / лишнее / сдвиг строк
mix run --no-compile --no-start sig.exs Blind.Account:execute/2        # выведенная сигнатура из ExCk
```

В самом core-ex (worktree): `MIX_ENV=test mix compile --warnings-as-errors`, `mix test test/core/es`
(Postgres на 5433 — контейнер `core-infra-postgres-1`).

## Что где

| Путь | Что внутри |
|---|---|
| `consumer/` | Mix-проект потребителя `:blind`, `{:core, path: "../../../.."}` — свой `_build` и `deps` |
| `consumer/lib/blind/**` | корректный потребитель: предупреждений быть не должно |
| `consumer/lib/blind/account.ex` | агрегат в стиле qc (`%command{} when command in @on_existing`), `fold/3`, `draft/1` |
| `consumer/lib/blind/user.ex`, `user/event.ex` | `decide` по образцу `QC…User` в форме `draft/1`, кодек, `Repo` |
| `consumer/lib/blind/never_fails.ex` | `NeverFails` (`decide` без ошибок) и `AlwaysFails` (`decide` только с ошибкой) |
| `consumer/lib/blind/ping*` | кодек без событий с нагрузкой и его `Repo` |
| `consumer/lib/blind/projection.ex` | проекция на события двух агрегатов |
| `consumer/lib/blind/usecase.ex` | корректные вызовы `execute`, `get`, `refresh`, `get_many`, `Process.execute`, `new/0` |
| `consumer/lib/scenarios/p0.ex` | A1, A2, A3, A4a, A5a, E5, E1b, D2b, F1b, F2, F5, E8 — с маркерами `# expect:` |
| `consumer/lib/scenarios/p1_draft.ex` | B1, B1p, B1n, B3, B2t, B1d, B1s |
| `consumer/lib/scenarios/p2_evolve.ex`, `p2_projection.ex`, `h_codec.ex` | C1, C2a, C4; G1, G3a; H1, H2 |
| `variants/shared_payload.ex` | два события с общим модулем нагрузки — `CompileError` |
| `variants/draft2.ex` | конструктор арности 2 `draft(Event.Mod, payload)` |
| `variants/family_draft.ex` | `draft/1` в модуле-семействе `<Aggregate>.Event` |
| `ratchet/check_warnings.exs` | сверка диагностик Mix с маркерами в исходнике |
| `ratchet/selftest.sh` | самопроверка храповика |
| `out/*.out` | вывод компилятора, xref, dialyzer, сигнатуры, самопроверка — ссылки из `RESULTS.md` |

Варианты `variants/*.ex` в сборку не входят: их копируют в `consumer/lib/scenarios/` на один прогон.

Правки `lib/` и `test/support/` — в этом worktree, перечислены в `RESULTS.md`.
