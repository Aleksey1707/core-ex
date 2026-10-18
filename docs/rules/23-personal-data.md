# Персональные данные

- **Область.** `lib/core/prim.ex`, `lib/core/prim/**` (опция `personal:`), `lib/core/codec.ex`
  (`load_composite/3`), `lib/core/es/event/payload.ex` и `lib/core/codec/plugin/fields.ex`
  (`subject:`), `lib/core/es/personal.ex`, `lib/core/es/personal/**`; у потребителя — Prim с
  персональными данными (ПДн), события с ними и своя реализация хранилища ключей.
- **Читать перед.** Новым Prim, значение которого — ПДн; полем нагрузки события с ПДн;
  переводом Prim с ПДн с `sensitive:` на `personal:`; правкой редакции значения Prim в выводе;
  апкастером и `evolve/2` / `project/1` события с полем `subject:`; конфигурацией KEK, своей
  реализацией или правкой хранилища ключей.
- **Словарь.** Плейсхолдеры и модальность — `00-index.md`; термины («ПДн-значение», «Субъект
  данных», «Уничтожение ключа субъекта») — `CONTEXT.md`, «Персональные данные».

Механизм — ПДн в событиях под ключом субъекта и уничтожение ключа (ADR-0072…0079). Нормы слоёв
живут в их файлах со ссылкой сюда; нормы приложения —
`deps/core/docs/rules/app/23-personal-data.md`.

## Разметка

Prim, значение которого — ПДн, MAY объявляться `personal: true` (default `false`) вместо
`sensitive: true`: значение скрыто в выводе так же, а read-путь открыт. Опция есть у всех
обёрток (`Prim.String` / `Integer` / `Decimal` / `UUID` / `DateTime` / `Date` / `Compose`),
интроспекция — `__domain_personal__/0`.

| Свойство | `personal: true` | `sensitive: true` |
|---|---|---|
| `inspect/1` | без значения: `#Phone<...>` | без значения |
| `detail` отказа `new` и вся cause-цепочка | `{:redacted, n}` / `:redacted` | то же |
| `Core.View`, Redump | значение проходит — ПДн показываются клиенту | `CompileError` / поле вырезается |
| `Prim.Compose` | наследует от базы, понижение — `CompileError` | то же |

Флаги независимы, оба вместе MAY: значение скрыто в выводе и закрыто для read-пути.

```elixir
# плохо — sensitive закрывает read-путь: телефон клиента не показать в View
use Core.Prim.String,
  name: first_line(@moduledoc),
  max_len: 32,
  sensitive: true

# хорошо
use Core.Prim.String,
  name: first_line(@moduledoc),
  max_len: 32,
  personal: true
```

Ошибку базы `Core.Codec.load_composite/3` отдаёт вместо ошибки композита и редактирует по флагу
композита (`sensitive:` или `personal:`), а не базы: композит с флагом над обычной базой сырое
значение в `detail` не отдаёт.

Чем ПДн отличаются от секрета и что помечать `sensitive:` — `12-errors.md`, «Чувствительные
данные»; вывод ПДн в логи, span'ы и отчёт о падении — `21-observability.md`, «Персональные
данные в выводе».

Проверяется: `test/core/prim/personal_test.exs` — редакция, наследование и `CompileError` при
понижении; `test/core/codec_test.exs`, describe «load_composite/3»; `test/core/view_test.exs` и
`test/core/codec/redump_test.exs` — personal-Prim на read-пути.

### Поле нагрузки события (`subject:`)

ПДн-значение в событии объявляется у поля нагрузки по полям (`use Core.Es.Event.Payload`)
ключом `subject:` — субъектом данных, под чьим ключом лежит значение (ADR-0073):

- `subject: :aggregate_id` — субъект — сам агрегат события (агрегат-лицо);
- `subject: :<поле>` — UUID-поле той же нагрузки (контакт получателя в заказе); само поле-субъект
  `subject:` не несёт.

