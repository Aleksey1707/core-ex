# 09: Фасад Codec — сужение `load/2`, `load!/2` и фолбэка `dump/1`

**What to build:** автор подписчика брокера знает тип события из `InCodec.load(Agg.Event, data)` и `InCodec.load!`:
опечатка в поле загруженного события или нагрузки и невозможная clause по результату ловятся при сборке. `InCodec.dump`
struct'а, который не Prim и не тип плагина (команды, View), тоже ловится. Исходы фасада при исполнении прежние.

**Blocked by:** 01

**Status:** resolved

**Spec:** [Типобезопасность потребителя `Core.Es`](../spec.md) — «Фасад Codec — `Core.Codec.Facade`»

- [x] `load/2` на модуль типа или семейства сужает результат по типам плагина (`{:ok, %A{}} | … | {:error, _}`; для
      семейства событий — объединение событий кодека) в `generated: true`.
- [x] `load!/2` получает те же clauses по плагинам и падает `raise` сам; Prim-фолбэк `load/2` и `load!/2` прежний.
- [x] Фолбэк `dump/1` сужен guard'ом `is_prim/1`.
- [x] Фикстура: маркеры H3a (опечатка в поле события после `load(Agg.Event, …)`), H3b (в поле нагрузки после
      `load(Event.X, …)`), H3c (невозможная clause), H6 (`dump` команды), опечатка после `load!`. Корректные вызовы
      фасада, dump-only плагин — ноль предупреждений.
- [x] ExUnit фасада Codec — прежние исходы.
- [x] moduledoc `Core.Codec.Facade`; `11-domain.md`, если описывает результат фасада.
- [x] `CHANGELOG.md`: пункт фасада дополнен или новый — по правилам CHANGELOG.
- [x] `make` зелёный.

## Comments

- 2026-09-17 — реализация:
  - `use Core.Codec.Facade`: клоуза плагина `load/2` / `load!/2` — `case plugin.load(mod, raw, __MODULE__)`,
    clauses строит `Core.Codec.Facade.load_clauses/3` (`@doc false`) в `quote generated: true`: `{:ok, <pattern> =
    value}` на каждый тип (для семейства — все типы плагина), у `load/2` — `{:error, reason} -> {:error, reason}`, у
    `load!/2` — `{:error, %Core.Error{} = error} -> raise Core.Exc, error`. Prim-фолбэки `load/2` / `load!/2` прежние
    (`load!/2` — через `Core.Result.unwrap!/1`, строка `DEBT.md` уточнена). Клоузы одной функции сгруппированы: dump,
    load, load!;
  - паттерн события — `Core.Es.Check.event_pattern/1` (`%Event.X{payload: %Payload{}}` / `payload: nil`), признак —
    `__es_type__/0` у плагина. Сверх текста спеки («`{:ok, %A{}}`»): поля struct компилятор не типизирует, и без
    нагрузки в паттерне H3b молчал. Исход при исполнении прежний — `new/6` события уже требует `%Payload{}`;
  - фолбэк `dump/1` — `when Core.Guard.is_prim(value)` (`require`, не `import`: имя в модуле фасада не занимается).
    Отступление от «Исходы фасада при исполнении прежние»: struct без плагина и без поля `value` —
    `FunctionClauseError` вместо `ArgumentError` — прямое следствие guard'а и запрета защитной clause с `raise`
    (`20-agreements.md`, «Домен функции»). Struct с `value`, но не Prim, — по-прежнему `ArgumentError`. Плагин вне
    контракта `load/3` (не struct запрошенного типа; у `load!/2` — ошибка не `%Core.Error{}`) — `CaseClauseError`.
    Записано в CHANGELOG;
  - фикстура: `lib/scenarios/codec.ex` — H3a, H3b, H3c, H3e (опечатка после `load!/2` без паттерна — «опечатка после
    `load!`» тикета), H6; dump-only плагин `Consumer.Account.Card.Codec` в фасаде и типовые вызовы в
    `Consumer.Usecase` (`load/2` по модулю события с чтением нагрузки, `load!/2` по семейству, Prim, dump события,
    карточки и Prim) — ноль предупреждений. Маркеров 97 (было 92). Мутации: без паттерна нагрузки гаснет H3b, без
    сужения — H3a/H3c/H3e, без guard'а — H6. Снятие `generated: true` предупреждений в фикстуре не добавляет: её
    плагины — тот же проект, их `load/3` — `dynamic()`, у `Core.Outbox.Codec` обе clauses достижимы; разметка
    оставлена для плагинов из зависимостей, храповик её не держит;
  - ExUnit `facade_test.exs`: `load/2` и `load!/2` по модулю события (с нагрузкой и без, ошибка загрузки), `load!/2`
    по семейству с неизвестным тегом, dump-only и Prim — `Core.Exc` / `ArgumentError`; `dump/1` struct без `value`
    — `FunctionClauseError`, с `value` не Prim — `ArgumentError`;
  - `11-domain.md`: фолбэк `dump/1` и сужение результата; moduledoc — раздел «Сужение результата»; CHANGELOG — новый
    пункт в «Ломающие изменения контракта» (фасад и сужение существовали до «Не выпущено», сменился класс
    исключения).
- 2026-09-17 — по ревью: пункт CHANGELOG перенесён из «Изменения контракта макросов» в «Ломающие изменения
  контракта»; `import Core.Guard` → `require`; строка `DEBT.md` о генерируемых функциях; describe теста назван
  «`load/2` и `load!/2` по модулю события». Не принято: модальность и строка `Проверяется:` в пунктах фасада
  `11-domain.md` — соседние пункты описательные, ссылка на `make consumer-check` в скобках как в
  «Event-sourced»; общий comprehension для `load/2` и `load!/2` — clauses функций должны идти группами;
  паттерн от плагина вместо `event_pattern/1` в фасаде — новый колбэк плагина ради одного вида типов;
  `@doc false` у `load_clauses/3` — хелпер раскрытия макроса, как `Es.Check`.
