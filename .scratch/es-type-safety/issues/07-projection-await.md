# 07: `Projection.await/3` вместо `Core.Es.Projection.await/4`

**What to build:** автор usecase ждёт проекцию вызовом `Projection.await(Agg, %Agg.ID{} = id, timeout)` у модуля своей
проекции. Агрегат, чьих событий нет в `events:`, ID другого агрегата и невозможная clause по результату ловятся при
сборке. Исходы (`:ok`, `:projection_timeout`, `:projection_rebuilding`), ошибки программиста, span, telemetry и режим
`:inline` прежние.

**Blocked by:** 01

**Status:** resolved

**Spec:** [Типобезопасность потребителя `Core.Es`](../spec.md) — «Ожидание проекции — `Core.Es.Projection`»

- [x] `use Core.Es.Projection` генерирует `await/3`: clause на каждый агрегат, чьи события есть в `events:`, голова —
      закрытый struct его ID, результат сужен до `:ok | {:error, %Core.Error{}}` в `generated: true`.
- [x] `Core.Es.Projection.await/4` — `@doc false` реализация; вызовы в core-ex переведены.
- [x] Фикстура: маркеры G4 (ID другого агрегата), G4b (агрегат не из `events:`), G4c (невозможная clause). Ожидание
      проекции на события двух агрегатов в usecase — ноль предупреждений.
- [x] Тесты ожидания проекции — на `await/3`; исходы, `ArgumentError` внутри транзакции, `RuntimeError` без дерева,
      `:inline`, span и telemetry — прежние.
- [x] Свод: `22-projections.md`, `20-agreements.md` (CQS и `Transact.run`), `12-errors.md`, `17-otp-concurrency.md`,
      `21-observability.md`; ярус `app/`: `15-web-api.md`, `19-testing.md`, `00-index.md` (строка карты
      «`Core.Es.Projection.await/4` → `Projection.await/3`»); `README.md`; описание скилла `projections`.
- [x] moduledoc `Core.Es.Projection` («Ожидание», генерируемая функция).
- [x] `CHANGELOG.md`, «Не выпущено»: пункт «Read-after-write» дополнен, «было → стало».
- [x] `make` зелёный.

## Comments

- 2026-09-17 — реализация:
  - `__before_compile__` `use Core.Es.Projection` генерирует `await/3` по `streams` объявления: агрегат — кодек
    `<Aggregate>.Event.Codec` без двух последних сегментов, ID — `__es_aggregate_id__/0` кодека; кодек с другим
    именем clause не получает (реализация такой агрегат и прежде не находила), без clauses функции нет. `@spec` —
    объединение `<ID>.t()`. Clause — `quote generated: true`, результат `Core.Es.Projection.await/4` сужен
    `:ok | {:error, %Core.Error{} = error}`; `await/4` — `@doc false`, сигнатура прежняя;
  - фикстура: `lib/scenarios/await.ex` — G4 (`%Order.ID{}` при `Account`), G4b (`Ping` не из `events:`), G4c
    (`{:ok, _}`); `Consumer.Usecase.await/2` ждёт проекцию по `Account` и `Order` в одном `with` — ноль
    предупреждений. Маркеров 89 (было 86). Мутация «без сужения» гасит G4c; «без `generated: true`» лишних
    предупреждений не даёт — результат `await/4` у потребителя `dynamic()`, разметка — по норме;
  - тесты `await_test.exs` / `await_commit_test.exs` — механически на `Projection.await/3`; тест
    «агрегат не из `events:` — `FunctionClauseError`» теперь падает в голове `await/3`, предупреждения при сборке
    теста нет (модули того же проекта);
  - сверх перечня: moduledoc соседних модулей (`Await`, `Checkpoint`, `Listener`, `Reader`, `Registry`,
    `Supervisor`, `Supervisor.Mark`, `Core.Es.Store`, `Core.Otel.Es`) ссылались на `Core.Es.Projection.await/4` —
    переведены на «`await/3` модуля проекции»; `docs/rules/19-testing.md` (ярус библиотеки); в `app/15-web-api.md` пример
    хелпера `Helper.Projection.await(conn, Projection, Agg, …)` звал бы `await/3` через модуль-переменную и
    терял проверку — норма: литеральный вызов в экшене, хелпер принимает результат. ADR-0013 и ADR-0014 не
    правились — записи решений.
- 2026-09-17 — по ревью: clause передаёт в `Core.Es.Projection.await/4` тип агрегата (ключ `streams`) вместо
  модуля агрегата — `Await.subscribed_type/2` и `codec_parts/1` удалены, раскладка «агрегат ↔ кодек» вычисляется
  один раз, при сборке; `@spec await/3` — объединение литералов агрегатов и типов ID; `@doc` без несуществующего
  аргумента `aggregate`; в moduledoc — кодек не `<Aggregate>.Event.Codec` clause не получает; тест
  `FunctionClauseError` дополнен ID другого агрегата; «Проверяется:» в «Read-after-write» `22-projections.md`;
  комментарий над `await_ast/1` убран. Не принято: тексты `raise` с префиксом `Es.Projection.await:` — тексты
  сообщений прежние, как и ошибки программиста; занятое имя `await/3` в «Изменения контракта макросов» — прецедент
  `project/1` держит его в пункте проекций; норма хелпера в `app/15-web-api.md` оставлена — хелпер с модулем
  проекции параметром воспроизводит отвергнутый ADR-0014 API, решение вынесено пользователю.
- 2026-09-17 — по проверке rc на qc (коммит 87b2579): после ревью второй аргумент `Core.Es.Projection.await/4` стал
  типом агрегата, и запись «сигнатура прежняя» выше устарела. Старый вызов потребителя
  `Core.Es.Projection.await(Projection, Agg, id, timeout)` ловился лишь случайно — непонятным
  `incompatible types … binary()`, а CHANGELOG не говорил, что он больше не работает. `await/4` удалена: clause
  `await/3` зовёт `Core.Es.Projection.Await.run/5`, старый вызов — `Core.Es.Projection.await/4 is undefined or
  private` (маркер G4o фикстуры). Норма `app/15-web-api.md` дополнена: литерал MAY стоять в `defp`, ID MUST быть
  сужен до `%Agg.ID{}` — без сужения ID другого агрегата не ловится (проба 8 на qc); пример — `respond_taken/3` с
  `{id, version}` для 202. CHANGELOG — «было → стало» с предупреждением старого вызова.
