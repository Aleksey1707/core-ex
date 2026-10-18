# Персональные данные приложения

- **Область.** `lib/my_app/**`: код, который извлекает ПДн-значение из Prim (`Prim.value/1`,
  `raw/1`, сопоставление `%Mod{value: v}`) и выводит его.
- **Читать перед.** Логом, исключением или атрибутом span'а рядом с ПДн; новым Prim с ПДн.
- **Словарь.** Плейсхолдеры и модальность — `deps/core/docs/rules/00-index.md`; термины —
  `deps/core/CONTEXT.md`, «Персональные данные».

Разметку `personal: true` и то, что библиотека скрывает сама, нормирует
`deps/core/docs/rules/23-personal-data.md`. Здесь — то, что остаётся на приложении.

## Вывод

Библиотека скрывает ПДн-значение, пока оно в своей форме — Prim с `personal: true`. Извлечённое
значение — строка, число, дата — уже не Prim, и `Inspect` его не скрывает.

- Извлечённое ПДн-значение MUST NOT попадать в текст `raise`, в `Logger.*` и в атрибут span'а.
- Вместо значения выводится идентификатор агрегата или субъекта, длина или признак наличия.
- Prim с ПДн целиком в `Logger.*` и в `inspect/1` MAY: значение скрывает его `Inspect`.

```elixir
# плохо — телефон уходит в лог и в службу учёта ошибок открытым
Logger.warning("контакт не принят: phone=#{Phone.value(phone)}")
raise ArgumentError, "неверный телефон #{Phone.value(phone)}"

# хорошо
Logger.warning("контакт не принят: client_id=#{InCodec.dump(client.id)}")
raise ArgumentError, "неверный телефон: client_id=#{InCodec.dump(client.id)}"
```

## Связанные правила

- Разметка ПДн и редакция Prim — `deps/core/docs/rules/23-personal-data.md`
- Уровни и формат логов — `20-agreements.md`
- Секреты и `detail` на границах — `12-errors.md`
- Служба учёта ошибок — `21-observability.md`
