# 21: ПДн-поле нагрузки: `subject:`, маркер и уничтоженное значение в кодеке

**What to build:** автор события объявляет `subject:` у поля нагрузки, и сборка ловит забытую разметку и неверного
субъекта. Кодек событий на `dump` кладёт маркер ПДн-значения, который JSON не кодирует. На `load` он превращает
`{"$pd": null}` в `%Core.Es.Personal.Destroyed{}`, а шифротекст, дошедший до `load`, распознаёт отдельно.

Всё — чистый кодек, без БД. До тикета 23 запись события с ПДн падает на маркере; так и задумано.

**Blocked by:** [19: Персональный Prim: `personal: true`](19-personal-prim.md)

**Status:** resolved

**Spec:** [Crypto-shredding: ПДн в событиях под ключом субъекта](../spec.md) — «Разметка», «Кодек событий: маркер и
уничтоженное значение»; ADR-0072, ADR-0073, ADR-0074

- [x] Спека поля `fields:` у `Core.Es.Event.Payload` получает `subject:` — `:aggregate_id` или поле той же нагрузки.
      Плагин сущности вне нагрузки события и View `subject:` не принимают.
- [x] `CompileError`:
      - персональный Prim на прямом поле нагрузки (`prim:` / `list: [prim:]`) без `subject:`;
      - субъект — не `Prim.UUID` и не `Prim.Compose` над ним; для `subject: :aggregate_id` это проверяет
        `use Core.Es.Event`;
      - обязательное ПДн-поле при необязательном поле-субъекте;
      - `subject:` на несуществующее поле или на само себя;
      - wire-ключ на `$` — у любой нагрузки.
- [x] `@type t` получает `| Core.Es.Personal.Destroyed.t()` у ПДн-поля. `@spec new` и guard `new/N` остаются
      прежними; guard отвергает `nil` в поле-субъекте при непустом ПДн-значении.
- [x] `Inspect` нагрузки не выводит поля с `subject:`. `detail` ошибки `load` под таким полем редактируется, какого
      бы вида ни было поле.
- [x] Интроспекция: `subject:` в `__es_payload_fields__/0`, у кодека событий — `__es_subjects__/0` (поля `subject:` по
      модулю события).
- [x] `dump`:
      - на месте значения — маркер `%Core.Es.Personal.Marker{}`: субъект и wire-значение;
      - `nil` остаётся `nil`;
      - на месте `%Destroyed{}` — маркер уничтоженного значения;
      - голова `dump` отвергает непустое ПДн-значение при `nil` субъекта;
      - `Jason.Encoder` маркера поднимает исключение без значения, `inspect/1` показывает только субъекта.
- [x] `load`:
      - `{"$pd": null}` в поле с `subject:` → `%Destroyed{}` на месте поля целиком, любого вида;
      - то же в поле без `subject:` → `:invalid_value`, `ns: :codec`;
      - `{"$pd": "<строка>"}` → `:sealed_personal_value`, `ns: :codec`;
      - `null` необязательного ПДн-поля → `nil`;
      - строки, записанные открытыми, грузятся как раньше.
- [x] `Core.Es.Personal.Destroyed` — struct без полей, экземпляры равны. Фасад его не дампит.
- [x] Фикстуры:
      - `Account.Holder` (`personal: true`), событие `Account.Event.HolderSet`
        (`holder: [prim: Account.Holder, subject: :aggregate_id]`), команда и клауза `evolve`;
      - событие `ContactSet` кодека `Core.EventFixture`: `person_id`, `contact` с `subject: :person_id`, `note` с
        `subject: :aggregate_id`;
      - открытые golden обоих событий; нынешние `EventCompatCase` зелёные;
      - прежние события, `Name`, `NameKey` и их golden не меняются.
- [x] Фикстура-потребитель: персональный Prim и поле `subject:` в `Sales.Account`, маркеры `# expect:` — по факту;
      `make consumer-check` зелёный.
- [x] Тесты — чистые, `async: true`: все `CompileError`, маркер, `load` во всех формах, `inspect` нагрузки и маркера,
      `Jason.Encoder`.
- [x] Свод:
      - 23 «Разметка» дополнена: `subject:`, единица шифротекста, вложенная сущность вне проверки сборкой, `nil`
        субъекта, `$`;
      - 23 «Уничтоженное ПДн-значение»: форма после `load`, `{"$pd": null}` у апкастера, запрет записи и дампа
        фасадом;
      - `11-domain.md` «Нагрузка по полям»;
      - `12-errors.md` — коды `ns: :codec`;
      - `21-observability.md` — нагрузка и маркер в выводе.
- [x] `CHANGELOG.md`:
      - «Изменения контракта макросов» — `subject:` у поля `Payload`, `CompileError` на `$` и при ПДн;
      - сквозной пункт — разметка, маркер и `%Destroyed{}`.
- [x] `make` зелёный.
