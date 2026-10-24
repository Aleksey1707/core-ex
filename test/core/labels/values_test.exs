defmodule Core.Labels.ValuesTest do
  use ExUnit.Case, async: true

  alias Core.Labels.Values
  alias Core.LabelsFixture.Status

  test "label/1 — подпись значения" do
    assert Status.label(:active) == "Активна"
    assert Status.label(:archived) == "В архиве"
  end

  test "label/1 вне Enum — FunctionClauseError" do
    assert_raise FunctionClauseError, fn -> Status.label(Enum.random([:unknown])) end
  end

  test "labels/0 — пары в порядке values/0, а не labels:" do
    assert Status.labels() == [draft: "Черновик", active: "Активна", archived: "В архиве"]
    assert Keyword.keys(Status.labels()) == Status.values()
  end

  describe "labels!/2 — разбор по значениям Enum" do
    test "пары в порядке значений Enum, а не labels:" do
      assert Values.labels!(~w(new done)a, done: "Готов", new: "Новый") ==
               [new: "Новый", done: "Готов"]
    end

    test "значение без подписи — CompileError" do
      assert_raise CompileError, "Labels.Values: значения без подписи: [:done]", fn ->
        Values.labels!(~w(new done)a, new: "Новый")
      end
    end

    test "подпись вне Enum — CompileError" do
      assert_raise CompileError, "Labels.Values: подписи значений вне Enum: [:lost]", fn ->
        Values.labels!(~w(new)a, new: "Новый", lost: "Потерян")
      end
    end

    test "не Enum — CompileError" do
      assert_raise CompileError, ~r/^Labels.Values: не Enum: `use Core.Labels.Values` подключается после/, fn ->
        Values.labels!(nil, new: "Новый")
      end
    end
  end

  describe "отказ сборки" do
    test "значение без подписи — CompileError" do
      assert_raise CompileError, ~r/^Labels.Values: значения без подписи: \[:done\]$/, fn ->
        compile_enum(:Missing, labels: [new: "Новый"])
      end
    end

    test "подпись вне Enum — CompileError" do
      assert_raise CompileError, ~r/^Labels.Values: подписи значений вне Enum: \[:lost\]$/, fn ->
        compile_enum(:Extra, labels: [new: "Новый", done: "Готов", lost: "Потерян"])
      end
    end

    test "повтор значения — CompileError" do
      assert_raise CompileError, ~r/^Labels.Values: labels: повторяются \[:new\]$/, fn ->
        compile_enum(:Twice, labels: [new: "Новый", new: "Свежий", done: "Готов"])
      end
    end

    test "пустая подпись — CompileError" do
      assert_raise CompileError, ~r/^Labels.Values: labels: done: ожидается непустая строка, получено ""$/, fn ->
        compile_enum(:Blank, labels: [new: "Новый", done: ""])
      end
    end

    test "не строковая подпись — CompileError" do
      assert_raise CompileError, ~r/^Labels.Values: labels: done: ожидается непустая строка, получено :hidden$/, fn ->
        compile_enum(:NotText, labels: [new: "Новый", done: :hidden])
      end
    end

    test "labels: не keyword-список — CompileError" do
      assert_raise CompileError,
                   ~r/^Labels.Values: labels: ожидается непустой keyword-список, получено \["Новый"\]$/,
                   fn ->
                     compile_enum(:List, labels: ["Новый"])
                   end
    end

    test "без labels: — CompileError" do
      assert_raise CompileError, ~r/Labels.Values: нет обязательных опций: \[:labels\]/, fn ->
        compile_enum(:NoLabels, [])
      end
    end

    test "опечатка в ключе — при раскрытии, с меткой" do
      assert_raise CompileError,
                   ~r/^Labels.Values: нет обязательных опций: \[:labels\]; неизвестные опции: \[:lables\]$/,
                   fn ->
                     {:ok, env} = Macro.Env.define_require(__ENV__, [], Values)
                     Macro.expand(quote(do: Core.Labels.Values.__using__(lables: [new: "Новый"])), env)
                   end
    end

    test "атрибут в опции — «ожидается литерал»" do
      assert_raise CompileError, ~r/^Labels.Values: labels: ожидается литерал, получено @labels$/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Labels.ValuesTest.AttrLabels do
              use Core.Enum, name: "Статус", values: ~w(new done)a

              @labels [new: "Новый", done: "Готов"]
              use Core.Labels.Values, labels: @labels
            end
          end
        )
      end
    end

    test "модуль без use Core.Enum — CompileError" do
      assert_raise CompileError, ~r/^Labels.Values: не Enum: `use Core.Labels.Values` подключается после/, fn ->
        Code.eval_quoted(
          quote do
            defmodule Core.Labels.ValuesTest.NotEnum do
              use Core.Labels.Values, labels: [new: "Новый"]
            end
          end
        )
      end
    end
  end

  # ---

  defp compile_enum(name, opts) do
    module = Module.concat(__MODULE__, name)

    Code.eval_quoted(
      quote do
        defmodule unquote(module) do
          use Core.Enum, name: "Статус", values: ~w(new done)a

          use Core.Labels.Values, unquote(opts)
        end
      end
    )
  end
end
