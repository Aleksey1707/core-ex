# Тесты

Плейсхолдеры: `MyApp`, `<Aggregate>` — см. `10-architecture.md`.

## Case-модули

| Case | Когда |
|---|---|
| `ExUnit.Case` | чистые модули: Prim, Enum, Codec, хелперы |
| `Core.DataCase` | всё, что ходит в Postgres (Ecto Sandbox) |

У приложения-потребителя набор шире (`MyAppWeb.ConnCase`, `MyApp.EventCompatCase`);
в библиотеке их аналогов нет — web-слоя и доменных агрегатов здесь не бывает.

Тестовая обвязка библиотеки живёт в `test/support`: `Core.TestRepo` (роль `MyApp.DAO`),
`Core.CodecFixture.*` (роль `MyApp.Codec.*`), `Core.TestTypes.JSON`, `Core.PrimFixture`,
`Core.ViewFixture`, `Core.MqFake`, `Core.EventFixture`. Процессы, которые в приложении
поднимает его supervisor, стартуют в `test/test_helper.exs`.

`async: true` по умолчанию. `async: false` — только когда тест трогает глобальное состояние
(конфиг приложения, именованный процесс, консолидированные протоколы) и восстанавливает его
в `on_exit`. Явный `async:` требует `Credo.Check.Refactor.PassAsyncInTestCases`.

Фикстуры — доменные конструкторы (`<Aggregate>.new`, `test/support/prim_fixture.ex`), не Ecto
fixtures. Репозитории тестируются через behaviour: `@repo Application.compile_env!(:core, Behaviour)`
(в приложении-потребителе — под его `:my_app`).
При `shadow_copy?: true` контекст готовится как `Context.new() |> Repo.Sc.init()`.

## Codec: round-trip

`Repo.Pg.Schema.to_entity/to_model` пишутся руками, поэтому каждый Codec-плагин MUST иметь
round-trip-проверку `entity |> dump() |> load() == entity`.

- Примерный тест (один-два инстанса) — минимум.
- Property-based (`stream_data`) — для типов с комбинаторикой полей (шаги сообщения,
  настройки интегратора, nullable-поля): генератор доменных значений + `check all`.

Round-trip на текущем коде **не** ловит переименования: меняются обе стороны сразу.
От этого защищают golden-фикстуры (см. ниже).

### View: round-trip неприменим

`<Aggregate>.View.Codec` — dump-only (`loadable: false`), обратного преобразования у него нет.
Вместо round-trip MUST:

1. тест `<Aggregate>.ReadRepo.Pg.Schema.to_view/1` на полной строке — все колонки, включая
   nullable (тотальная функция: `nil` обязан пройти, а не упасть);
2. проверка формата `OutCodec.dump(view)` — id, даты и decimal совпадают с дампом
   соответствующего Prim (`OutCodec.dump(Agg.ID.new!(raw))` и т.п.), иначе wire read-пути
   молча разъедется с агрегатным;
3. `OutCodec.load(<Aggregate>.View, _)` поднимает `ArgumentError` — плагин остаётся dump-only.

### jsonb на read-пути: контракт wire

Полиморфная нагрузка (снимки, состояния шагов) переводится в формат внешнего профиля по
спеке `Core.Codec.Redump` (`13-repos.md`). Спека — декларация, и она обязана иметь
исполняемую проверку: `entity |> InCodec.dump() |> json_roundtrip() |> Redump.run(spec, OutCodec)`
MUST равняться `entity |> OutCodec.dump() |> json_roundtrip()`.

- `json_roundtrip` (`Jason.encode!` → `decode!`) обязателен: только он придаёт дампу ту
  форму, в которой jsonb реально возвращается из БД (строковые ключи, `Decimal` числом или
  строкой, `DateTime` строкой). Без него сверка идёт не с тем, что лежит в колонке.
- Проверка перебирает **весь набор** источников формы (`for step <- Step.Codec.steps()`),
  а не один пример: новый вариант нагрузки без объявленного формата обязан валить тест.
- Отдельным тестом — полнота декларации: у каждой нагрузки все поля с форматируемым Prim
  (`:uuid` / `:datetime` / `:date` / `:decimal`) объявлены (`wire_prims:`). Он даёт понятную
  ошибку раньше, чем расхождение дампов.

## Совместимость событий

`use MyApp.EventCompatCase, codec:, aggregate_id:, fixtures:` — один тест-модуль на агрегат.
Golden-фикстуры `test/support/fixtures/events/<aggregate>/<wire_tag>.json` не перегенерируются.
Новый тип события → добавить фикстуру. Правила эволюции — `14-events-outbox.md`.

## Enum: описания и внешние коды

