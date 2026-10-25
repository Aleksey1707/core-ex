# 11: Включение `CredoChecks.OptsSchema` и свёртка `StartOpts`

**What to build:** новая функция библиотеки, читающая свои опции мимо схемы, валит `make` на
Credo; `StartOpts` больше не второй язык проверки опций — в нём остались только custom-валидаторы
и проверки элементов дерева.

Спека — «Правило свода и проверка», «Custom-валидаторы вместо `Core.Helper.StartOpts`».

**Blocked by:** 03, 04, 05, 06, 08, 09, 10

**Status:** resolved

- [x] `CredoChecks.OptsSchema` (только `lib/`): срабатывает на `Keyword.validate!(opts, …)` и на
      чтение `Keyword.get/fetch/fetch!(opts, …)` / `opts[:…]` в публичной функции без
      `@opts_schema`.
- [x] Исключения проверки: обратные вызовы с `@impl` (протоколы, behaviour, PromEx), модули
      разбора опций (`Helper.Opts`, `Prim.Opts`, `Store.Opts`, `Codec.Plugin.Opts`, `Snapshot`,
      `Prim.Wrapper`), функции, передающие `opts` целиком в вызов.
- [x] Тесты проверки в `test/scripts/credo_checks_test.exs`: срабатывания и каждое исключение.
- [x] Проверка подключена в `.credo.exs`; `mix credo --strict` на `lib/` зелёный без исключений по
      файлам.
- [x] `StartOpts`: функции, заменённые встроенными типами NimbleOptions, удалены; остаются
      custom-валидаторы, `process!/3`, `unique!/4`; `@moduledoc` обновлён.
- [x] `20-agreements.md`: в разделе о схеме опций — «Проверяется: `mix credo --strict`
      (`CredoChecks.OptsSchema`)»; `make rules-check` зелёный.
- [x] `make` зелёный.

## Comments

- Что считается опциями: параметр `opts` публичной `def` (`CONTEXT.md`, «Опции функции»: последний
  аргумент — `opts`). Чтение — `Keyword.get/get_lazy/fetch/fetch!/has_key?/validate/validate!` с
  `opts` первым аргументом и `opts[:…]`. `Keyword.pop/take/delete/merge` чтением не считаются:
  это правка перед передачей дальше (`Repo.Pg.insert_many/4` — смешанный случай вне объёма спеки,
  запись в `docs/rules/DEBT.md`).
- Исключения:
  - `@opts_schema` и `@impl` (кроме `@impl false`) относятся к функции — имени и арности, — а не к
    клаузе: снимают проверку со всех клауз, следующей функции не достаются;
  - «опции насквозь» — голый `opts` внутри аргументов вызова или литерала данных (в том числе
    спецификация ребёнка `{__MODULE__, :start_link, [opts]}` и `opts |> Keyword.delete(…) |>
    call()`); управляющие формы (`case`, `if`, `=`, `with` …) и `Keyword.*` его не отдают.
    `Keyword.validate!` срабатывает и при передаче: это проверка своих ключей;
  - приватная функция модуля — не «дальше»: опции, отданные ей голой переменной, разбираются её
    телом под именем её параметра (рекурсивно), чтение отмечается на месте передачи в публичной
    функции. Иначе `def f(opts), do: g(opts)` с чтением в `defp g` прятал бы чтение от проверки;
  - `def` внутри `quote` — генерируемый код, схема в нём MUST NOT: не проверяется; в теле
    проверяемой функции `quote` разбирается только по `unquote`;
  - модули разбора опций как данных — параметр `parsers:` проверки (по умолчанию шесть модулей из
    тикета), сверка по полному имени с учётом вложенности `defmodule`. Исключений по файлам в
    `.credo.exs` нет.
