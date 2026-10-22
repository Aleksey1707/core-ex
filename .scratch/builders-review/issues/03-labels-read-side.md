# 03: Чтение подписей — одна классификация и один обход

**Status:** needs-triage

**Blocked by:** 01 — Prim сам отдаёт leaf и kind; `.scratch/codec-field/` (struct поля)

**Сила:** Strong.

**Файлы:**
- `lib/core/labels/details.ex` — `prim_shape`, `plain_kind`, `declaration`, `change_detail` (~140–218);
- `lib/core/labels/refs.ex` — `classify`, `prim_role`, `visible_fields` (~95–134);
- `lib/core/labels/completeness_case.ex` — `walk`, `visit`, `unkinded?`, `specs` (~250–340);
- `lib/core/labels/fields.ex` — `specs`, `paths` (~400–440);
- `lib/core/labels/event.ex` (~137).

**Проблема.**
- Правило «как Prim выходит в сведения» записано трижды: в `Details.declaration` / `plain_kind`, `Refs.prim_role` и `CompletenessCase.unkinded?`. Оно состоит из `Text.find` + `ID.find`, спуска к `__domain_base__`, проверки `__domain_kind__` и пробела для `:uuid`.
- Дерево нагрузки обходится четырьмя способами: по спеке и значению, по значению, по типам с раскрытием семейств и по спеке.
- Подстановка «change → `[old_value, new_value]`» повторена трижды.
- Предикат «модуль подписан» реализован пять раз, и модуль в нём загружается по-разному: `ensure_compiled`, `ensure_loaded` или голый `function_exported?`.
- `__label_fields__` читается в обход interface `Labels.Fields` в шести местах.

**Что изменилось бы.** На вопросы «вид значения в сведениях» и «видимые поля struct» отвечает один module. Details, Refs и CompletenessCase спрашивают его, а не собирают ответ сами.

**Выигрыш.** Ситуация «сведения показали значение, а словарь ссылок его не собрал» становится невозможной. Классификацию можно тестировать без построения событий. Locality: правило `text:` / `change:` правится в одном месте.

**ADR:** конфликта нет. ADR-0063 фиксирует объявления подписей, а не модули, которые их читают.
