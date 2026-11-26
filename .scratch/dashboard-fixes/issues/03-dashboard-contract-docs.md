# 03: Документы контракта дашбордов

**What to build:** потребитель читает CHANGELOG, ADR, README, спеку consumer-tooling и тикеты — и
видит только существующее поведение: без `standard?/1`, без `--assign`, с одной схемой `uid`, с
`stale/2`/`surplus/2`, покрывающими `standard/0`, с памятью контейнера на `container` и штатными
PromEx-дашбордами в scope. README объясняет миграцию `graph` → `timeseries`, смену `uid` и удаление
старых плиток после переэкспорта. Спека: `.scratch/dashboard-fixes/spec.md`.

**Blocked by:** 01, 02 — документы описывают уже реализованное поведение.

**Status:** ready-for-agent

- [ ] CHANGELOG: убран `standard?/1`; убран `--assign title=`; `uid` описан одной схемой для подсистемных и штатных дашбордов; `stale/2`/`surplus/2` упоминают `standard/0`; старый пункт про память в `workers` и `workers_container_memory_*` исправлен на `container` и `container_memory_*`
- [ ] Правки CHANGELOG дополняют существующие пункты «Не выпущено», новых дублей нет
- [ ] ADR-0099: `uuid` → `uid`
- [ ] README: штатные `application`/`beam`/`phoenix`/`ecto`/`oban`, миграция `graph` → `timeseries`, смена `uid`, удаление старых плиток
- [ ] `.scratch/consumer-tooling/spec.md`: US 18 и список шаблонов — память на `container`; Testing Decisions — `stale/2`/`surplus/2` проверяют `standard/0`
- [ ] Тикеты consumer-tooling 04 и 07 не противоречат `container` и штатным выгрузкам
- [ ] `make rules-check` и `make` зелёные
