# 02: `Reader.Poll` — один цикл ожидания

**What to build:** три читателя — stream, Kafka и DLQ — ждут сообщение через один модуль: он владеет
deadline, интервалом, заявкой на готовность и исходом `:nothing_to_commit` по таймауту. Особенности
адаптеров (буфер и chunk у stream, партиции и аренда у Kafka, база у DLQ) остаются на месте; backoff,
интервал по умолчанию и решение «опрашивать или ждать заявку» остаются у подписчика. Спека —
`.scratch/mq-lease-reader/spec.md`.

**Blocked by:** C1 (`01-mq-lease`).

**Status:** resolved

- [ ] Общий цикл ожидания: чтение, ожидание готовности, deadline и `:nothing_to_commit`; backoff и политика опроса не переезжают.
- [ ] Три читателя используют его; собственных `poll/2`, `deadline/1`, `timed_out?/1` и повторов `Process.sleep` не остаётся.
- [ ] Поведение `get`/`commit`, исходы пустоты и ошибок брокера прежние; `exit` процесса-читателя не переупаковывается.
- [ ] Unit-тесты цикла на фейковом чтении: сообщение до таймаута, пустота до таймаута, заявка на готовность, отсутствие busy-loop.
- [ ] Поведение подписчика не изменилось; его тесты проходят без правок.
- [ ] `make`, `make test-stream`, `make test-kafka` зелёные; CHANGELOG не меняется.

## Comments

Resolved in `6ffeb70`. `Core.Mq.Reader.Poll` owns the deadline, interval
and `{:error, :nothing_to_commit}` outcome; readers map it back to `:empty` via
`Poll.await_empty/4` (review fixes `e93c502`). Stream/Kafka `get/2` pass no readiness request:
the reader has one slot and a timed-out `get` must not clobber a subscriber's request.
Subscriber code and tests unchanged. `make`, `make test-stream`, `make test-kafka` green.
