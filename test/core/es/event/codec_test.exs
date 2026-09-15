defmodule Core.Es.Event.CodecTest do
  use ExUnit.Case, async: true

  alias Core.CodecFixture.Internal, as: InCodec
  alias Core.Error
  alias Core.Es
  alias Core.EventFixture
  alias Core.Version

  @envelope_keys ~w(aggregate_id aggregate_version at by event_id payload type)

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

    test "нагрузка неверной формы после апкаста — доменная ошибка load_payload" do
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
  end

  describe "опции" do
    test "требует обязательные" do
      assert_raise CompileError, ~r/нет обязательных опций: \[:tags\]/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Es.Event.CodecTest.MissingTags do
              use Core.Es.Event.Codec,
                event: Core.EventFixture.Event,
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
                event: Core.EventFixture.Event,
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
                  event: Core.EventFixture.Event,
                  type: unquote(type),
                  tags: %{Core.EventFixture.Event.Closed => "bad_type.closed"}
              end
            end
          )
        end
      end
    end

    test "тип агрегата доступен интроспекцией" do
      assert EventFixture.Event.Codec.__es_type__() == "fixture"
    end

    test "интроспекция: модули из tags: и карта upcasts: как объявлена" do
      assert Enum.sort(EventFixture.Event.Codec.__es_mods__()) ==
               Enum.sort([EventFixture.Event.Closed, EventFixture.Event.Created])

      assert EventFixture.Event.Codec.__es_upcasts__() == %{
               "fixture.created.v1" => "fixture.created.v2",
               "fixture.created.v2" => "fixture.created",
               "fixture.opened" => "fixture.created"
             }
    end

    test "источники upcasts: не входят в types/0 и mod_by_tag/1" do
      assert EventFixture.Event.Codec.types() == MapSet.new(["fixture.created", "fixture.closed"])
      assert EventFixture.Event.Codec.mod_by_tag("fixture.opened") == :error
    end

    test "отклоняет неизвестную опцию" do
      assert_raise CompileError, ~r/неизвестные опции: \[:aggregate_id\]/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Es.Event.CodecTest.UnknownOpt do
              use Core.Es.Event.Codec,
                event: Core.EventFixture.Event,
                type: "codec_test",
                tags: %{Core.EventFixture.Event.Closed => "unknown_opt.closed"},
                aggregate_id: Core.EventFixture.AggID
            end
          end
        )
      end
    end

    test "выводит Prim агрегата и автора из самих событий" do
      assert {:ok, _} =
               InCodec.load(EventFixture.Event.Closed, InCodec.dump(EventFixture.closed()))
    end

    test "события с разными Prim агрегата — CompileError" do
      assert_raise CompileError, ~r/разными __es_aggregate_id__/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Es.Event.CodecTest.OtherEvent do
              use Core.Es.Event,
                aggregate_id: Core.EventFixture.ActorID,
                by: Core.EventFixture.ActorID,
                payload: nil
            end

            defmodule Core.Es.Event.CodecTest.MixedCodec do
              use Core.Es.Event.Codec,
                event: Core.EventFixture.Event,
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
                event: Core.EventFixture.Event,
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
                event: Core.EventFixture.Event,
                type: "codec_test",
                tags: %{Core.Version => "not_an_event.version"}
            end
          end
        )
      end
    end

    test "событие с нагрузкой без dump_payload/2 — CompileError" do
      assert_raise CompileError, ~r/обязан объявить dump_payload\/2/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Es.Event.CodecTest.NoPayloadClauses do
              use Core.Es.Event.Codec,
                event: Core.EventFixture.Event,
                type: "codec_test",
                tags: %{Core.EventFixture.Event.Created => "no_clauses.created"}
            end
          end
        )
      end
    end

    test "кодек событий без нагрузки клоуз не требует" do
      {mod, _} =
        Code.eval_quoted(
          quote do
            defmodule Core.Es.Event.CodecTest.PayloadlessCodec do
              use Core.Es.Event.Codec,
                event: Core.EventFixture.Event,
                type: "codec_test",
                tags: %{Core.EventFixture.Event.Closed => "payloadless.closed"}
            end

            Core.Es.Event.CodecTest.PayloadlessCodec
          end
        )

      assert mod.type(Core.EventFixture.Event.Closed) == "payloadless.closed"
      refute function_exported?(mod, :dump_payload, 2)
    end

    test "источник upcasts: объявлен в tags: — CompileError" do
      assert_raise CompileError, ~r/upcasts: источник "src\.closed" объявлен в tags:/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Es.Event.CodecTest.UpcastSourceInTags do
              use Core.Es.Event.Codec,
                event: Core.EventFixture.Event,
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
                event: Core.EventFixture.Event,
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
                event: Core.EventFixture.Event,
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
            defmodule Core.Es.Event.CodecTest.NoUpcastClauses do
              use Core.Es.Event.Codec,
                event: Core.EventFixture.Event,
                type: "codec_test",
                tags: %{Core.EventFixture.Event.Closed => "no_upcast.closed"},
                upcasts: %{"no_upcast.old" => "no_upcast.closed"}
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
                  event: Core.EventFixture.Event,
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

  defp json_roundtrip(map) do
    map
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
