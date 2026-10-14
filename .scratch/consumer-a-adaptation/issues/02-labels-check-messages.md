# 02: Текст compile-ошибок подписей расходится с moduledoc

**What to build:** moduledoc `Core.Labels.Check` описывает форму текста compile-ошибки подписей
«… — после `where`», а код пишет `"#{where}: …"`. Привести к одной форме.

Места (из отчёта потребителя A, номера строк сверить):

- `lib/core/labels/check.ex` — около :46, :51;
- `lib/core/labels/fields.ex` — около :272, :275;
- `Core.Labels.Values.ensure_none!`;
- `Core.Labels.ID.reject!`.

**Решение:** правится moduledoc под код, а не код под moduledoc. Форма `"#{where}: …"` стоит в шести
местах и проверяется тестами; moduledoc — одно место. Если по файлам окажется, что код сам
непоследователен (часть мест в другой форме), — привести код к `"#{where}: …"`.

**Status:** ready-for-agent

**Spec:** этот файл.

## Готово, когда

- moduledoc `Core.Labels.Check` описывает форму `"<where>: <текст>"` так, как её пишет код;
- все места из списка пишут одну форму;
- CHANGELOG не трогается, если меняется только moduledoc (внутреннее, `CLAUDE.md`, «CHANGELOG»);
- `make` зелёный.

## Comments
