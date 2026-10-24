defmodule Core.Labels.EventTest do
  use ExUnit.Case, async: true

  alias Core.LabelsFixture.Event.Updated

  describe "отказ сборки" do
    test "без title: — CompileError" do
      assert_raise CompileError, ~r/Labels.Event: нет обязательных опций: \[:title\]/, fn ->
        compile_event(:NoTitle, Updated.Payload, [])
      end
    end

    test "пустое название — CompileError" do
      assert_raise CompileError, ~r/NoText: title: непустая строка, задано " "/, fn ->
        compile_event(:NoText, Updated.Payload, title: " ")
      end
    end

    test "не строковое название — CompileError" do
      assert_raise CompileError, ~r/AtomTitle: title: непустая строка, задано :closed/, fn ->
        compile_event(:AtomTitle, Updated.Payload, title: :closed)
      end
    end

    test "неизвестная опция — CompileError" do
      assert_raise CompileError, ~r/Labels.Event: неизвестные опции: \[:name\]/, fn ->
        compile_event(:Unknown, Updated.Payload, title: "Событие", name: "Имя")
      end
    end

    test "модуль без use Core.Es.Event — CompileError" do
      assert_raise CompileError, ~r/NotEvent: не событие: `use Core.Labels.Event` подключается после/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Labels.EventTest.NotEvent do
              use Core.Labels.Event, title: "Событие"
            end
          end
        )
      end
    end

    test "нагрузка-Prim без payload: — CompileError" do
      assert_raise CompileError, ~r/PrimNoLabel: нагрузка-Prim без подписи `payload:`/, fn ->
        compile_event(:PrimNoLabel, Core.LabelsFixture.Name, title: "Событие")
      end
    end

    test "пустая подпись нагрузки-Prim — CompileError" do
      assert_raise CompileError, ~r/PrimEmpty: payload: непустая строка, задано ""/, fn ->
        compile_event(:PrimEmpty, Core.LabelsFixture.Name, title: "Событие", payload: "")
      end
    end

    test "payload: у нагрузки-struct'а — CompileError" do
      assert_raise CompileError, ~r/StructLabel: `payload:` у нагрузки-struct'а/, fn ->
        compile_event(:StructLabel, Updated.Payload, title: "Событие", payload: "Нагрузка")
      end
    end

    test "нагрузка-struct без Core.Labels.Fields — CompileError" do
      payload = Core.EventFixture.Event.Created.Payload

      assert_raise CompileError, ~r/Unlabelled: нагрузка-struct .*Created.Payload без `use Core.Labels.Fields`/, fn ->
        compile_event(:Unlabelled, payload, title: "Событие")
      end
    end

    test "payload: у события без нагрузки — CompileError" do
      assert_raise CompileError, ~r/NoPayload: `payload:` у события без нагрузки/, fn ->
        compile_event(:NoPayload, nil, title: "Событие", payload: "Нагрузка")
      end
    end
  end

  # ---

  defp compile_event(name, payload, opts) do
    module = Module.concat(__MODULE__, name)

    Code.eval_quoted(
      quote do
        defmodule unquote(module) do
          use Core.Es.Event,
            family: Core.EventFixture.Event,
            payload: unquote(payload)

          use Core.Labels.Event, unquote(opts)
        end
      end
    )
  end
end
