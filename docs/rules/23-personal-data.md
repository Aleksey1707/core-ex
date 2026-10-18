# Персональные данные

- **Область.** `lib/core/prim.ex`, `lib/core/prim/**` (опция `personal:`), `lib/core/codec.ex`
  (`load_composite/3`); у потребителя — Prim с персональными данными (ПДн).
- **Читать перед.** Новым Prim, значение которого — ПДн; переводом Prim с ПДн с `sensitive:` на
  `personal:`; правкой редакции значения Prim в выводе.
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

## Связанные правила

- Prim и его опции — `11-domain.md`
- Чувствительные данные и `detail` — `12-errors.md`
- Вывод в логи и span'ы — `21-observability.md`
- Тест «значение не утекает в `inspect/1`» — `19-testing.md`
- Нормы приложения — `deps/core/docs/rules/app/23-personal-data.md`
