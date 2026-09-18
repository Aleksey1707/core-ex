# 16: `ConstraintErrorsCase` не считает `save` write-методом

**Status:** done

**What to build:** `write?/1` в `Core.Repo.ConstraintErrorsCase` отбирает write-репозиторий по
`Core.Repo.write_methods/0`, а не по паре `insert/3` / `update/3`; фикстура получает репозиторий
`only: ~w(get save)a` с `constraint_errors:`.

**Why:** репозиторий, объявленный `use Core.Repo, only: ~w(get save)a` — форма, предписанная
`13-repos.md`, — выпадает из четырёх сверок кейса молча и ложно валит пятую. Это ровно та дыра
в декларации `constraint_errors:`, ради которой ратчет и заведён.

- [x] `write?/1` через `Core.Repo.write_methods/0`; фикстура и тесты; пункт CHANGELOG о кейсе
      дополняется, новый не заводится

## Comments

> *Найдено в code-review ветки `develop` (18.09.2026), код — из тикета 03 «Сверка
> `constraint_errors`».*

## Agent Brief

**Category:** bug
**Summary:** отбор write-репозиториев в ратчете `constraint_errors` расходится с
`Core.Repo.write_methods/0`

**Current behavior:**

- `Core.Repo.ConstraintErrorsCase.write?/1` (`lib/core/repo/constraint_errors_case.ex:292`):
  `exports?(repo, :insert, 3) or exports?(repo, :update, 3)`.
- `Core.Repo.write_methods/0` — `~w(insert update save)a` (`lib/core/repo.ex:31`); по нему
  определяет write-путь `Core.Repo.Pg.validate_mappers!/2` (`lib/core/repo/pg.ex:304`).
- `Core.Repo.Pg` генерирует `save/3` под `if :save in only` независимо от `insert` и `update`
  (`lib/core/repo/pg.ex:227`), а `Repo.Pg.save/4` внутри зовёт `insert` / `update` библиотеки —
  маппинг ограничений на нём срабатывает.
- Следствия для репозитория `only: ~w(get save)a` с непустым `constraint_errors:`:
  1. тесты 1–4 (ключи маппинга, покрытие `changeset/2`, имена в БД, FK детей) его **пропускают**;
  2. `mapped_read?/1` (`:285`) считает его read-репозиторием, и тест 5 «read-репозиторий не
     объявляет `constraint_errors`» падает **ложно**.
- Дыра не видна, потому что фикстура покрывает только `only: ~w(insert update save)a`
  (`test/support/constraint_errors_fixture.ex:91`) и read-репозиторий `only: :read` (`:132`).

**Desired behavior:**

- `write?/1` — `Enum.any?(Core.Repo.write_methods(), &exports?(repo, &1, 3))`: один источник
  истины о том, что такое write-путь.
- Фикстура получает репозиторий `only: ~w(get save)a` с `constraint_errors:`, и он попадает
  в тесты 1–4 и не попадает в тест 5.

**Key interfaces:**

- `Core.Repo.write_methods/0` — уже публичная, новых не нужно

**Acceptance criteria:**

- [x] `write?/1` опирается на `Core.Repo.write_methods/0`
- [x] фикстура с `only: ~w(get save)a`: тест 5 её не ловит, тесты 1–4 её сверяют (мутация
      декларации валит тест)
- [x] пункт CHANGELOG о `Core.Repo.ConstraintErrorsCase` (раздел «Новое», «Не выпущено»)
      дополняется — нового пункта правка не заводит
- [x] `make` проходит

**Out of scope:**

- `delete/3` как write-метод: `@write_methods` его не включает, маппинг на `DELETE` — отдельный
  вопрос
- отбор репозиториев по `__constraint_errors__/0` — он верен
