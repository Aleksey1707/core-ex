defmodule Core.Mq.Reader.Poll do
  @moduledoc false

  alias Core.Result

  @typedoc "Одно чтение reader'а."
  @type fetch :: (-> {:ok, term()} | :empty | {:error, term()})

  @typedoc "Заявка на готовность; `nil` — reader её не поддерживает."
  @type ready_request :: (-> Result.t(reference(), term())) | nil

  @doc """
  Читать, пока не появится сообщение, не истечёт `timeout` или чтение не откажет.

  `fetch` вызывается сразу и после каждой паузы; не-`:empty` исход возвращается как есть.
  `ready_request`, если задан, заменяет паузу заявкой на готовность: после `:empty`
  регистрируется одна заявка, и следующее чтение идёт по `{:mq_ready, ref}`. Ложная заявка
  (`:empty` после неё) регистрирует следующую, пока есть время. Отказ заявки не
  возвращается вызывающему — ожидание продолжается опросом с интервалом.

  По таймауту — `{:error, :nothing_to_commit}`: пустота к этому моменту, а не отказ
  брокера. `timeout == :infinity` ждёт без deadline.
  """
  @spec await(fetch(), ready_request(), timeout(), pos_integer()) ::
          {:ok, term()} | :empty | {:error, term()}

  def await(fetch, ready_request, timeout, interval \\ 10) do
    poll(fetch, ready_request, deadline(timeout), interval)
  end

  @doc """
  Как `await/4`, но исход таймаута — `:empty`: пустота к дедлайну не отказ брокера.

  Общий перевод для читателей `Core.Mq.ReaderReliable`: их `get/2` отдаёт `:empty`.
  """
  @spec await_empty(fetch(), ready_request(), timeout(), pos_integer()) ::
          {:ok, term()} | :empty | {:error, term()}

  def await_empty(fetch, ready_request, timeout, interval \\ 10) do
    case await(fetch, ready_request, timeout, interval) do
      {:error, :nothing_to_commit} -> :empty
      result -> result
    end
  end

  # ---

  defp poll(fetch, ready_request, deadline, interval) do
    case fetch.() do
      :empty -> poll_empty(fetch, ready_request, deadline, interval)
      result -> result
    end
  end

  defp poll_empty(fetch, ready_request, deadline, interval) when is_function(ready_request, 0) do
    if expired?(deadline) do
      nothing_to_commit()
    else
      case ready_request.() do
        {:ok, ref} -> poll_ready(fetch, ready_request, ref, deadline, interval)
        {:error, _reason} -> poll_empty(fetch, nil, deadline, interval)
      end
    end
  end

  defp poll_empty(fetch, nil, deadline, interval) do
    case wait_ms(deadline) do
      :infinity ->
        Process.sleep(interval)
        poll(fetch, nil, deadline, interval)

      0 ->
        nothing_to_commit()

      ms ->
        Process.sleep(min(ms, interval))
        poll(fetch, nil, deadline, interval)
    end
  end

  defp poll_ready(fetch, ready_request, ref, deadline, interval) do
    receive do
      {:mq_ready, ^ref} -> poll(fetch, ready_request, deadline, interval)
    after
      wait_ms(deadline) -> nothing_to_commit()
    end
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms

  defp expired?(:infinity), do: false
  defp expired?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  defp wait_ms(:infinity), do: :infinity
  defp wait_ms(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp nothing_to_commit, do: {:error, :nothing_to_commit}
end
