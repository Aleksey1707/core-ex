defmodule Core.Outbox.TestTest do
  use Core.DataCase, async: true

  import Core.EsAggregateRepoContract, only: [freeze: 0, open: 0, rename: 1, write!: 3]
  import ExUnit.CaptureLog

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.EsFixture.Account
  alias Core.Mq
  alias Core.Outbox

  require Error

  describe "drain/2" do
    test "доставляет запись подписчику топика и отмечает её :published" do
      id = Account.ID.new()
      write!(Account.Repo.Pg, id, [open()])

      :ok = Outbox.Test.drain([subscriber(notify(:a))])

      assert_received {:a, %Account.Event.Opened{aggregate_id: ^id}}
      assert statuses(id) == [:published]
    end

    test "время публикации реальное при остановленных часах" do
      :ok = Core.Clock.Test.freeze(~U[2000-01-01 00:00:00Z])
      id = Account.ID.new()
      write!(Account.Repo.Pg, id, [open()])

      :ok = Outbox.Test.drain([])

      key = Config.codec().dump(id)
      query = from(r in Outbox.Repo.Pg.Schema, where: r.key == ^key, select: [r.updated_at, r.published_at])
      times = TestRepo.one!(query)

      for at <- times, do: assert_in_delta(DateTime.to_unix(at), System.os_time(:second), 5)
    end

    test "filter отсекает сообщение до обработчика, {:skip, _} сдвигает курсор" do
      id = Account.ID.new()
      write!(Account.Repo.Pg, id, [open(), rename("Другое")])
      test = self()

      skip = fn event, _data, _context ->
        send(test, {:skipped, event})
        {:skip, :not_mine}
      end

      subscribers = [
        subscriber(notify(:renamed), name: :renamed, filter: &(header(&1, "name") == "account.renamed")),
        subscriber(skip, name: :skipping)
      ]

      :ok = Outbox.Test.drain(subscribers)

      assert_received {:renamed, %Account.Event.Renamed{}}
      refute_received {:renamed, %Account.Event.Opened{}}
      assert_received {:skipped, %Account.Event.Opened{}}
      assert_received {:skipped, %Account.Event.Renamed{}}
      refute_received {:skipped, _event}
      assert Outbox.Test.dead_letters(self()) == []
    end

    test "ошибка держит подписчика до следующего вызова, соседи по топику и другие топики идут дальше" do
      id = Account.ID.new()
      write!(Account.Repo.Pg, id, [open(), rename("Другое")])
      append_other!("other.first")
      failing = fail_times(1, notify(:flaky))

      subscribers = [
        subscriber(failing, name: :flaky),
        subscriber(notify(:steady), name: :steady),
        other_subscriber(notify(:other))
      ]

      capture_log(fn -> :ok = Outbox.Test.drain(subscribers) end)

      assert_received {:steady, %Account.Event.Opened{}}
      assert_received {:steady, %Account.Event.Renamed{}}
      assert_received {:other, %Mq.Message{}}
      refute_received {:flaky, _event}

      append_other!("other.second")
      :ok = Outbox.Test.drain(subscribers)

      assert_received {:flaky, %Account.Event.Opened{}}
      assert_received {:flaky, %Account.Event.Renamed{}}
      assert_received {:other, %Mq.Message{}}
      refute_received {:steady, _event}
      assert Outbox.Test.dead_letters(self()) == []
    end

    test "исчерпание max_attempts — мёртвое письмо, курсор дальше" do
      id = Account.ID.new()
      write!(Account.Repo.Pg, id, [open(), rename("Другое")])
      failing = fail_times(2, notify(:a))
      subscribers = [subscriber(failing, max_attempts: 2)]

      capture_log(fn ->
        :ok = Outbox.Test.drain(subscribers)
        :ok = Outbox.Test.drain(subscribers)
      end)

      assert_received {:a, %Account.Event.Renamed{}}
      refute_received {:a, %Account.Event.Opened{}}

      assert [%Outbox.Test.DeadLetter{reason: :exhausted, attempts: 2, topic: "accounts"} = dead] =
               Outbox.Test.dead_letters(self())

      assert dead.subscriber == :accounts_subscriber
      assert %Error{code: :boom} = dead.error
      assert header(dead.message, "name") == "account.opened"
    end

    test "{:reject, _} — мёртвое письмо сразу" do
      id = Account.ID.new()
      write!(Account.Repo.Pg, id, [open()])
      reject = fn _event, _data, _context -> {:reject, boom()} end

      capture_log(fn -> :ok = Outbox.Test.drain([subscriber(reject, max_attempts: 5)]) end)

      assert [%Outbox.Test.DeadLetter{reason: :rejected, attempts: 1}] = Outbox.Test.dead_letters(self())
    end

    test "топик без подписчиков публикуется" do
      id = Account.ID.new()
      write!(Account.Repo.Pg, id, [open()])

      :ok = Outbox.Test.drain([])

      assert statuses(id) == [:published]
    end

    test "запись, сделанная обработчиком, уходит следующим вызовом" do
      id = Account.ID.new()
      write!(Account.Repo.Pg, id, [open()])
      test = self()

      react = fn
        %Account.Event.Opened{aggregate_id: opened}, _data, _context ->
          write!(Account.Repo.Pg, opened, [rename("Реакция")])
          :ok

        event, _data, _context ->
          send(test, {:reacted, event})
          :ok
      end

      :ok = Outbox.Test.drain([subscriber(react)])

      refute_received {:reacted, _event}
      assert statuses(id) == [:published, :new]

      :ok = Outbox.Test.drain([subscriber(react)])

      assert_received {:reacted, %Account.Event.Renamed{aggregate_id: ^id}}
      assert statuses(id) == [:published, :published]
    end

    test "subscribe_data — данные on_message" do
      write!(Account.Repo.Pg, Account.ID.new(), [open()])
      test = self()

      on_message = fn _event, data, _context ->
        send(test, {:data, data})
        :ok
      end

      :ok = Outbox.Test.drain([subscriber(on_message, subscribe_data: :tenant)])

      assert_received {:data, :tenant}
    end

    test "неизвестный ключ, подписчик без name или topic и повтор name — ArgumentError" do
      element = "Core.Outbox.Test.drain/2: invalid list element at position 0 in :subscribers option"

      assert_raise ArgumentError, ~r/^#{element}: unknown options \[:filtr\]/, fn ->
        Outbox.Test.drain([subscriber(notify(:a), filtr: & &1)])
      end

      assert_raise ArgumentError, ~r/^#{element}: required :topic option not found/, fn ->
        Outbox.Test.drain([Keyword.delete(subscriber(notify(:a)), :topic)])
      end

      assert_raise ArgumentError, ~r/^#{element}: required :name option not found/, fn ->
        Outbox.Test.drain([Keyword.delete(subscriber(notify(:a)), :name)])
      end

      assert_raise ArgumentError, ~r/^Core.Outbox.Test.drain\/2: опция :name — ожидается различные name/, fn ->
        Outbox.Test.drain([subscriber(notify(:a)), subscriber(notify(:b))])
      end
    end
  end

  describe "опции" do
    test "drain/2 и settle/2: неизвестный ключ и значение не той формы — ArgumentError" do
      assert_raise ArgumentError, ~r/^Core.Outbox.Test.drain\/2: unknown options \[:context\]/, fn ->
        Outbox.Test.drain([], context: Context.new())
      end

      assert_raise ArgumentError, ~r/^Core.Outbox.Test.settle\/2: unknown options \[:timeout_ms\]/, fn ->
        Outbox.Test.settle(self(), timeout_ms: 100)
      end

      assert_raise ArgumentError, ~r/^Core.Outbox.Test.settle\/2: invalid value for :dead_letters option/, fn ->
        Outbox.Test.settle(self(), dead_letters: :ignore)
      end
    end

    @tag :capture_log
    test "реактор: неизвестная опция, нет subscribers:, owner: не pid — ArgumentError при старте" do
      for {opts, expected} <- [
            {[subscribers: [], owner: self(), interval_ms: 10], "unknown options [:interval_ms]"},
            {[owner: self()], "required :subscribers option not found"},
            {[subscribers: [], owner: :test], "invalid value for :owner option: expected pid, got: :test"},
            {[subscribers: [[name: :a]], owner: self()],
             "invalid list element at position 0 in :subscribers option: required :topic option not found"},
            {[subscribers: [subscriber(notify(:a)), subscriber(notify(:b))], owner: self()],
             "опция :name — ожидается различные name подписчиков"}
          ] do
        %ArgumentError{message: message} = assert_raise(ArgumentError, fn -> Outbox.Test.Reactor.start_link(opts) end)
        assert message =~ "Core.Outbox.Test.Reactor.start_link/1: #{expected}"
      end
    end
  end

  describe "реактор и settle/2" do
    test "реактор доставляет запись, сделанную после его старта" do
      start_supervised!({Outbox.Test.Reactor, subscribers: [subscriber(notify(:a))]})
      id = Account.ID.new()

      write!(Account.Repo.Pg, id, [open()])

      assert_receive {:a, %Account.Event.Opened{aggregate_id: ^id}}, 1_000
    end

    test "settle проходит после цепочки из двух реакций" do
      test = self()

      react = fn
        %Account.Event.Opened{aggregate_id: id}, _data, _context ->
          write!(Account.Repo.Pg, id, [rename("Реакция")])
          :ok

        %Account.Event.Renamed{aggregate_id: id}, _data, _context ->
          write!(Account.Repo.Pg, id, [freeze()])
          :ok

        event, _data, _context ->
          send(test, {:reacted, event})
          :ok
      end

      reactor = start_supervised!({Outbox.Test.Reactor, subscribers: [subscriber(react)]})
      id = Account.ID.new()
      write!(Account.Repo.Pg, id, [open()])

      :ok = Outbox.Test.settle(reactor)

      assert_received {:reacted, %Account.Event.Frozen{aggregate_id: ^id}}
      assert statuses(id) == [:published, :published, :published]
    end

    @tag :capture_log
    test "settle по пределу валит тест списком застрявших" do
      failing = fn _event, _data, _context -> {:error, boom()} end
      subscribers = [subscriber(failing, name: :stuck, max_attempts: 1_000_000)]
      reactor = start_supervised!({Outbox.Test.Reactor, subscribers: subscribers})
      write!(Account.Repo.Pg, Account.ID.new(), [open()])
      %{"event_id" => event_id} = TestRepo.one!(from(r in Outbox.Repo.Pg.Schema, select: r.headers))

      error = assert_raise Outbox.Test.NotSettled, fn -> Outbox.Test.settle(reactor, timeout: 200) end

      message = Exception.message(error)
      assert message =~ "topic=accounts"
      assert message =~ "tag=account.opened"
      assert message =~ "event_id=#{event_id}"
      assert message =~ "subscriber=:stuck"
      assert message =~ ~r/attempts=[1-9]/
      assert message =~ "сбой обработчика"
    end

    test "реактор ждёт соединения, которое держит тест, дольше предела очереди по умолчанию" do
      reactor = start_supervised!({Outbox.Test.Reactor, subscribers: [subscriber(notify(:a))]})
      write!(Account.Repo.Pg, Account.ID.new(), [open()])

      # Sandbox отбрасывает ожидающего на опросе очереди раз в `queue_interval` (1 с).
      TestRepo.transaction(fn -> Process.sleep(1_200) end)

      assert :ok = Outbox.Test.settle(reactor)
    end

    test "упавший проход валит settle текстом исключения, лог — одной строкой" do
      crashing = subscriber(notify(:a), context_factory: fn -> raise "сбой контекста" end)
      reactor = start_supervised!({Outbox.Test.Reactor, subscribers: [crashing]})

      log =
        capture_log(fn ->
          write!(Account.Repo.Pg, Account.ID.new(), [open()])

          error = assert_raise Outbox.Test.NotSettled, fn -> Outbox.Test.settle(reactor) end
          assert Exception.message(error) =~ "сбой контекста"
          assert Exception.message(error) =~ "test_test.exs"
        end)

      assert log =~
               ~s{Outbox.Test.Reactor: проход доставки упал, опрос остановлен: error="** (RuntimeError) сбой контекста"}

      refute log =~ "test_test.exs"
    end

    test "мёртвое письмо валит settle, с dead_letters: :allow — проходит" do
      reject = fn _event, _data, _context -> {:reject, boom()} end
      reactor = start_supervised!({Outbox.Test.Reactor, subscribers: [subscriber(reject, name: :rejecting)]})

      capture_log(fn ->
        write!(Account.Repo.Pg, Account.ID.new(), [open()])

        error = assert_raise Outbox.Test.NotSettled, fn -> Outbox.Test.settle(reactor) end
        assert Exception.message(error) =~ "reason=rejected"

        assert :ok = Outbox.Test.settle(reactor, dead_letters: :allow)
      end)

      assert [%Outbox.Test.DeadLetter{reason: :rejected, subscriber: :rejecting}] = Outbox.Test.dead_letters(reactor)
    end
  end

  # ---

  defp subscriber(on_message, opts \\ []) do
    Keyword.merge(
      [
        name: :accounts_subscriber,
        topic: Account.Outbox.topic(),
        from_message: &Es.Event.Message.load(Account.Event, &1),
        on_message: on_message
      ],
      opts
    )
  end

  defp other_subscriber(on_message) do
    [name: :other_subscriber, topic: "other", from_message: &{:ok, &1}, on_message: on_message]
  end

  defp append_other!(name) do
    {:ok, record} =
      Outbox.Record.new(Outbox.Topic.new!("other"), Outbox.Key.new!("other"), Outbox.Name.new!(name), %{})

    :ok = Outbox.Repo.Pg.append([record], Context.new())
  end

  defp notify(tag) do
    test = self()

    fn event, _data, _context ->
      send(test, {tag, event})
      :ok
    end
  end

  defp fail_times(times, on_message) do
    counter = :counters.new(1, [])

    fn event, data, context ->
      :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) <= times, do: {:error, boom()}, else: on_message.(event, data, context)
    end
  end

  defp boom, do: Error.app(code: :boom, ns: :test, message: "сбой обработчика")

  defp header(message, name), do: Mq.Message.find_header(message, Mq.HeaderKey.new!(name))

  defp statuses(id) do
    key = Config.codec().dump(id)

    TestRepo.all(from(r in Outbox.Repo.Pg.Schema, where: r.key == ^key, order_by: r.created_at, select: r.status))
  end
end
