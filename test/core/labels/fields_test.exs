defmodule Core.Labels.FieldsTest do
  use ExUnit.Case, async: true

  alias Core.Labels.Fields
  alias Core.LabelsFixture.Event.Updated
  alias Core.LabelsFixture.Name

  test "specs/1 — видимые поля в порядке спеки нагрузки" do
    assert Keyword.keys(Fields.specs(Updated.Payload)) == ~w(name count amount day moment note urgent rank)a
    assert Keyword.fetch!(Fields.specs(Updated.Payload), :name) == {:prim, Name}
  end

  describe "отказ сборки" do
    test "поле без решения — CompileError" do
      assert_raise CompileError, ~r/Missing: поля без подписи или `:hidden`: \[:note\]/, fn ->
        compile_payload(:Missing, labels: [name: "Название"])
      end
    end

    test "подпись поля вне struct'а — CompileError" do
      assert_raise CompileError, ~r/Extra: подписи полей вне struct'а: \[:extra\]/, fn ->
        compile_payload(:Extra, labels: [name: "Название", note: :hidden, extra: "Лишнее"])
      end
    end

    test "повтор поля — CompileError" do
      assert_raise CompileError, ~r/Twice: labels: — ключи повторяются \[:name\]/, fn ->
        compile_payload(:Twice, labels: [name: "Название", name: "Имя", note: :hidden])
      end
    end

    test "пустая подпись — CompileError" do
      assert_raise CompileError, ~r/Blank: labels: поле name — непустая строка, задано " "/, fn ->
        compile_payload(:Blank, labels: [name: " ", note: :hidden])
      end
    end

    test "не строковая подпись — CompileError" do
      assert_raise CompileError, ~r/NotText: labels: поле note — непустая строка, задано :shown/, fn ->
        compile_payload(:NotText, labels: [name: "Название", note: :shown])
      end
    end

    test "labels: не keyword-список — CompileError" do
      assert_raise CompileError, ~r/Empty: labels: — непустой keyword-список, задано \[\]/, fn ->
        compile_payload(:Empty, labels: [])
      end
    end

    test "без labels: — CompileError" do
      assert_raise CompileError, ~r/Labels.Fields: нет обязательных опций: \[:labels\]/, fn ->
        compile_payload(:NoLabels, [])
      end
    end

    test "подпись у свободной map'ы — CompileError" do
      assert_raise CompileError, ~r/Meta: свободная map подписью не выходит — `:hidden`: \[:note\]/, fn ->
        compile_payload(:Meta, [labels: [name: "Название", note: "Данные"]], :map)
      end
    end

    test "use до Core.Es.Event.Payload — CompileError" do
      assert_raise CompileError, ~r/Early — не нагрузка: `use Core.Labels.Fields` подключается после/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Labels.FieldsTest.Early do
              use Core.Labels.Fields, labels: [name: "Название"]

              use Core.Es.Event.Payload, fields: [name: [prim: Core.LabelsFixture.Name]]
            end
          end
        )
      end
    end

    test "struct без Core.Es.Event.Payload — CompileError" do
      assert_raise CompileError, ~r/Plain — не нагрузка: `use Core.Labels.Fields` подключается после/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Labels.FieldsTest.Plain do
              defstruct [:name]

              use Core.Labels.Fields, labels: [name: "Название"]
            end
          end
        )
      end
    end
  end

  test "свободная map под :hidden собирается" do
    {{:module, module, _bytecode, _result}, _binding} =
      compile_payload(:HiddenMap, [labels: [name: "Название", note: :hidden]], :map)

    assert Fields.specs(module) == [name: {:prim, Name}]
  end

  # ---

  defp compile_payload(name, opts, note_type \\ :string) do
    module = Module.concat(__MODULE__, name)

    Code.eval_quoted(
      quote do
        defmodule unquote(module) do
          use Core.Es.Event.Payload,
            fields: [
              name: [prim: Core.LabelsFixture.Name],
              note: [type: unquote(note_type), optional: true]
            ]

          use Core.Labels.Fields, unquote(opts)
        end
      end
    )
  end
end
