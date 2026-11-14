defmodule Core.Mq.Reader.PollTest do
  use ExUnit.Case, async: true

  alias Core.Mq.Reader.Poll

  test "немедленное сообщение возвращается как есть" do
    assert {:ok, :message} = Poll.await(fn -> {:ok, :message} end, nil, 100)
  end

  test "отказ чтения возвращается как есть" do
    assert {:error, :broker_down} = Poll.await(fn -> {:error, :broker_down} end, nil, 100)
  end

  test "сообщение до таймаута возвращается без заявки на готовность" do
    {fetch, calls} = scripted_fetch([:empty, :empty, {:ok, :late}])

    assert {:ok, :late} = Poll.await(fetch, nil, 500, 5)
    assert calls.() == 3
  end

  test "пусто до таймаута — :nothing_to_commit" do
    started = System.monotonic_time(:millisecond)

    assert {:error, :nothing_to_commit} = Poll.await(fn -> :empty end, nil, 50, 10)
    assert System.monotonic_time(:millisecond) - started >= 40
  end

  test "await_empty переводит таймаут в :empty, await оставляет :nothing_to_commit" do
    assert :empty = Poll.await_empty(fn -> :empty end, nil, 30, 10)
    assert {:error, :nothing_to_commit} = Poll.await(fn -> :empty end, nil, 30, 10)
  end

  test "опрос по интервалу не превращается в busy-loop" do
    {fetch, calls} = scripted_fetch([:empty])
    started = System.monotonic_time(:millisecond)

    assert {:error, :nothing_to_commit} = Poll.await(fetch, nil, 60, 20)

    assert System.monotonic_time(:millisecond) - started >= 50
    assert calls.() <= 5
  end

  test "заявка на готовность будит ровно одно чтение и возвращает сообщение" do
    {fetch, calls} = scripted_fetch([:empty, {:ok, :message}])

    assert {:ok, :message} = Poll.await(fetch, ready_after(10), 500, 10)
    assert calls.() == 2
  end

  test "ложная заявка на готовность не завершает ожидание" do
    {fetch, calls} = scripted_fetch([:empty, :empty, {:ok, :message}])

    assert {:ok, :message} = Poll.await(fetch, ready_after(5), 500, 10)
    assert calls.() == 3
  end

  test "заявка без сообщения — :nothing_to_commit по deadline" do
    {fetch, calls} = scripted_fetch([:empty])
    started = System.monotonic_time(:millisecond)

    assert {:error, :nothing_to_commit} = Poll.await(fetch, fn -> {:ok, make_ref()} end, 50, 10)

    assert System.monotonic_time(:millisecond) - started >= 40
    assert calls.() == 1
  end

  test "отказ заявки на готовность — переход к опросу по интервалу" do
    {fetch, calls} = scripted_fetch([:empty, {:ok, :message}])

    assert {:ok, :message} = Poll.await(fetch, fn -> {:error, :not_supported} end, 500, 10)
    assert calls.() == 2
  end

  test "timeout :infinity ждёт заявку без deadline" do
    {fetch, _calls} = scripted_fetch([:empty, {:ok, :message}])

    assert {:ok, :message} = Poll.await(fetch, ready_after(10), :infinity)
  end

  test "timeout :infinity ждёт опросом без deadline" do
    {fetch, _calls} = scripted_fetch([:empty, {:ok, :message}])

    assert {:ok, :message} = Poll.await(fetch, nil, :infinity, 5)
  end

  # ---

  defp scripted_fetch(results) do
    key = {__MODULE__, make_ref()}
    Process.put(key, 0)

    fetch = fn ->
      index = Process.get(key)
      Process.put(key, index + 1)
      Enum.at(results, index, List.last(results))
    end

    {fetch, fn -> Process.get(key) end}
  end

  defp ready_after(delay) do
    fn ->
      ref = make_ref()
      Process.send_after(self(), {:mq_ready, ref}, delay)
      {:ok, ref}
    end
  end
end
