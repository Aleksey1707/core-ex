# 32: Снапшоты event-sourced агрегата

**What to build:** автор домена включает `snapshot: [every: N, version: V]` у репозитория, и `get` / `get_many` /
`refresh` длинного потока сворачивают только хвост после снапшота. Снапшот — кэш: пишется после commit, сбрасывается при
правке кода агрегата и событий, любой его отказ даёт полную свёртку, а не ошибку.

**Blocked by:** [31: Write-репозиторий event-sourced агрегата](31-event-sourced-repo.md)

**Status:** ready-for-agent

**Spec:** [Event-sourced агрегат в :core](../spec.md) — «Снапшоты»

- [ ] Опция `snapshot:` у `use Core.Es.Aggregate.Repo.Pg`: `every:` обязателен без значения по умолчанию, `version:` —
      целое, по умолчанию 1; проверка на компиляции; без опции — поведение тикета 31.
- [ ] `Core.Es.Migration` создаёт `es_snapshots`: PK `(тип, aggregate_id)`, `aggregate_version`, `marker`,
      `state bytea`, `updated_at`.
- [ ] Маркер — md5 модуля агрегата, кодека событий и модулей событий (интроспекция кодека) + `version:`.
- [ ] Чтение одним запросом: `LEFT JOIN LATERAL` снапшота с маркером в условии + события после его версии; `get_many` —
      все пары одним запросом; `get(id, %Version{})` сверяет голову после свёртки.
- [ ] Свёрнуто ≥ N событий после снапшота (или с начала потока) → upsert
      `WHERE marker <> new OR aggregate_version < new` синхронно в хуке `AfterCommit` (вне транзакции — сразу);
      `get_many` — один upsert на несколько строк; свой
      `rescue` → `warning`, успех — `debug`; `refresh` пишет по тому же правилу; `append` не меняется.
- [ ] Отказ: несовпавший маркер — полная свёртка тем же запросом без `warning`; ошибка `binary_to_term(bin, [:safe])`,
      расхождение ключей struct с `defstruct` или исключение `fold/2` от снапшота — `warning` и второй запрос всего
      потока; `raise` — только если не читается сам поток.
- [ ] `Account.Repo.Pg.Snapshotted` (`every: 2`) проходит контрактный набор тикета 31. Тесты снапшота на нём: upsert
      после ≥ N, один upsert у `get_many`, промах маркера прямым `UPDATE`, битый `bytea` и лишний ключ struct →
      `warning` и верное состояние.
- [ ] Telemetry: `[:es, :aggregate, :load]` дополнен `snapshot_hit` / `snapshot_miss` / `snapshot_rejected`;
      `[:es, :aggregate, :fold]` — `snapshot: :hit | :miss | :rejected | :off`; `[:es, :snapshot, :write]`
      (`duration`, `rows`; `type`, `result: :ok | :error`).
- [ ] `13-repos.md` — `snapshot:` и MUST поднять `version:`, если `evolve` зависит от кода вне модуля агрегата, кодека
      и модулей событий; «Наименование» — `es_snapshots`. `CHANGELOG.md`, «Новое».
- [ ] `make` зелёный.