У каждого ПДн-поля ровно один субъект; ПДн разных лиц в одном событии MAY — каждое поле со
своим `subject:`. Список значений разных субъектов не выражается: такие данные делятся на поля
или события.

```elixir
use Core.Es.Event.Payload,
  fields: [
    recipient_id: [prim: Order.RecipientID],
    phone: [prim: Order.Phone, subject: :recipient_id],
    comment: [prim: Order.Comment, subject: :aggregate_id, optional: true]
  ]
```

Единица шифротекста — значение поля верхнего уровня целиком, любого вида (`prim`, `entity`,
`list`, `enum`, `type`). Плагин сущности и View `subject:` не принимают (ADR-0073). `subject:`
MAY и у поля с Prim без `personal: true`: шифруется поле, а не флаг Prim.

ПДн вложенной сущности (`entity:`, `union:`, `type:`) размечается `subject:` у её поля нагрузки,
а не внутри плагина.

```elixir
# плохо — Address несёт ПДн во вложенных Prim, поле без subject: уходит в историю открытым
fields: [address: [entity: Order.Address]]

# хорошо — шифруется значение поля целиком
fields: [recipient_id: [prim: Order.RecipientID], address: [entity: Order.Address, subject: :recipient_id]]
```

Сборка (`CompileError`) ловит:

- персональный Prim на прямом поле (`prim:` / `list: [prim:]`) без `subject:`;
- субъект — не `Prim.UUID` и не `Prim.Compose` над ним; у
  `subject: :aggregate_id` это проверяет `use Core.Es.Event` по `aggregate_id:`;
- поле с `subject:` в роли субъекта, `subject:` на несуществующее поле или на само себя;
- обязательное ПДн-поле при необязательном поле-субъекте;
- wire-ключ, начинающийся с `$`, — у любой нагрузки, с ПДн и без: форма `{"$pd": …}`
  зарезервирована.

`nil` в поле-субъекте при непустом ПДн-значении не записывается: такую нагрузку отвергают guard
`new/N` и голова `dump` кодека событий (нагрузка, собранная литералом мимо `new/N`). `nil`
необязательного ПДн-поля остаётся `null` без шифрования.

`Inspect` нагрузки поля с `subject:` не выводит, ошибка `load` под таким полем — с
отредактированным `detail` всей cause-цепочки, какого бы вида ни было поле.

Кодек событий на `dump` кладёт на место значения поля с `subject:` маркер
`%Core.Es.Personal.Marker{}` — идентификатор субъекта и wire-значение поля. JSON маркер не
кодирует (`Jason.Encoder` поднимает исключение без значения), `inspect/1` показывает только
субъекта. Поля с `subject:` по событиям отдаёт `__es_subjects__/0` кодека событий.

Проверяется: `test/core/es/event/payload_personal_test.exs` — `CompileError` разметки;
`test/core/es/event/codec_personal_test.exs`, describe «dump» и «нагрузка».

## Уничтоженное ПДн-значение

Уничтожение ключа субъекта не делает событие нечитаемым: на месте значения поля с `subject:`
стоит явное уничтоженное ПДн-значение (ADR-0074).

| Где | Форма |
|---|---|
| после `load` | `%Core.Es.Personal.Destroyed{}` на месте поля целиком, любого вида |
| у апкастера (wire до `load`) | `{"$pd": null}` |

`%Destroyed{}` — struct без полей: ни ключа, ни субъекта, ни длины, экземпляры равны. В
`@type t` нагрузки ПДн-поле получает `| Core.Es.Personal.Destroyed.t()`, а `@spec new` и guard
`new/N` — нет: тип чтения шире типа записи.

- `evolve/2`, `decide/2` и `project/1` MUST разбирать `%Destroyed{}` у каждого поля с `subject:`:
  функция Prim над ним — `FunctionClauseError` только на событии уничтоженного ключа.
- Уничтоженное значение MUST NOT записываться в новое событие: `new/N` его не принимает
  (`FunctionClauseError`), фасад не дампит. Команде, которой нужно уничтоженное ПДн, — доменный
  отказ потребителя.
