defmodule Core.Es.Projection.ReaderTest do
  use ExUnit.Case, async: true

  alias Core.Es.Projection.Reader

  @intervals %{
    idle_min_ms: 50,
    poll_interval_ms: 1_000,
    retry_min_ms: 1_000,
    retry_max_ms: 30_000
  }

  describe "next_tick/3" do
    test "исход цикла и wake во время цикла → задержка следующего тика и backoff'ы" do
      # {исход, wake во время цикла, idle_ms, retry_ms} → {задержка, idle_ms, retry_ms}
      table = [
        # пачка с работой — сразу следующая, backoff'ы сброшены
        {{:processed, false, 400, 8_000}, {0, 50, 1_000}},
        {{:processed, true, 400, 8_000}, {0, 50, 1_000}},
        # холостая и заблокированная — удвоение от idle_min_ms до poll_interval_ms
        {{:idle, false, 50, 1_000}, {50, 100, 1_000}},
        {{:locked, false, 100, 1_000}, {100, 200, 1_000}},
        {{:idle, false, 800, 1_000}, {800, 1_000, 1_000}},
        {{:idle, false, 1_000, 1_000}, {1_000, 1_000, 1_000}},
        # wake во время цикла — сразу, счётчик не сброшен
        {{:idle, true, 400, 1_000}, {0, 400, 1_000}},
        {{:locked, true, 400, 1_000}, {0, 400, 1_000}},
        # холостая пачка заканчивает серию повторов — retry_ms с начала, заблокированная — нет
        {{:idle, false, 50, 8_000}, {50, 100, 1_000}},
        {{:idle, true, 400, 8_000}, {0, 400, 1_000}},
        {{:locked, false, 100, 8_000}, {100, 200, 8_000}},
        {{:locked, true, 400, 8_000}, {0, 400, 8_000}},
        # повтор — удвоение от retry_min_ms до retry_max_ms, wake не ускоряет
        {{:retry, false, 400, 1_000}, {1_000, 400, 2_000}},
        {{:retry, true, 400, 16_000}, {16_000, 400, 30_000}},
        {{:retry, false, 400, 30_000}, {30_000, 400, 30_000}},
        # чекпоинт новее версии — poll_interval_ms, wake не ускоряет
        {{:outdated, false, 400, 8_000}, {1_000, 400, 1_000}},
        {{:outdated, true, 400, 1_000}, {1_000, 400, 1_000}}
      ]

      for {{result, woken?, idle_ms, retry_ms} = row, {delay, next_idle_ms, next_retry_ms}} <-
            table do
        backoff = Map.merge(@intervals, %{idle_ms: idle_ms, retry_ms: retry_ms})
        expected = {delay, %{backoff | idle_ms: next_idle_ms, retry_ms: next_retry_ms}}

        assert Reader.next_tick(backoff, result, woken?) == expected, inspect(row)
      end
    end
  end
end
