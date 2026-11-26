# 03: Документы контракта дашбордов

**What to build:** потребитель читает CHANGELOG, ADR, README, спеку consumer-tooling и тикеты — и
видит только существующее поведение: без `standard?/1`, без `--assign`, с одной схемой `uid`, с
`stale/2`/`surplus/2`, покрывающими `standard/0`, с памятью контейнера на `container` и штатными
PromEx-дашбордами в scope. README объясняет миграцию `graph` → `timeseries`, смену `uid` и удаление
старых плиток после переэкспорта. Спека: `.scratch/dashboard-fixes/spec.md`.

**Blocked by:** 01, 02 — документы описывают уже реализованное поведение.

**Status:** resolved

- [x] CHANGELOG: в «Не выпущено» `standard/0` — единственный API имён штатных дашбордов (упоминание `standard?/1` убрано); заголовок — `app_title`, точечной подмены `title` нет; `stale/2`/`surplus/2` покрывают `standard/0`; память контейнера — в пункте `container`
- [x] Правки CHANGELOG — в «Не выпущено»; выпущенный 0.17.0 не переписан
- [x] ADR-0099: `uuid` → `uid`
- [x] README: штатные `application`/`beam`/`phoenix`/`ecto`/`oban`, миграция `graph` → `timeseries`, смена `uid`, удаление старых плиток
- [x] `.scratch/consumer-tooling/spec.md`: US 18 и список шаблонов — память на `container`; Testing Decisions — `stale/2`/`surplus/2` проверяют `standard/0`
- [x] Тикеты consumer-tooling 04 и 07 не противоречат `container` и штатным выгрузкам
- [x] `make rules-check` и `make` зелёные