- Апкастер MAY переносить `{"$pd": null}` как есть, в том числе в оба поля после разделения;
  строковая операция над ним MUST NOT — событие станет нечитаемым.

```elixir
# плохо — функция Prim над уничтоженным значением: свёртка падает после уничтожения ключа
def evolve(state, %Event.HolderSet{payload: payload}),
  do: %{state | holder_name: Holder.value(payload.holder)}

# хорошо — значение поля хранится как есть, уничтоженное разбирается паттерном там, где нужно ПДн
def evolve(state, %Event.HolderSet{payload: payload}), do: %{state | holder: payload.holder}

def decide(%Cmd.Notify{}, %__MODULE__{holder: %Destroyed{}}),
  do: {:error, Errors.domain(__MODULE__, :holder_destroyed, nil)}

# плохо — строковая операция над маркером уничтоженного значения в апкастере
def upcast("order.created.v1", envelope),
  do: %{"name" => String.split(field(field(envelope, :payload), :full_name)) |> hd()}

# хорошо — маркер переносится как есть
def upcast("order.created.v1", %{"payload" => %{"full_name" => %{"$pd" => nil} = destroyed}}),
  do: %{"first_name" => destroyed, "last_name" => destroyed}
```

Ошибки `load` (`ns: :codec`, `module` — модуль нагрузки, `detail: %{field: поле}`):

| Wire поля | Исход |
|---|---|
| `{"$pd": null}` в поле с `subject:` | `%Destroyed{}` |
| `{"$pd": null}` в поле без `subject:` | `:invalid_value` |
| `{"$pd": "<строка>"}` в любом поле | `:sealed_personal_value` |
| `null` необязательного ПДн-поля | `nil` |
| открытое значение | грузится как раньше |

Проверяется: `test/core/es/event/codec_personal_test.exs`, describe «load».

## Хранилище ключей

Порт `Core.Es.Personal.KeyStore` шифрует, расшифровывает, считает индекс и уничтожает ключ
субъекта сам: ключ субъекта порт не покидает (ADR-0075). Операции — пачками, ответ — в порядке
пачки, сбой хранилища — `{:error, %Error{kind: :app}}` на всю пачку; формы и исходы — moduledoc
`Core.Es.Personal.KeyStore`. Библиотека зовёт порт только через фасад `Core.Es.Personal`: он
резолвит реализацию `Core.Config.key_store/0` и эмитит telemetry `[:es, :personal, :call]` и
`[:es, :personal, :open]` (moduledoc `Core.Es.Personal`).

### Своя реализация порта

Встроенная реализация `Core.Es.Personal.KeyStore.Pg` работает по умолчанию; потребитель с
требованием СКЗИ, Vault или KMS подменяет порт целиком —
`config :core, Core.Es.Personal.KeyStore, MyApp.KeyStore`. Её тесты — контрактный набор и
golden своей схемы (`19-testing.md`, «Хранилище ключей»). Своя реализация MUST:

- отвечать на запись ПДн уничтоженного субъекта `Core.Es.Personal.KeyStore.subject_destroyed/1`;
- отдавать неизвестный ключ как `:unreadable`, а не `:destroyed`: потеря хранилища или откат на
  старую копию не выглядят уничтожением;
- начинать шифротекст своей версией схемы: шифротекст открывает только записавшая его
  реализация, и смена реализации на живых данных MUST NOT.

Реализация мимо транзакции вызывающего MAY оставлять ключ-сироту после отката: уничтожает она
необратимо.

```elixir
# плохо — ключа нет в хранилище, а ответ — «уничтожен»: потеря хранилища выглядит уничтожением
defp outcome(nil = _key), do: :destroyed

# хорошо
defp outcome(nil = _key), do: :unreadable
defp outcome(%{destroyed?: true}), do: :destroyed
```

Проверяется: `test/core/es/personal/key_store/contract_test.exs` — набор на встроенной
реализации; `test/core/config_test.exs`, describe «key_store/0» и «validate!/0».

