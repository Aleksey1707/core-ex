# 18: Модуль ключа с `aggregate:`

**What to build:** автор модуля ключа ссылается на агрегат одной опцией `aggregate:` вместо `event:` / `id:`. Неполный
`reservation/1` предупреждает на строке `use` ключа, а не репозитория, и ловится без репозитория. Чужой ID в `find/2`
по-прежнему даёт предупреждение; ключ другого агрегата в `key_reservations:` — `CompileError` в `Repo.Pg`; `aggregate:`
ключа не агрегат — `CompileError`. Спека — `../spec.md`, «`Core.Es.KeyReservation`», «`Core.Es.Aggregate.Repo.Pg`»
(ключи), «Порядок работ», срез 4; ADR-0084. Образец — `prototype/key-reservation-wiring`.

**Blocked by:** 16.

**Status:** resolved

- [x] `KeyReservation`: обязательны `scope:`, `aggregate:`, `code:`, опциональна `personal:`; `event:` / `id:` ушли.
  `aggregate:` — `module!` с `exports: [__es_event_codec__: 0]`; id — `__es_aggregate_id__/0` кодека, литерал в
  `find/2` и его `@spec`.
- [x] Функции-проверки «reservation/1 принимает <Event>» генерирует `use` ключа по `__es_mods__/0` кодека.
- [x] `declaration` ключа несёт `aggregate`, `event_codec`, `id`; `event` ушёл.
- [x] `Repo.Pg` (`declarations!`): агрегат ключа равен агрегату репозитория — `key_reservations: aggregate: <X> у
  <Key> не равен агрегату репозитория <Agg>`; clause `code:` и уникальность `scope` — как сейчас.
  `KeyReservation.checks/3` и `reservation: 1` в `exports:` ушли. Агрегат репозитория — тот, что `Repo.Pg` знает на
  момент вливания.
- [x] Все `use Core.Es.KeyReservation` в `lib/`, `test/`, фикстуре переведены.
- [x] Тесты: ключ чужого агрегата в `key_reservations:`; `aggregate:` ключа — не агрегат; тесты сверок `event:` /
  `id:` ключа переписаны на сверку агрегата; старая форма — одно сообщение.
- [x] `make consumer-check`: сценарий `key_reservation.ex` (чужой ID в `find/2`, неполный `reservation/1`, опечатка в
  поле нагрузки — маркер на строке `use` ключа) даёт те же предупреждения; `BadKey.Repo.Pg` / `BadKeyPayload.Repo.Pg`
  удалены.
- [x] `@moduledoc` `Core.Es.KeyReservation`.
- [x] Своды `13-repos.md` («Резервы ключей»), `app/13-repos.md` («Уникальность без индекса состояния»).
  `make rules-check`.
- [x] CHANGELOG: строка `use Core.Es.KeyReservation` и сверки ключа; строка 4 «Версии библиотеки».
- [x] С тикетом 17 конфликт в `Es.Aggregate.Repo.Pg`: вливаемый вторым перестраивается на первый.
- [x] Приёмка: `make` целиком.
- [ ] После влития удаляется ветка `prototype/key-reservation-wiring`.

## Comments

- Ключ чужого агрегата проверяется на `Catalog.PathKey` в репозитории `Account` — одно сообщение вместо прежних
  двух сверок (`event:` и `id:`); отдельный тест чужого `id:` снят: id ключа берётся из кодека агрегата.
- Вливался вторым: после merge тикета 17 агрегат ключа сравнивается с агрегатом из `behaviour.__es_aggregate_repo__()`;
  конфликты — строки таблиц CHANGELOG и «Версия библиотеки» (обе сохранены), сценарии `BadKey*.Repo.Pg` (удалены).
- `app/23-personal-data.md` (пример ключа из ПДн) и `19-testing.md` («Резерв ключа») — тоже переведены: там была
  старая форма и «полноту проверяет сборка репозитория».
- Не отмечено: удаление `prototype/key-reservation-wiring` — делает оркестратор после влития.
