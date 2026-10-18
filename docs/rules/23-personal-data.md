# Персональные данные

- **Область.** `lib/core/prim.ex`, `lib/core/prim/**` (опция `personal:`), `lib/core/codec.ex`
  (`load_composite/3`), `lib/core/es/event/payload.ex` и `lib/core/codec/plugin/fields.ex`
  (`subject:`), `lib/core/es/personal/**`; у потребителя — Prim с персональными данными (ПДн) и
  события с ними.
- **Читать перед.** Новым Prim, значение которого — ПДн; полем нагрузки события с ПДн;
  переводом Prim с ПДн с `sensitive:` на `personal:`; правкой редакции значения Prim в выводе;
  апкастером и `evolve/2` / `project/1` события с полем `subject:`.
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

## Связанные правила

- Prim и его опции — `11-domain.md`
- Чувствительные данные и `detail` — `12-errors.md`
- Вывод в логи и span'ы — `21-observability.md`
- Тест «значение не утекает в `inspect/1`» — `19-testing.md`
- Нормы приложения — `deps/core/docs/rules/app/23-personal-data.md`