`test/my_app/enum_docs_test.exs` — один тест на всё приложение: находит модули `Core.Enum`
(`values/0` + `cast_optional/1` без `new/1`) и сверяет таблицу значений в `@moduledoc`
с `values/0`. Не описанное значение и описанное несуществующее валят сборку. Конвенция
описаний — `11-domain.md`.

Enum с `codes:` MUST иметь round-trip по **всем** `values/0`
(`from_code(to_code(value)) == {:ok, value}`) и проверку нескольких известных кодов
против выгрузки источника. Round-trip сам по себе не ловит сдвиг нумерации: он проходит
и на выдуманных кодах, если они согласованы между собой.

У строковых кодов дополнительно проверяется, что совпадение точное (`"weight"` не проходит
за `"WEIGHT"`): молчаливая нормализация регистра свела бы два кода источника в один.

```elixir
test "коды справочника round-trip" do
  for value <- Type.values() do
    assert {:ok, ^value} = Type.from_code(Type.to_code(value))
  end
end

test "известные коды соответствуют справочнику" do
  assert {:ok, :railcar} = Type.from_code(2)
end
```

## Контрактные тесты behaviour

Если у behaviour больше одной реализации (`.Pg` и `.Cached`), общий набор тестов MUST лежать
в `test/support` и прогоняться на **каждой** реализации — иначе фасады расходятся молча.

```elixir
defmodule MyApp.ReadRepoContract do
  defmacro __using__(impl: impl), do: quote(do: @impl_mod unquote(impl))
  # ... общие тесты, работающие через @impl_mod
end
```

## `constraint_errors`

Маппинг DB-ограничения в доменный код — декларация, которая при расхождении с `changeset/2`
не падает, а **молчит**: наружу уходит `%Ecto.Changeset{}` вместо `%Error{}`. Поэтому
`test/<app>/repo/constraint_errors_test.exs` (один на приложение) сверяет декларации с реальностью:

1. каждый ключ `constraint_errors` объявлен в `changeset/2` (сверка по `error_type`, не по типу
   ограничения — `foreign_key_constraint/3` пишет `:foreign`);
2. каждое ограничение `changeset/2` покрыто маппингом;
3. имена ограничений (`unique_constraint(name:)`, ключи `children:`) существуют в БД —
   `pg_constraint` плюс имена индексов, `unique_index` строки в `pg_constraint` не создаёт;
4. каждый FK дочерней таблицы, кроме колонки `fk:` на сам агрегат, покрыт маппингом.

Источник списка репозиториев — сгенерированные `__constraint_errors__/0` и
`__children_constraint_errors__/0`, а не ручной перечень: новый репозиторий попадает под
проверку сам.

## ACL

Каждый actor-репозиторий с `default_filters` под роль MUST иметь **negative**-тест: сущность
чужого владельца недоступна (`{:error, :not_found}`), а не «просто не появилась в списке».
Позитивный тест доступа сам по себе не доказывает, что фильтр работает.

## Время

Домен получает момент времени аргументом (`at`), а не читает часы внутри: `Es.Event.At.from(at)`,
`CreatedAt.from(at)`. `*.now()` вызывается на границе (usecase, воркер, OTP) — там его можно
подменить в тесте, передав явный `at`.

Тест MUST NOT зависеть от реального «сейчас»: сравнения дат — с зафиксированным значением,
переданным в конструктор.

## Oban

- Режим `testing: :manual`; постановка джобы проверяется `Oban.Testing.assert_enqueued/1`.
- Воркер с внешним эффектом MUST иметь тест на ключ идемпотентности: две постановки с
  одинаковыми `unique`-полями дают одну джобу (см. `14-events-outbox.md`).

## Процессы

- `Ecto.Adapters.SQL.Sandbox.allow(DAO, self(), pid)` для порождённых процессов.
- Циклы OTP проверять синхронным `run_once/1`, а не `sleep`.
- Подробности — `17-otp-concurrency.md`.

## Чувствительные данные

Проверка «секрет не утекает» (`refute inspect(...) =~ plaintext`) требует, чтобы Prim был
объявлен в `lib` или в `test/support`: протоколы консолидируются до старта тестов, и
`@derive Inspect` у модуля, объявленного внутри тест-файла, не действует. Чек-лист —
`12-errors.md`.

## Внешние зависимости

- Тесты, которым нужен живой брокер, — под тегом (`:rabbit_stream`), исключённым по умолчанию
  в `test/test_helper.exs`. Инфраструктура поднимается `make infra-up`.
- Конфигурационный контракт (`Core.Config`) проверяется отдельно, `test/core/config_test.exs`:
  такие тесты правят app env целиком, поэтому `async: false` с восстановлением в `on_exit`.

## Связанные правила

- Репозитории и Sandbox — `13-repos.md`
- События и идемпотентность — `14-events-outbox.md`
- Кеш и контрактные тесты фасадов — `16-caching.md` свода приложения
- OTP — `17-otp-concurrency.md`