### Встроенная реализация

- Таблица `es_subject_keys` — в базе `Core.Config.dao()` рядом с `es_events`, DDL —
  `Core.Es.Personal.KeyStore.Migration`; миграция и восстановление —
  `deps/core/docs/rules/app/18-migrations.md`, «Таблицы библиотеки».
- Ключ субъекта создаётся в транзакции вызывающего: откат убирает его вместе с событиями. Гонку
  создания решают уникальный индекс по субъекту, вставка в порядке субъектов и одно
  перечитывание; не вышло — `:key_unresolved`.
- Строки ключей пачки `seal/1` читает `FOR SHARE`: уничтожение ждёт commit записи, запись после
  commit уничтожения получает `:subject_destroyed`.
- Уничтожение стирает обёрнутый ключ и оставляет строку следом: субъект без ключа получает след,
  повтор — `:ok` без перезаписи первой даты.
- Кеша ключей нет: запрос — на пачку, развёртка — на каждое обращение; уничтожение действует на
  всех нодах с commit.
- Оценка встроенного шифра по модели угроз — `deps/core/docs/rules/app/23-personal-data.md`,
  «Эксплуатация».

Проверяется: `test/core/es/personal/key_store/pg_test.exs` — сбой хранилища, `:kek_unknown`,
откат ключа, golden схемы `1`; `test/core/es/personal/key_store/race_test.exs` — гонки создания
ключа и уничтожения с записью.

### KEK и секрет индекса

```elixir
config :core, Core.Es.Personal.KeyStore.Pg,
  keks: %{1 => "<base64 32 байт>", 2 => "<base64 32 байт>"},
  current_kek: 2,
  index_secret: "<base64 32 байт>"
```

- `keks:` — набор версий KEK: уникальные положительные целые, ключи по 32 байта. Новые ключи
  субъектов оборачивает `current_kek:`, остальные версии только разворачивают.
- KEK MUST NOT совпадать с `secret_key` `Core.Security.Secret` и MUST NOT лежать в базе.
- Версия KEK строки, которой нет в `keks:`, — `:kek_unknown` (`:app`) на всю пачку расшифровки, с
  повтором: ошибка конфигурации не выглядит уничтожением. Удалять версию из `keks:`, пока под
  ней есть живые ключи, MUST NOT.
- `index_secret:` — 32 байта, отдельно от KEK и без версии; не ротируется. Хранится и копируется
  наравне с KEK.
- Сборка конфигурацию не требует. Приложение с ПДн на встроенной реализации MUST звать
  `Core.Es.Personal.KeyStore.Pg.ensure_configured!/0` в `start/2`: без конфигурации первая
  операция поднимает `ArgumentError` уже под трафиком.

```elixir
# плохо — форма конфигурации всплывёт на первой записи ПДн
def start(_type, _args), do: Supervisor.start_link(children(), strategy: :rest_for_one)

# хорошо
def start(_type, _args) do
  Core.Es.Personal.KeyStore.Pg.ensure_configured!()
  Supervisor.start_link(children(), strategy: :rest_for_one)
end
```

Проверяется: `test/core/es/personal/key_store/config_test.exs`.

### Физический след

Обёрнутый ключ уничтоженного субъекта остаётся в мёртвом кортеже `es_subject_keys`, WAL,
WAL-архиве, репликах и копиях и читается, пока жив KEK его версии (ADR-0075, «Цена»). Запросы с
обёрнутым ключом встроенная реализация шлёт с `log: false`, но telemetry Ecto (`[..., :repo,
:query]`) получает их параметры и строки. Обработчик telemetry Ecto MUST NOT печатать параметры
и результат запросов к `es_subject_keys`. Восстановление из копии — повтор уничтожения по актам
(`deps/core/docs/rules/app/23-personal-data.md`, «Эксплуатация»).

