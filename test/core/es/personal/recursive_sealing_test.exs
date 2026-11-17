defmodule Core.Es.Personal.RecursiveSealingTest do
  @moduledoc """
  Сквозной путь ПДн на любой глубине: маркеры вложенных мест → `$pd` в `es_events` и outbox →
  рекурсивное чтение; число вызовов порта не растёт с числом шагов.
  """

  use Core.DataCase, async: false

  import Ecto.Query

  alias Core.Config
  alias Core.Context
  alias Core.Error
  alias Core.Es
  alias Core.Es.Personal
  alias Core.Es.Personal.Destroyed
  alias Core.Es.Personal.Marker
  alias Core.Es.Store
  alias Core.EsFixture.Itinerary
  alias Core.EsFixture.Itinerary.Event
  alias Core.EsFixture.Itinerary.Event.Planned
  alias Core.EsFixture.UserID
  alias Core.Outbox
  alias Core.Pagination
  alias Core.Telemetry
  alias Core.TestRepo
  alias Core.Version

  @tag_name "itinerary.planned"
  @call [:es, :personal, :call]

  describe "запись" do
    test "вложенные ПДн-места — $pd в es_events и outbox, открытая часть открыта" do
      id = Itinerary.ID.new()
      write!(id, [step("sms", "pending", 1, "Иван", "Код 1111")])

      payload = stored_payload(id)
      assert %{"steps" => [stored]} = payload
      assert %{"channel" => "sms", "status" => "pending", "attempts" => 1} = stored
      assert %{"recipient" => %{"$pd" => recipient}, "content" => %{"$pd" => content}} = stored
      assert is_binary(recipient) and is_binary(content)
      refute inspect(payload) =~ "Иван"
      refute inspect(payload) =~ "Код 1111"

      record = outbox_record(id)
      assert record.name == @tag_name
      assert record.key == Itinerary.ID.value(id)
      assert %{"event_id" => event_id, "name" => @tag_name} = record.headers
      assert event_id == stored_event_id(id)
      assert %{"steps" => [%{"recipient" => %{"$pd" => outboxed}}]} = record.payload["payload"]
      assert is_binary(outboxed)
    end

    test "число вызовов порта на запись не растёт с числом шагов" do
      one = count_calls(fn -> write!(Itinerary.ID.new(), [step("sms", "pending", 1)]) end)
      many = count_calls(fn -> write!(Itinerary.ID.new(), steps(5)) end)

      assert Enum.count(one, &(&1 == :seal)) == Enum.count(many, &(&1 == :seal))
      assert Enum.count(many, &(&1 == :seal)) == 2
    end
  end

  describe "нагрузка-Prim" do
    test "корневое ПДн-место: payload — {\"$pd\": …}, чтение открывает значение" do
      id = Itinerary.ID.new()

      event =
        Event.RecipientChanged.new(
          Itinerary.Recipient.new!("Иван"),
          id,
          Version.new(),
          UserID.new(),
          Es.Event.At.now!()
        )

      assert :ok = Itinerary.Repo.Pg.append([event], Context.new())

      assert %{"$pd" => sealed} = stored_payload(id)
      assert is_binary(sealed)

      assert [%Event.RecipientChanged{payload: recipient}] = Es.Store.Test.events!(Event.Codec, id)
      assert recipient == Itinerary.Recipient.new!("Иван")
    end

    test "тип чтения события допускает %Destroyed{} в нагрузке-Prim" do
      {:ok, types} = Code.Typespec.fetch_types(Event.RecipientChanged)

      {:type, {:t, {:type, _, :map, entries}, []}} = Enum.find(types, &match?({:type, {:t, _, []}}, &1))

      payload =
        for {:type, _, :map_field_exact, [{:atom, _, :payload}, value]} <- entries,
            do: type_to_string(value)

      assert payload == ["Core.EsFixture.Itinerary.Recipient.t() | Core.Es.Personal.Destroyed.t()"]
    end

    test "после destroy_key/3 — нагрузка-Prim читается уничтоженной" do
      id = Itinerary.ID.new()

      event =
        Event.RecipientChanged.new(
          Itinerary.Recipient.new!("Иван"),
          id,
          Version.new(),
          UserID.new(),
          Es.Event.At.now!()
        )

      assert :ok = Itinerary.Repo.Pg.append([event], Context.new())
      assert %{"$pd" => sealed} = stored_payload(id)
      assert is_binary(sealed)

      assert :ok = Personal.destroy_key(id, UserID.new(), Context.new())
      assert [%Event.RecipientChanged{payload: %Destroyed{}}] = Es.Store.Test.events!(Event.Codec, id)
    end
  end

  describe "нагрузка-сущность" do
    test "ПДн-места полей сущности: $pd на месте, открытые поля открыты" do
      id = Itinerary.ID.new()
      step = step("sms", "pending", 1)

      event =
        Event.StepRecorded.new(step, id, Version.new(), UserID.new(), Es.Event.At.now!())

      assert :ok = Itinerary.Repo.Pg.append([event], Context.new())

      assert %{"recipient" => %{"$pd" => recipient}, "content" => %{"$pd" => content}} = stored_payload(id)
      assert is_binary(recipient) and is_binary(content)

      assert [%Event.StepRecorded{payload: read}] = Es.Store.Test.events!(Event.Codec, id)
      assert read == step
    end
  end

  describe "чтение" do
    test "свёртка и page_stream открывают вложенные ПДн-места" do
      id = Itinerary.ID.new()
      steps = steps(3)
      write!(id, steps)

      assert {:ok, %Itinerary{steps: read}} = Itinerary.Repo.Pg.get(id, :current, Context.new())
      assert read == steps

      assert {:ok, %Pagination.Result{items: [%Planned{payload: %{steps: ^steps}}]}} =
               Itinerary.Repo.Pg.page_stream(id, Pagination.Limit.new!(10), Pagination.Offset.new!(0), Context.new())
    end

    test "число вызовов порта на чтение не растёт с числом шагов" do
      one = Itinerary.ID.new()
      many = Itinerary.ID.new()
      write!(one, [step("sms", "pending", 1)])
      write!(many, steps(5))

      read_one = count_calls(fn -> Itinerary.Repo.Pg.get(one, :current, Context.new()) end)
      read_many = count_calls(fn -> Itinerary.Repo.Pg.get(many, :current, Context.new()) end)

      assert Enum.count(read_one, &(&1 == :open)) == Enum.count(read_many, &(&1 == :open))
      assert Enum.count(read_many, &(&1 == :open)) == 1
    end

    test "после destroy_key/3 открытая часть читается, ПДн-места — {\"$pd\": null}" do
      id = Itinerary.ID.new()
      write!(id, [step("sms", "pending", 1), step("email", "sent", 2)])

      assert :ok = Personal.destroy_key(id, UserID.new(), Context.new())

      assert {:ok, [{:ok, wire}]} =
               Store.load_wires([{Event.Codec, raw_wire(id)}], fn _codec, wire -> {:ok, wire} end)

      assert %{"steps" => [first, second]} = wire["payload"]
      assert %{"channel" => "sms", "status" => "pending", "attempts" => 1} = first
      assert %{"recipient" => %{"$pd" => nil}, "content" => %{"$pd" => nil}} = first
      assert %{"channel" => "email", "status" => "sent", "attempts" => 2} = second
    end

    test "после destroy_key/3 — %Destroyed{} на каждом вложенном месте, открытая часть на месте" do
      id = Itinerary.ID.new()
      write!(id, [step("sms", "pending", 1), step("email", "sent", 2)])

      assert :ok = Personal.destroy_key(id, UserID.new(), Context.new())

      assert {:ok, %Itinerary{steps: [first, second]}} = Itinerary.Repo.Pg.get(id, :current, Context.new())

      assert %Itinerary.Step{channel: "sms", status: "pending", attempts: 1} = first
      assert %Itinerary.Step{channel: "email", status: "sent", attempts: 2} = second
      assert %Itinerary.Step{recipient: %Destroyed{}, content: %Destroyed{}} = first
      assert %Itinerary.Step{recipient: %Destroyed{}, content: %Destroyed{}} = second

      assert {:ok, %Pagination.Result{items: [%Planned{payload: %{steps: page_steps}}]}} =
               Itinerary.Repo.Pg.page_stream(id, Pagination.Limit.new!(10), Pagination.Offset.new!(0), Context.new())

      assert [
               %Itinerary.Step{channel: "sms", recipient: %Destroyed{}},
               %Itinerary.Step{channel: "email", recipient: %Destroyed{}}
             ] = page_steps
    end

    test "строка, записанная открытой до разметки вложенных мест, читается" do
      id = Itinerary.ID.new()
      insert_open_steps!(id)

      assert {:ok, %Itinerary{steps: [step]}} = Itinerary.Repo.Pg.get(id, :current, Context.new())
      assert %Itinerary.Step{channel: "sms", status: "pending", attempts: 1} = step
      assert Itinerary.Recipient.value(step.recipient) == "Иван"
      assert Itinerary.Content.value(step.content) == "Код 1111"
    end

    test "маркер не на месте внутри шага — :invalid_value с полем объявления" do
      id = Itinerary.ID.new()
      write!(id, [step("sms", "pending", 1), step("email", "sent", 2)])

      wire =
        raw_wire(id)
        |> Map.update!("payload", fn %{"steps" => [first, second]} ->
          %{"steps" => [Map.put(first, "channel", %{"$pd" => nil}), second]}
        end)

      assert {:error, %Error{kind: :domain, ns: :codec, code: :invalid_value, detail: %{field: :steps}}} =
               Event.Codec.load(Planned, wire, Config.codec())
    end
  end

  describe "план" do
    test "вложенные места и субъект :aggregate_id" do
      assert Event.Codec.__es_personal__() == %{
               Planned => [
                 %{path: [:steps, :each, :recipient], subject: :aggregate_id},
                 %{path: [:steps, :each, :content], subject: :aggregate_id}
               ],
               Event.RecipientChanged => [%{path: [], subject: :aggregate_id}],
               Event.StepRecorded => [
                 %{path: [:recipient], subject: :aggregate_id},
                 %{path: [:content], subject: :aggregate_id}
               ]
             }
    end

    test "dump — маркер на каждом ПДн-месте шага, открытая часть открыта" do
      id = Itinerary.ID.new()
      event = event(id, [step("sms", "pending", 1)])
      subject = Config.codec().dump(id)

      assert %{
               "steps" => [
                 %{
                   "channel" => "sms",
                   "status" => "pending",
                   "attempts" => 1,
                   "recipient" => %Marker{subject: ^subject, value: "Иван"},
                   "content" => %Marker{subject: ^subject, value: "Код 1111"}
                 }
               ]
             } = Config.codec().dump(event)["payload"]
    end
  end

  # ---

  defp steps(count), do: Enum.map(1..count, &step("sms", "pending", &1))

  defp step(channel, status, attempts, recipient \\ "Иван", content \\ "Код 1111") do
    %Itinerary.Step{
      channel: channel,
      status: status,
      attempts: attempts,
      recipient: Itinerary.Recipient.new!(recipient),
      content: Itinerary.Content.new!(content)
    }
  end

  defp event(id, steps) do
    Event.Planned.new(Planned.Payload.new(steps), id, Version.new(), UserID.new(), Es.Event.At.now!())
  end

  defp write!(id, steps) do
    :ok = Itinerary.Repo.Pg.append([event(id, steps)], Context.new())
  end

  defp stored_payload(id) do
    db_id = Config.codec().dump(id)

    TestRepo.one!(
      from(e in "es_events",
        where: e.aggregate_type == "itinerary" and e.aggregate_id == type(^db_id, :binary_id),
        select: e.payload
      )
    )
  end

  defp outbox_record(id) do
    key = Itinerary.ID.value(id)
    TestRepo.one!(from(r in Outbox.Repo.Pg.Schema, where: r.key == ^key))
  end

  defp stored_event_id(id) do
    db_id = Config.codec().dump(id)

    TestRepo.one!(
      from(e in Store.Schema,
        where: e.aggregate_type == "itinerary" and e.aggregate_id == type(^db_id, :binary_id),
        select: type(e.event_id, :binary_id)
      )
    )
  end

  defp raw_wire(id) do
    db_id = Config.codec().dump(id)

    TestRepo.one!(
      from(e in Store.Schema,
        where: e.aggregate_type == "itinerary" and e.aggregate_id == type(^db_id, :binary_id)
      )
    )
    |> Store.Schema.to_wire()
  end

  defp insert_open_steps!(id) do
    row = %{
      aggregate_type: "itinerary",
      aggregate_id: Config.codec().dump(id),
      aggregate_version: 1,
      event_id: Es.Event.ID.value(Es.Event.ID.new()),
      tag: "itinerary.planned",
      payload: %{
        "steps" => [
          %{
            "channel" => "sms",
            "status" => "pending",
            "attempts" => 1,
            "recipient" => "Иван",
            "content" => "Код 1111"
          }
        ]
      },
      by_id: UserID.value(UserID.new()),
      at: DateTime.utc_now(:second)
    }

    {1, nil} = TestRepo.insert_all(Store.Schema, [row])
    :ok
  end

  defp type_to_string(type) do
    {:"::", _, [_name, quoted]} = Code.Typespec.type_to_quoted({:printed, type, []})

    Macro.to_string(quoted)
  end

  defp count_calls(fun) do
    handler = "recursive-sealing-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        Telemetry.event(@call),
        fn _event, _measurements, meta, _config ->
          send(parent, {:personal_call, meta.op})
        end,
        nil
      )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    drain([])
  end

  defp drain(calls) do
    receive do
      {:personal_call, op} -> drain([op | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end
end
