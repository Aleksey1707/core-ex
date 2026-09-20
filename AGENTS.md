# Инструкции агентам

Файл общий для агентов; `CLAUDE.md` — симлинк на него.

## Язык и тон

- Отвечай строго на русском.
- Сразу дай решение (код/diff), объяснение — только если без него нельзя понять правку.
- Исключи вводные фразы («вот решение», «пожалуйста», «конечно»), извинения, воду, мораль.
- Тон — технический, лаконичный.

## Стиль кода и формат вывода

- Минимальный diff: не переписывать код целиком без запроса.
- Формат правки: либо `diff -u` (без лишних строк), либо инлайн: «строка X: было → стало».
- Не добавляй комментарии, примеры использования, не трогай неиспользуемый код вне зоны задачи.

## Допущения и риски

- Если чего-то не хватает в задаче — явно укажи: «допущение: <кратко, 1 строка>, риск: <низкий/средний/высокий>».
- Если риск средний/высокий — не применяй допущение без подтверждения пользователя.

## Что это

Библиотека `:core` — shared-фундамент приложений (см. `README.md`). Она подключается
git-зависимостью к нескольким разным приложениям, поэтому **главный инвариант**:
в коде библиотеки не должно быть ни одной завязки на конкретное приложение-потребителя,
а её компиляция не имеет права требовать конфигурацию потребителя.

Формулировка инварианта, проверяющий его линтер (`make boundary-check`) и правила
optional-клиентов брокеров — `docs/rules/10-architecture.md`. После любой правки
в `lib/core/mq/**` обязателен `make compile-no-optional`.

## Правила проекта

Свод правил лежит в `docs/rules/*.md` и обязателен к соблюдению. Всегда в контексте —
только соглашения по коду (импорт ниже; если импорт не поддержан — прочитай файл первым):

@docs/rules/20-agreements.md

Остальные своды подключаются по задаче: у каждого есть одноимённый skill, который грузит
файл целиком. Skill выбирает модель — если правишь слой, а свод не подтянулся, читай файл сам.

| Файл | Skill | Тема |
|---|---|---|
| `docs/rules/10-architecture.md` | `architecture` | границы библиотеки, `Core.Config`, способы получения зависимостей |
| `docs/rules/11-domain.md` | `domain` | `Prim`, `Enum`, `Codec`, `Core.View`, `Context`, `Es.Event`, `Version` |
| `docs/rules/12-errors.md` | `errors` | `%Error{}` (`:domain` / `:app`), каталоги ошибок, cause-цепочки |
| `docs/rules/13-repos.md` | `repos` | `Repo` behaviour / `Repo.Pg` / `Schema` / `Specs`, read vs write |
| `docs/rules/14-events-outbox.md` | `events-outbox` | domain events, flush в одной TX, outbox lifecycle |
| `docs/rules/17-otp-concurrency.md` | `otp-concurrency` | дерево процессов, `init/1` / `handle_continue`, таймауты, mailbox |
| `docs/rules/19-testing.md` | `testing` | case-модули, round-trip кодеков, golden-фикстуры событий |
| `docs/rules/20-agreements.md` | — (всегда) | CQS, логирование, `@spec` / `@doc`, guards, алиасы, safe vs bang |
| `docs/rules/21-observability.md` | `observability` | метрики / трейсы / логи, `Core.Otel`, где ставить span |
| `docs/rules/22-projections.md` | `projections` | `use Core.Es.Projection`, read-модель, дерево, чекпоинт, `await`, пересборка |
| `docs/rules/00-index.md` | — | карта свода, словари плейсхолдеров и модальности, стандарт оформления правил |
| `docs/rules/DEBT.md` | — | осознанные отступления от сводов: что не чинится сейчас и почему |

Файл — источник истины, skill — только доставка. Правки вносятся в `docs/rules/*.md`;
`SKILL.md` трогать нужно, только если поменялось имя файла или область применения.
Форма самих файлов проверяется `make rules-check` (`scripts/rules_lint.exs`).

### Свод приложения-потребителя

`docs/rules/app/*.md` — ярус норм, общих для любого приложения на `Core.*`; к потребителю он
приезжает в `deps/core/docs/rules/app/`. Его стандарт — `docs/rules/app/00-index.md`. Правка
`app/**` меняет контракт для всех потребителей и идёт в `CHANGELOG.md` тем же коммитом.

## CHANGELOG

`CHANGELOG.md` обновляется в том же коммите, что и правка, — не перед выпуском.

- Записи копятся в разделе «Не выпущено»; база сравнения — последний выпуск (`## 0.3.3`).
- Разделы: «Ломающие изменения контракта» (публичный API и поведение, видимые потребителю),
  «Новое», «Изменения контракта макросов» (опции `use`, требования к компиляции).
