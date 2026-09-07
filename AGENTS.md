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

Формулировка инварианта, проверяющие его грепы и правила optional-клиентов брокеров —
`docs/rules/10-architecture.md`. После любой правки в `lib/core/mq/**` обязателен
`make compile-no-optional`.

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
| `docs/rules/00-index.md` | — | карта свода, словари плейсхолдеров и модальности, стандарт оформления правил |
| `docs/rules/DEBT.md` | — | осознанные отступления от сводов: что не чинится сейчас и почему |

Файл — источник истины, skill — только доставка. Правки вносятся в `docs/rules/*.md`;
`SKILL.md` трогать нужно, только если поменялось имя файла или область применения.
Форма самих файлов проверяется `make rules-check` (`scripts/rules_lint.exs`).

## Команды

```bash
make                     # rules-check → format-check → compile → compile-no-optional → deps-clean → xref → dialyzer → test → credo → audit
make rules-check         # свод docs/rules против стандарта 00-index.md
make compile-no-optional # сборка без optional-клиентов брокеров (как у потребителя без них)
make infra-up            # Postgres + RabbitMQ (podman compose, deploy/infra)
make infra-down
mix test                 # :rabbit_stream исключены по умолчанию
make test-stream         # включая тесты живого RabbitMQ Stream
mix test path/to/file_test.exs:42
mix credo --strict
mix dialyzer
mix docs
```

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
