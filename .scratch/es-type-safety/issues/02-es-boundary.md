# 02: Граница `Core.Es` — агрегат, Prim и `Version`, репозиторий и процесс

**What to build:** автор usecase получает предупреждение при сборке, если передал в `Agg.execute/2` команду другого
агрегата или команду без clause в `decide/2`, опечатался в поле состояния из `execute`, `get` или `refresh`, передал ID
из `Other.ID.new()` в репозиторий, процесс или конструктор события, опечатался в поле результата `now!()` или
`Version.new()`, написал невозможную clause по результату `append` или `Agg.Process.execute`. Поведение при исполнении
прежнее; у агрегата, чей `decide` никогда не ошибается или всегда ошибается, ложных предупреждений нет.

**Blocked by:** 01

**Status:** ready-for-agent

**Spec:** [Типобезопасность потребителя `Core.Es`](../spec.md) — «Граница типов генерируемых функций», «Агрегат»,
«Репозиторий event-sourced агрегата» (кроме `page_stream/4`), «Процесс агрегата», «Prim и `Version`»

- [ ] `Agg.execute/2` зовёт `decide(command, state)` в модуле агрегата и передаёт решение библиотеке новой `@doc false`
      функцией; библиотека сама `aggregate.decide` не зовёт. Прежняя `execute/3` удалена, если не используется.
- [ ] Головы `execute/2`, `fold/2`, `fold/3` — `%__MODULE__{}`; результат сужен до `%__MODULE__{}` /
      `{:ok, {list, %Agg{}}} | {:error, _}`.
- [ ] Генерируемые `get` / `refresh` репозитория event-sourced агрегата сужают результат до `{:ok, %Agg{}}`, `get_many`
      — до `{:ok, list}`, `append` — до `:ok | {:error, _}`; головы — закрытые struct.
- [ ] `Agg.Process.execute/4..6` сужает результат до `:ok | {:error, _}`.
- [ ] `new/0` и `new!/1` Prim, `now!/0` `Core.Prim.DateTime`, `Core.Version.new/0` выводятся своим struct; bang —
      `raise Core.Exc` напрямую, не через `Core.Result.unwrap!/1`.
- [ ] Код сужения — `quote generated: true`; в clause, недостижимой у части потребителей, нет голой переменной
      (`{:error, reason} -> {:error, reason}`).
- [ ] Фикстура: маркеры A1, A2, A5a, E5, E5b, E8, F5, D2b, D3b, E1b, F1b, опечатка в поле `now!()` и
      `Version.new()`; корректные агрегаты «`decide` никогда не ошибается», «`decide` только ошибается» и `decide` в
      стиле `%mod{} when mod in @mutations` — ноль предупреждений.
- [ ] ExUnit: тесты агрегата, репозитория event-sourced агрегата, процесса, Prim и `Version` — прежние исходы; меняются
      только тесты, опиравшиеся на удалённую внутреннюю функцию.
- [ ] `20-agreements.md`, «Домен функции и инференс типов»: правило для генерируемых функций — закрытые головы, сужение
      результата в `generated: true`, без голой переменной в недостижимой clause, bang с `raise` напрямую; ссылка на
      ADR-0014.
- [ ] moduledoc `Core.Es.Aggregate` («Генерируемые функции»), `Core.Es.Aggregate.Repo.Pg`, `Core.Es.Aggregate.Process`
      — типы результатов.
- [ ] `CHANGELOG.md`, «Не выпущено»: пункты агрегата, репозитория и процесса дополнены (локальный `decide`, результаты,
      которые видит компилятор); Prim и `Version` — по правилам CHANGELOG.
- [ ] `make` зелёный.

Prior art: `.scratch/es-type-safety/prototype/lib.diff` (`aggregate.ex`, `repo/pg.ex`, `process.ex`, `prim.ex`,
`prim/date_time.ex`), раздел P0 в `RESULTS.md` — обе поправки к форме сужения.