- Пункт: что изменилось, почему так, и как правится код потребителя (было → стало).
- Правка того, что само появилось в «Не выпущено», нового пункта не заводит — дополняется
  существующий.
- Внутренние изменения (приватные функции, перестановка блоков, тексты сообщений, тесты)
  в CHANGELOG не попадают.

## Выпуск

Версия живёт в трёх местах: `mix.exs` (`@version`), `README.md` (`tag:` в примере подключения)
и верхний заголовок `CHANGELOG.md`. Выпуск сводит их разом и ставит тег на коммит сведения:

```bash
make release VERSION=0.3.4   # три файла: «Не выпущено» → ## 0.3.4
git add mix.exs README.md CHANGELOG.md && git commit -m "version up"
git tag v0.3.4 && git push origin HEAD v0.3.4
```

Тег ставится на коммит сведения, а не на последнюю правку: иначе под `vX.Y.Z` уедет версия
прошлого выпуска. Проверяет `make release-check` (`scripts/release_lint.exs`), он же хук
`pre-push`: на коммите с тегом требует, чтобы все три места называли версию тега, вне выпуска
(«Не выпущено» в CHANGELOG) — пропускает. Хук ставится `pre-commit install --hook-type pre-push`.

## Команды

```bash
make                     # boundary-check → rules-check → layout-check → format-check → compile → compile-no-optional → consumer-check → deps-clean → xref → dialyzer → test → credo → audit
make boundary-check      # главный инвариант: библиотека не знает потребителя
make rules-check         # оба яруса docs/rules против стандартов 00-index.md
make layout-check        # разделители внутри модуля: # --- и # ===== <имя> =====
make compile-no-optional # сборка без optional-клиентов брокеров (как у потребителя без них)
make consumer-check      # храповик вывода типов: предупреждения фикстуры-потребителя против маркеров
make release-check       # версия сведена в mix.exs, README.md и CHANGELOG.md (и с тегом на коммите)
make release VERSION=X.Y.Z # свести версию в трёх местах: «Не выпущено» → ## X.Y.Z
make infra-up            # Postgres + RabbitMQ (podman compose, deploy/infra)
make infra-down
mix test                 # :rabbit_stream исключены по умолчанию
make test-stream         # включая тесты живого RabbitMQ Stream
mix test path/to/file_test.exs:42
mix credo --strict
mix dialyzer
mix docs
```

Шаги `make` — в том же порядке, что хуки `.pre-commit-config.yaml`:

| Шаг | Что проверяет |
|---|---|
| `boundary-check` | `scripts/boundary_lint.exs` — библиотека не знает потребителя (`docs/rules/10-architecture.md`) |
| `rules-check` | `scripts/rules_lint.exs` — оба яруса свода против стандартов `docs/rules/00-index.md` и `docs/rules/app/00-index.md` |
| `layout-check` | `scripts/layout_lint.exs` — разделители модуля (`docs/rules/20-agreements.md`, «Разделители внутри модуля») |
| `format-check` | `mix format --check-formatted` — падает, а не правит |
| `compile` | `mix compile --warnings-as-errors` |
| `compile-no-optional` | сборка без optional-клиентов брокеров (`docs/rules/10-architecture.md`) |
| `consumer-check` | предупреждения фикстуры-потребителя `fixtures/consumer` против маркеров `# expect:` (ADR-0014) |
| `deps-clean` | `mix deps.clean --unused` — неиспользуемые зависимости |
| `xref` | `mix xref graph --format cycles` — храповик на циклы компиляции |
| `dialyzer` | `mix dialyzer` |
| `test` | `mix test` после `make infra-up` |
| `credo` | `mix credo --strict` |
| `audit` | `mix deps.audit` — известные CVE в зависимостях |

Тестовая инфраструктура живёт в самой библиотеке: `Core.TestRepo`, `Core.DataCase`,
Codec-фикстуры и Prim-фикстуры — в `test/support`, таблица `outbox` — в
`priv/repo/migrations`. Процессы, которые в приложении поднимает его supervisor,
стартуют в `test/test_helper.exs`.

Максимальная длина строки — 120 (Credo); длинные литералы `Logger.*` разбивать
конкатенацией `<>`, а не heredoc.

## Agent skills

### Issue tracker

Задачи и спеки — markdown-файлы в `.scratch/<feature>/`. См. `docs/agents/issue-tracker.md`.

### Triage labels

Пять канонических ролей, имена меток совпадают с ролями. См. `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` и `docs/adr/` в корне. См. `docs/agents/domain.md`.

### Release check

Проверка незапушенных изменений на приложении-потребителе (`path:`-зависимость, симлинк
`deps/core`, PLT dialyzer). См. `docs/agents/release-check.md`.