```elixir
# плохо — обработчик печатает параметры: обёрнутый ключ уходит в лог
def handle_event(_event, _measurements, %{query: query, params: params}, _config),
  do: Logger.debug("sql: #{query} params=#{inspect(params)}")

# хорошо — запрос и длительность без параметров
def handle_event(_event, %{total_time: time}, %{query: query}, _config),
  do: Logger.debug("sql: #{query} time=#{time}")
```

## Уничтожение ключа субъекта

`Core.Es.Personal.destroy_key(subject_id, by, context)` → `Result.unit()` — один шаг, окончательный
(ADR-0076). `subject_id` и `by` — UUID-Prim (`Prim.UUID` или `Prim.Compose` над ним); `by` и права —
забота usecase (`deps/core/docs/rules/app/23-personal-data.md`, «Usecase уничтожения»). Транзакция —
вызывающего, если открыта, иначе своя; ключ уничтожен в момент её commit.

В транзакции операция:

1. зовёт `destroy` порта: обёрнутый ключ стирается, строка остаётся следом, субъект без ключа
   получает след — поздняя запись его ПДн получает `:subject_destroyed`;
2. пишет событие уничтожения ключа, если его нет в потоке субъекта, — независимо от ответа порта
   (ADR-0079).

| Ситуация | Исход |
|---|---|
| первый вызов | `:ok`, след и событие |
| повтор, событие уже в потоке | `:ok` без записи; первая дата уничтожения не меняется |
| субъект без ключа | `:ok`, след и событие |
| сбой хранилища | `{:error, %Error{kind: :app}}` вызывающему без лога, событие не пишется |
| откат транзакции вызывающего | ни следа, ни события; своя реализация порта мимо транзакции — ключ уничтожен необратимо, повтор идемпотентен |

Событие уничтожения ключа — `Core.Es.Personal.Event.KeyDestroyed` кодека
`Core.Es.Personal.Event.Codec`:

- поток субъекта: тип агрегата `"core.subject"`, тег `"core.subject.key_destroyed"`, `aggregate_id`
  — `Core.Es.Personal.SubjectID`, версия `1`, нагрузки нет;
- `by` — `Core.Es.Personal.ActorID`, `at` — момент вызова;
- пишет его `Core.Es.Store.append`; в outbox оно не идёт, страница потока его не отдаёт.

Тип `"core.subject"` зарезервирован: кодек библиотека подключает к каждому фасаду сама, и кодек
потребителя с этим `type:` MUST NOT — `CompileError` проверки уникальности типа агрегата фасада.
Строки потока субъекта остаются в `es_events` навсегда — контракт хранения.

Гонку уничтожения с записью ПДн того же субъекта решает блокировка строки ключа: событие либо
записано раньше и уничтожено, либо получает `:subject_destroyed` («Встроенная реализация»).
Несколько субъектов одной транзакцией SHOULD уничтожаться в порядке сортировки их дампа — так же,
как запись ПДн создаёт ключи пачки: произвольный порядок против конкурентного `append` с
несколькими субъектами даёт взаимную блокировку, и Postgres обрывает одну из транзакций
исключением.

```elixir
# плохо — порядок субъектов из ввода: встречный append ловит взаимную блокировку
Enum.reduce_while(subject_ids, :ok, &destroy_next(&1, &2, by, context))

# хорошо
subject_ids
|> Enum.sort_by(&InCodec.dump/1)
|> Enum.reduce_while(:ok, &destroy_next(&1, &2, by, context))
```

Проверяется: `test/core/es/personal/destroy_key_test.exs` — след, событие, повтор, откат;
`test/core/es/personal/destroy_key_failure_test.exs` — сбой порта; `test/core/codec/facade_test.exs`
— `CompileError` на `type: "core.subject"`; golden события —
`test/core/es/personal/event_compat_test.exs`.

## Связанные правила

- Prim и его опции — `11-domain.md`
- Чувствительные данные и `detail` — `12-errors.md`
- Вывод в логи и span'ы — `21-observability.md`
- Тест «значение не утекает в `inspect/1`» — `19-testing.md`
- Нормы приложения — `deps/core/docs/rules/app/23-personal-data.md`
