---
name: domain
description: "Свод правил домена библиотеки Core: Core.Prim (String/Integer/Decimal/UUID/DateTime/Date/Compose, sensitive), Core.Enum (values:/codes:, описания значений в @moduledoc), опции Prim-профиля Codec (uuid/datetime/datetime_tz/date/decimal), плагины и фасады (dump/load только через фасад, union, dump-only), Core.View, агрегаты state-stored и event-sourced (Core.Es.Aggregate: decide/evolve, fold/execute), команды Core.Es.Cmd, агрегаты против представления, Es.Event, Context и Context.Accessor, Version, Pagination, Result/Option. Использовать при заведении или правке примитивов, enum, кодеков, событий, команд, View и агрегатов."
---

# 11-domain.md

Прочитай `docs/rules/11-domain.md` целиком перед правкой и следуй ему: свод обязателен,
пересказ по памяти не годится.

Осознанные отступления от сводов — `docs/rules/DEBT.md`. Сверься с ним, прежде чем
«чинить» найденное несоответствие: часть из них оставлена намеренно.
