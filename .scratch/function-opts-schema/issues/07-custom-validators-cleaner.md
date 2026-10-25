# 07: Custom-валидаторы вместо доменных проверок `StartOpts`

**What to build:** опции старта OTP-процесса объявляются схемой над `init/1`, включая доменные
значения — Prim, фильтр топиков, имя процесса, `shutdown`, — и опечатка в дереве супервизии
по-прежнему падает в `init/1` с именем ключа. Описание опций старта — в `@moduledoc` из схемы.
Первый переведённый процесс — `Outbox.Cleaner`.

Спека — «Custom-валидаторы вместо `Core.Helper.StartOpts`», «Объём перевода», волна 2;
`17-otp-concurrency.md`.

**Blocked by:** 02

**Status:** resolved

- [x] Доменные проверки `prim`, `topics_filter`, `name`, `shutdown` доступны схеме в форме
      `{:custom, mod, fun, args}`: `{:ok, value}` / `{:error, message}`, тексты на русском.
- [x] Прежние функции `StartOpts` остаются до тикета 11: процессы, ещё не переведённые, работают
      как раньше.
- [x] `Outbox.Cleaner`: схема над `init/1`, вызовы `StartOpts` убраны, `child_spec` / `start_link`
      без схемы, опции описаны в `@moduledoc` через функцию описания `Core.Options`.
- [x] Тесты custom-валидаторов: значение принято / отклонено с текстом (перенесены с `StartOpts`).
- [x] Тест `Outbox.Cleaner`: неверные опции старта — `ArgumentError` в `init/1`; остальные зелёные.
- [x] CHANGELOG: если меняется видимое потребителю поведение `Outbox.Cleaner` (неизвестный ключ
      раньше проходил) — функция добавлена в список «Ломающих».
- [x] `make` зелёный.

## Comments

- Custom-валидаторы — в `Core.Helper.StartOpts`, блок «custom-валидаторы схемы»: `prim/2`
  (модуль Prim в args), `module/1`, `name/1`, `topics_filter/1`, `shutdown/1`. Возврат
  `{:ok, value}` / `{:error, "ожидается …, получено …"}`; префикс `invalid value for :<key> option: `
  добавляет NimbleOptions, `<Mod.fun/n>: ` — `Core.Options`.
- `module/1` сверх списка спеки: встроенный `:atom` пропускает `nil`, а прежний `module!/3` его
  отклонял (`repo: nil` из незаданного env). Необязательная опция-модуль с умолчанием `nil`
  (`module!/4`) — встроенный `:atom`.
- У custom-ключа схемы — `type_doc:`: тип custom-значения NimbleOptions в описании не выводит.
- Старые функции с `!` остаются (блок «проверки с raise»); `name!` / `topics_filter!` /
  `shutdown!` делегируют валидаторам, текст отказа прежний. Их тесты сохранены: функции ещё
  используются непереведёнными процессами, удаляет их тикет 11.
- CHANGELOG не тронут: `Outbox.Cleaner` неизвестный ключ и значение не той формы отклонял и
  раньше, сменился только текст отказа (внутреннее по `AGENTS.md`), класс — прежний `ArgumentError`
  при старте.
- `init/1` получил `@spec init(keyword()) :: {:ok, t()}` (`20-agreements.md`, «Спецификации
  типов»: `@impl` не освобождает).
- `Outbox.Cleaner.child_spec/1` больше не проверяет `name:` (вызов `StartOpts` убран, `child_spec`
  без схемы): `:id` — `Keyword.get(opts, :name) || __MODULE__`, имя не той формы отклоняет
  `GenServer.start_link/3` до `init/1` (`expected :name option …`). `name:` в схеме `init/1` нужен:
  ключ приходит в `init/1`, без него он был бы неизвестным.
- `17-otp-concurrency.md`, «`init/1`»: проверка опций процесса — схемой над `init/1`, доменные
  значения — custom-валидаторы `StartOpts`. `docs/rules/app/17-otp-concurrency.md` не тронут
  (спека: свод потребителя не меняется).
