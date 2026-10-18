# 28: Метрики хранилища ключей и алерты

**What to build:** дежурный инженер видит вызовы хранилища ключей и исходы расшифровки в `Core.Es.PromEx`. В сводах
есть рекомендованные алерты на нечитаемые ПДн-значения и на сбои хранилища. Своя реализация порта получает метрики
даром: их эмитит фасад из тикета 20.

**Blocked by:** [20: Хранилище ключей: порт и встроенная реализация](20-key-store.md)

**Status:** resolved

**Spec:** [Crypto-shredding: ПДн в событиях под ключом субъекта](../spec.md) — «Наблюдаемость»

- [x] `Core.Es.PromEx`, группа `:es_aggregate_event_metrics`, рядом с `key_reservation`:
      - `…_es_personal_call_total{op,result}`;
      - гистограмма `…_es_personal_call_duration_<unit>`;
      - `…_es_personal_open_total{outcome}`.

      Меток с идентификаторами субъекта, ключа и агрегата нет.
- [x] Тест — как тест группы `key_reservation`.
- [x] `21-observability.md`:
      - «Рекомендованные алерты» — `EsPersonalUnreadable` (рост `outcome="unreadable"`: потеряно хранилище ключей,
        восстановлен старый бэкап или чужой KEK) и `EsKeyStoreErrors` (рост `result="error"`) с PromQL; метка с
        идентификатором субъекта, ключа или агрегата — MUST NOT;
      - «Где ставить span» — у порта и уничтожения ключа span'а нет.
- [x] app/21 «Алерты event sourcing» — оба алерта SHOULD, с действием оператора.
- [x] README, «Имена метрик». `CHANGELOG.md`, сквозной пункт: метрики.
- [x] `make` зелёный.
