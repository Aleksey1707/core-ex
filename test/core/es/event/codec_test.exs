defmodule Core.Es.Event.CodecTest do
  use ExUnit.Case, async: true

  alias Core.CodecFixture.Internal, as: InCodec
  alias Core.Error
  alias Core.Es
  alias Core.EventFixture
  alias Core.Version

  @envelope_keys ~w(aggregate_id aggregate_version at by event_id payload type)
  @operation_keys ~w(operation_id session_id basis_id)

  describe "dump/2" do
    test "отдаёт конверт события целиком" do
      event = EventFixture.created()

      dumped = EventFixture.Event.Codec.dump(event, InCodec)

      keys =
        dumped
        |> Map.keys()
        |> Enum.sort()

      assert keys == @envelope_keys
      assert dumped["type"] == "fixture.created"
      assert dumped["payload"] == %{"name" => "Приёмка"}
      assert dumped["event_id"] == InCodec.dump(event.id)
      assert dumped["aggregate_id"] == InCodec.dump(event.aggregate_id)
      assert dumped["aggregate_version"] == Version.value(event.aggregate_version)
      assert dumped["at"] == InCodec.dump(event.at)
      assert dumped["by"] == InCodec.dump(event.by)
    end

    test "операция, сеанс и основание — в конверте строками UUID" do
      event = operated(EventFixture.created())

      dumped = EventFixture.Event.Codec.dump(event, InCodec)

      assert Enum.sort(Map.keys(dumped)) == Enum.sort(@envelope_keys ++ @operation_keys)
      assert dumped["operation_id"] == InCodec.dump(event.operation_id)
      assert dumped["session_id"] == InCodec.dump(event.session_id)
      assert dumped["basis_id"] == InCodec.dump(event.basis_id)
    end

    test "пустые операция, сеанс и основание в конверт не пишутся" do
      event = %{operated(EventFixture.created()) | session_id: nil, basis_id: nil}

      dumped = EventFixture.Event.Codec.dump(event, InCodec)

      assert Enum.sort(Map.keys(dumped)) == Enum.sort(["operation_id" | @envelope_keys])
    end

    test "у события без нагрузки payload равен nil" do
      dumped = EventFixture.Event.Codec.dump(EventFixture.closed(), InCodec)

      assert dumped["type"] == "fixture.closed"
      assert dumped["payload"] == nil
    end
  end

  describe "load/3" do
    test "восстанавливает событие по модулю" do
      event = EventFixture.created()

      assert {:ok, ^event} =
               EventFixture.Event.Codec.load(
                 EventFixture.Event.Created,
                 InCodec.dump(event),
                 InCodec
               )
    end

    test "по модулю-семейству выбирает тип события тегом" do
      created = EventFixture.created()
      closed = EventFixture.closed()

      assert {:ok, ^created} = InCodec.load(EventFixture.Event, InCodec.dump(created))
      assert {:ok, ^closed} = InCodec.load(EventFixture.Event, InCodec.dump(closed))
    end

    test "событие старого тега грузится фасадом в модуль текущего, заголовок не меняется" do
      event = EventFixture.created()

      data =
        event
        |> InCodec.dump()
        |> Map.merge(%{"type" => "fixture.created.v2", "payload" => %{"caption" => "Приёмка"}})
        |> json_roundtrip()

      assert {:ok, ^event} = InCodec.load(EventFixture.Event, data)
    end

    test "цепочка апкастов идёт по шагам: v1 → v2 → текущий тег" do
      event = EventFixture.created()

      data =
        event
        |> InCodec.dump()
        |> Map.merge(%{"type" => "fixture.created.v1", "payload" => %{"title" => "Приёмка"}})
        |> json_roundtrip()

      assert {:ok, ^event} = InCodec.load(EventFixture.Event, data)
    end

    test "переименованный тег грузится с нагрузкой как есть" do
      event = EventFixture.created()

      data =
        event
        |> InCodec.dump()
        |> Map.put("type", "fixture.opened")
        |> json_roundtrip()

      assert {:ok, ^event} = InCodec.load(EventFixture.Event, data)
    end

    test "нагрузка неверной формы после апкаста — доменная ошибка загрузки нагрузки" do
      data =
        EventFixture.created()
        |> InCodec.dump()
        |> Map.merge(%{"type" => "fixture.created.v2", "payload" => %{"caption" => 123}})
        |> json_roundtrip()

      assert {:error, %Error{kind: :domain}} = InCodec.load(EventFixture.Event, data)
    end

    test "тег вне tags: и upcasts: — доменная ошибка кодека агрегата" do
      data =
        EventFixture.created()
        |> InCodec.dump()
        |> Map.put("type", "fixture.gone")

      assert {:error, %Error{kind: :domain, code: :unknown_event_type, ns: :es} = error} =
               InCodec.load(EventFixture.Event, data)

      assert error.module == EventFixture.Event.Codec
      assert error.detail == "fixture.gone"
    end

    test "не-map вместо конверта — доменная ошибка формата" do
      assert {:error, %Error{code: :invalid_envelope, ns: :es, detail: %{field: :type}}} =
               InCodec.load(EventFixture.Event, "не конверт")
    end

    test "конверт без тега — доменная ошибка формата" do
      data =
        EventFixture.created()
        |> InCodec.dump()
        |> Map.delete("type")

      assert {:error, %Error{code: :invalid_envelope, ns: :es, detail: %{field: :type}}} =
               InCodec.load(EventFixture.Event, data)
    end

    test "round-trip через JSON: операция, сеанс и основание" do
      event = operated(EventFixture.created())

      assert {:ok, ^event} = load(json_roundtrip(InCodec.dump(event)))
    end

    test "golden-конверт без операции: load → dump побайтно прежний" do
      golden = Jason.decode!(File.read!("test/support/fixtures/events/fixture/fixture.created.json"))

      assert {:ok, event} = load(golden)
      assert Jason.encode!(InCodec.dump(event)) == Jason.encode!(golden)
    end

    test "конверт без ключей операции грузится с пустыми полями" do
      data = json_roundtrip(InCodec.dump(EventFixture.created()))

      assert {:ok, %{operation_id: nil, session_id: nil, basis_id: nil}} = load(data)
    end

    test "неприводимая операция — доменная ошибка приведения" do
      data =
        EventFixture.created()
        |> InCodec.dump()
        |> json_roundtrip()
        |> Map.put("operation_id", "не uuid")

      assert {:error, %Error{kind: :domain}} = load(data)
    end

    test "round-trip через JSON: событие с нагрузкой" do
      event = EventFixture.created()

      assert {:ok, ^event} = load(json_roundtrip(InCodec.dump(event)))
    end

    test "round-trip через JSON: событие без нагрузки — payload вправе отсутствовать" do
      event = EventFixture.closed()

      data =
        event
        |> InCodec.dump()
        |> json_roundtrip()
        |> Map.delete("payload")

      assert {:ok, ^event} = InCodec.load(EventFixture.Event.Closed, data)
    end

    test "отсутствующее обязательное поле — доменная ошибка с именем поля" do
      data =
        EventFixture.created()
        |> InCodec.dump()
        |> json_roundtrip()
        |> Map.delete("aggregate_version")

      assert {:error, %Error{kind: :domain, code: :invalid_envelope, ns: :es} = error} =
               load(data)

      assert error.module == EventFixture.Event.Codec
      assert error.detail == %{field: :aggregate_version}
    end

    test "неприводимое значение поля — доменная ошибка приведения" do
      data =
        EventFixture.created()
        |> InCodec.dump()
        |> json_roundtrip()
        |> Map.put("aggregate_id", "не uuid")

      assert {:error, %Error{kind: :domain}} = load(data)
    end
  end

  describe "to_fields/1 и from_fields/1" do
    test "переносят поля конверта врозь и обратно" do
      event = EventFixture.created()
      dumped = InCodec.dump(event)

      fields = Es.Event.Codec.to_fields(dumped)

      assert fields.id == dumped["event_id"]
      assert fields.by == dumped["by"]
      assert fields.type == "fixture.created"
      assert Es.Event.Codec.from_fields(fields) == dumped
    end

    test "переносят операцию, сеанс и основание; пустые ключи обратно не пишутся" do
      event = %{operated(EventFixture.created()) | basis_id: nil}
      dumped = InCodec.dump(event)

      fields = Es.Event.Codec.to_fields(dumped)

      assert fields.operation_id == dumped["operation_id"]
      assert fields.session_id == dumped["session_id"]
      assert fields.basis_id == nil
      assert Es.Event.Codec.from_fields(fields) == dumped
    end
  end

  describe "опции" do
    test "требует обязательные" do
      assert_raise CompileError, ~r/нет обязательных опций: \[:tags\]/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Es.Event.CodecTest.MissingTags do
              use Core.Es.Event.Codec,
                family: Core.EventFixture.Event,
                type: "codec_test"
            end
          end
        )
      end
    end

    test "без type: — CompileError" do
      assert_raise CompileError, ~r/нет обязательных опций: \[:type\]/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Es.Event.CodecTest.MissingType do
              use Core.Es.Event.Codec,
                family: Core.EventFixture.Event,
                tags: %{Core.EventFixture.Event.Closed => "missing_type.closed"}
            end
          end
        )
      end
    end

    test "type: пустая строка или не строка — CompileError" do
      for type <- ["", :fixture] do
        assert_raise CompileError, ~r/type: ожидается непустая строка/, fn ->
          Code.eval_quoted(
            quote do
              defmodule Core.Es.Event.CodecTest.BadType do
                use Core.Es.Event.Codec,
                  family: Core.EventFixture.Event,
                  type: unquote(type),
                  tags: %{Core.EventFixture.Event.Closed => "bad_type.closed"}
              end
            end
          )
        end
      end
    end

    test "зарезервированный тип \"core.subject\" вне кодека библиотеки — CompileError" do
      assert_raise CompileError, ~r/type: "core.subject" зарезервирован.*Core.Es.Personal.Event.Codec/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Es.Event.CodecTest.ReservedType do
              use Core.Es.Event.Codec,
                family: Core.EventFixture.Event,
                type: "core.subject",
                tags: %{Core.EventFixture.Event.Closed => "core.subject.closed"}
            end
          end
        )
      end
    end

    test "тип агрегата доступен интроспекцией" do
      assert EventFixture.Event.Codec.__es_type__() == "fixture"
    end

    test "интроспекция: модули из tags: и карта upcasts: как объявлена" do
      assert Enum.sort(EventFixture.Event.Codec.__es_mods__()) ==
               Enum.sort([EventFixture.Event.Closed, EventFixture.Event.Created, EventFixture.Event.ContactSet])

      assert EventFixture.Event.Codec.__es_upcasts__() == %{
               "fixture.created.v1" => "fixture.created.v2",
               "fixture.created.v2" => "fixture.created",
               "fixture.opened" => "fixture.created"
             }
    end

    test "источники upcasts: не входят в types/0 и mod_by_tag/1" do
      assert EventFixture.Event.Codec.types() ==
               MapSet.new(["fixture.created", "fixture.closed", "fixture.contact_set"])

      assert EventFixture.Event.Codec.mod_by_tag("fixture.opened") == :error
    end

    test "отклоняет неизвестную опцию" do
      assert_raise CompileError, ~r/неизвестные опции: \[:aggregate_id\]/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Es.Event.CodecTest.UnknownOpt do
              use Core.Es.Event.Codec,
                family: Core.EventFixture.Event,
                type: "codec_test",
                tags: %{Core.EventFixture.Event.Closed => "unknown_opt.closed"},
                aggregate_id: Core.EventFixture.AggID
            end
          end
        )
      end
    end

    test "старая форма event: — CompileError с недостающей и неизвестной опцией" do
      assert_raise CompileError, ~r/нет обязательных опций: \[:family\]; неизвестные опции: \[:event\]/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Es.Event.CodecTest.OldForm do
              use Core.Es.Event.Codec,
                event: Core.EventFixture.Event,
                type: "codec_test",
                tags: %{Core.EventFixture.Event.Closed => "old_form.closed"}
            end
          end
        )
      end
    end

    test "берёт Prim агрегата и автора у семейства" do
      assert EventFixture.Event.Codec.__es_aggregate_id__() == EventFixture.AggID

      assert {:ok, _} =
               InCodec.load(EventFixture.Event.Closed, InCodec.dump(EventFixture.closed()))
    end

    test "codec: семейства — другой кодек — CompileError" do
      message =
        "Es.Event.Codec: семейство Core.EventFixture.Event объявляет codec: Core.EventFixture.Event.Codec, " <>
          "а не Core.Es.Event.CodecTest.ForeignCodec"

      assert_raise CompileError, message, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Es.Event.CodecTest.ForeignCodec do
              use Core.Es.Event.Codec,
                family: Core.EventFixture.Event,
                type: "codec_test",
                tags: %{Core.EventFixture.Event.Closed => "foreign.closed"}
            end
          end
        )
      end
    end

    test "событие из tags: не из семейства кодека — CompileError" do
      message = ~r/tags: событие .*CodecTest\.OtherEvent не из семейства Core\.EventFixture\.Event$/

      assert_raise CompileError, message, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Es.Event.CodecTest.OtherEvent do
              use Core.Es.Event,
                family: Core.EsFixture.Account.Event,
                payload: nil
            end

            defmodule Core.Es.Event.CodecTest.MixedCodec do
              use Core.Es.Event.Codec,
                family: Core.EventFixture.Event,
                type: "codec_test",
                tags: %{
                  Core.EventFixture.Event.Closed => "mixed.closed",
                  Core.Es.Event.CodecTest.OtherEvent => "mixed.other"
                }
            end
          end
        )
      end
    end

    test "тег, объявленный дважды, — CompileError" do
      assert_raise CompileError, ~r/дубликат тега/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Es.Event.CodecTest.DupTag do
              use Core.Es.Event.Codec,
                family: Core.EventFixture.Event,
                type: "codec_test",
                tags: %{
                  Core.EventFixture.Event.Created => "dup.tag",
                  Core.EventFixture.Event.Closed => "dup.tag"
                }
            end
          end
        )
      end
    end

    test "не событие в tags — CompileError" do
      assert_raise CompileError, ~r/не объявлен через `use Core.Es.Event`/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Es.Event.CodecTest.NotAnEvent do
              use Core.Es.Event.Codec,
                family: Core.EventFixture.Event,
                type: "codec_test",
                tags: %{Core.Version => "not_an_event.version"}
            end
          end
        )
      end
    end

    test "кодек событий без нагрузки клоуз не требует" do
      {mod, _} =
        Code.eval_quoted(
          quote do
            unquote(EventFixture.family_ast(Core.Es.Event.CodecTest.PayloadlessCodec))

            defmodule Core.Es.Event.CodecTest.PayloadlessCodec do
              use Core.Es.Event.Codec,
                family: Core.Es.Event.CodecTest.PayloadlessCodec.Family,
                type: "codec_test",
                tags: %{Core.Es.Event.CodecTest.PayloadlessCodec.Done => "payloadless.done"}
            end

            Core.Es.Event.CodecTest.PayloadlessCodec
          end
        )

      assert mod.type(Core.Es.Event.CodecTest.PayloadlessCodec.Done) == "payloadless.done"
    end

    test "модуль нагрузки, общий у двух событий, — кодек собирается" do
      events = [Granted: EventFixture.Name, Revoked: EventFixture.Name]

      {mod, _} =
        Code.eval_quoted(
          quote do
            unquote(EventFixture.family_ast(Core.Es.Event.CodecTest.SharedPayloadCodec, events))

            defmodule Core.Es.Event.CodecTest.SharedPayloadCodec do
              use Core.Es.Event.Codec,
                family: Core.Es.Event.CodecTest.SharedPayloadCodec.Family,
                type: "codec_test",
                tags: %{
                  Core.Es.Event.CodecTest.SharedPayloadCodec.Granted => "shared.granted",
                  Core.Es.Event.CodecTest.SharedPayloadCodec.Revoked => "shared.revoked"
                }
            end

            Core.Es.Event.CodecTest.SharedPayloadCodec
          end
        )

      assert mod.type(Core.Es.Event.CodecTest.SharedPayloadCodec.Granted) == "shared.granted"
      assert mod.type(Core.Es.Event.CodecTest.SharedPayloadCodec.Revoked) == "shared.revoked"
    end

    test "источник upcasts: объявлен в tags: — CompileError" do
      assert_raise CompileError, ~r/upcasts: источник "src\.closed" объявлен в tags:/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Es.Event.CodecTest.UpcastSourceInTags do
              use Core.Es.Event.Codec,
                family: Core.EventFixture.Event,
                type: "codec_test",
                tags: %{
                  Core.EventFixture.Event.Created => "src.created",
                  Core.EventFixture.Event.Closed => "src.closed"
                },
                upcasts: %{"src.closed" => "src.created"}
            end
          end
        )
      end
    end

    test "цель upcasts: не в tags: и не источник — CompileError" do
      assert_raise CompileError, ~r/upcasts: цель "dst\.gone" не объявлена/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Es.Event.CodecTest.UpcastUnknownTarget do
              use Core.Es.Event.Codec,
                family: Core.EventFixture.Event,
                type: "codec_test",
                tags: %{Core.EventFixture.Event.Closed => "dst.closed"},
                upcasts: %{"dst.old" => "dst.gone"}
            end
          end
        )
      end
    end

    test "цикл в upcasts: — CompileError" do
      assert_raise CompileError, ~r/upcasts: цикл "loop\.a" → "loop\.b" → "loop\.a"/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Es.Event.CodecTest.UpcastCycle do
              use Core.Es.Event.Codec,
                family: Core.EventFixture.Event,
                type: "codec_test",
                tags: %{Core.EventFixture.Event.Closed => "loop.closed"},
                upcasts: %{"loop.a" => "loop.b", "loop.b" => "loop.a"}
            end
          end
        )
      end
    end

    test "непустые upcasts: без upcast/2 — CompileError" do
      assert_raise CompileError, ~r/обязан объявить upcast\/2/, fn ->
        Code.eval_quoted(
          quote do
            unquote(EventFixture.family_ast(Core.Es.Event.CodecTest.NoUpcastClauses))

            defmodule Core.Es.Event.CodecTest.NoUpcastClauses do
              use Core.Es.Event.Codec,
                family: Core.Es.Event.CodecTest.NoUpcastClauses.Family,
                type: "codec_test",
                tags: %{Core.Es.Event.CodecTest.NoUpcastClauses.Done => "no_upcast.done"},
                upcasts: %{"no_upcast.old" => "no_upcast.done"}
            end
          end
        )
      end
    end

    test "upcasts: не map непустых строк — CompileError" do
      for upcasts <- [[{"shape.old", "shape.closed"}], %{"shape.old" => :closed}] do
        assert_raise CompileError, ~r/upcasts: ожидается/, fn ->
          Code.eval_quoted(
            quote do
              defmodule Core.Es.Event.CodecTest.BadUpcasts do
                use Core.Es.Event.Codec,
                  family: Core.EventFixture.Event,
                  type: "codec_test",
                  tags: %{Core.EventFixture.Event.Closed => "shape.closed"},
                  upcasts: unquote(Macro.escape(upcasts))
              end
            end
          )
        end
      end
    end
  end

  # ---

  defp load(data), do: InCodec.load(EventFixture.Event.Created, data)

  defp operated(event) do
    %{
      event
      | operation_id: Es.Event.OperationID.new(),
        session_id: Es.Event.SessionID.new!(Ecto.UUID.generate()),
        basis_id: Es.Event.OperationID.new()
    }
  end

  defp json_roundtrip(map) do
    map
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