- Что проверка нашла и как решено:
  - `Core.Helper.StartOpts`, функции с `!` — удалены (ниже).
  - `Prim.String` / `Prim.Integer` / `Prim.Decimal` `cast/2`, `sec_max_len/1`, `Prim.Compose`
    `sensitive?/2` / `personal?/2` — не опции функции, а опции объявления Prim (спека, «вне объёма по
    природе»): `cast/2` получает `pipeline_opts:` Prim, `sec_max_len/1` — опции типа, `sensitive?` /
    `personal?` — опции `use` композита. Параметр переименован в `pipeline_opts` / `type_opts` /
    `use_opts` — имя называет, что это за данные (`@prim_type_opts`, `pipeline_opts:` в
    `Core.Prim`), а не исключение проверки по модулю.
- Решения по известным местам:
  - `child_spec/1` (`Keyword.get(opts, :name)` для `:id`, `shutdown:` с умолчанием) — опции
    насквозь: они целиком уходят в `start_link/1` → `init/1`, где схема проверяет и `name:`, и
    `shutdown:`. Своя схема у `child_spec/1` повторила бы схему `init/1` и разошлась бы с ней, как у
    `Es.Projection.Test.run_until_idle/2` (тикет 04). Проверка относит их к «насквозь» без
    отдельного исключения.
  - `Step.new!/2` → `Step.new!/1` со схемой `@opts_schema @schema`: она читает свои ключи, а
    `Keyword.take/2` своих ключей, мешавший схеме, перешёл к вызывающим
    (`MqSubscriberReliable.init/1`, `Outbox.Test`). Метка вызывающего в отказе больше не нужна:
    оба вызывающих проверяют ключи шага своей схемой раньше. `Core.Options.__validate__!/3` вне
    `Core.Options` остался в одном месте — разбор элемента `subscribers:` в
    `Outbox.Test.parse_subscriber!/1`: это значение внутри списка дерева, как `process!/3`, а не
    опции функции.
  - `Outbox.Supervisor`, `required!/1` — условная обязательность (`enabled: true`), схемой не
    выражается; приватная, межключевая проверка в теле (как у тикета 10). Отказы значений
    поддерева (`prim!`, `transport!`, `via!`) — свой приватный `invalid!/3` вместо удалённого
    `StartOpts.raise_invalid!/4`, текст прежний.
  - Ключ схемы без умолчания — `Keyword.get/2` без запасного значения (тикет 05): записано в
    `20-agreements.md`, «Схема опций функции»; проверка функции со схемой не трогает.
- `StartOpts`: удалены `keys!`, `module!/3,4`, `prim!`, `atom!`, `binary!/3,4`, `list!`, `term!`,
  `fun!/4,5`, `pos_integer!/3,4`, `boolean!/3,4`, `one_of!`, `topics_filter!`, `name!`,
  `shutdown!` (вызовов не осталось) и их тесты; `raise_invalid!/4` стал приватным `invalid!/4`
  блока «процессы дерева». Спека называет модуль внутренним, но функции с `!` объявлены в
  выпущенном CHANGELOG («Новое») как проверка опций OTP-процесса, и свод потребителя
  (`docs/rules/app/17-otp-concurrency.md`) отсылает к `StartOpts`: удаление — отдельный пункт
  «Ломающих» с правкой было → стало.
- После ревью: в CHANGELOG — отдельные пункты о порядке аргументов Otel (с удалёнными типами
  `Otel.start_opts/0`, `Otel.Messaging.opts/0`) и о свёртке `StartOpts`; `Otel.Messaging`
  `attributes:` получил `default: %{}`, `operation_name:` — умолчание от операции в теле;
  `cast/2` Prim называет второй аргумент `pipeline_opts` во всех клаузах; тест на `@impl false`.
- Обход проверки переименованием параметра возможен: проверка смотрит на `opts` — термин
  `CONTEXT.md`. Переименование Prim-функций — не обход, а точное имя данных объявления;
  ревью новых функций по-прежнему видит имя параметра.
- `docs/rules/DEBT.md`: запись «Опции функций `lib/` мимо схемы» заменена записью о единственном
  оставшемся случае — `Repo.Pg.insert_many/4` (`chunk_size:` рядом с ключами Ecto).
- `docs/rules/app/17-otp-concurrency.md` («разбираются в `init/1` (`Core.Helper.StartOpts`)») не
  тронут: спека — свод потребителя не меняется.
