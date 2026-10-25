defmodule Core.Helper.StartOptsTest do
  use ExUnit.Case, async: true

  alias Core.Helper.StartOpts

  @label "Test.Process"

  describe "custom-типы схемы" do
    test "name: имя процесса или nil" do
      for good <- [nil, :poller, {:global, :poller}, {:via, Registry, {:r, 1}}] do
        assert StartOpts.name(good) == {:ok, good}
      end

      for bad <- ["poller", {:via, "Registry", :poller}, {:local, :poller}] do
        assert {:error, "ожидается имя процесса (атом, {:global, term} или {:via, module, term}), получено " <> _} =
                 StartOpts.name(bad)
      end
    end

    test "shutdown: неотрицательное целое, :infinity или :brutal_kill" do
      for good <- [0, 5_000, :infinity, :brutal_kill] do
        assert StartOpts.shutdown(good) == {:ok, good}
      end

      for bad <- [-1, "30s", :kill, nil] do
        assert {:error, "ожидается неотрицательное целое, :infinity или :brutal_kill, получено " <> _} =
                 StartOpts.shutdown(bad)
      end
    end
  end

  describe "фрагменты схемы" do
    @schema [
      name: StartOpts.name_option(),
      shutdown: StartOpts.shutdown_option(5_000)
    ]

    test "ключи проверяются своими custom-типами, shutdown: — с умолчанием" do
      assert NimbleOptions.validate([], @schema) == {:ok, [shutdown: 5_000]}

      for {key, value, expected} <- [
            {:name, "proc", "ожидается имя процесса"},
            {:shutdown, -1, "ожидается неотрицательное целое"}
          ] do
        assert {:error, %NimbleOptions.ValidationError{message: message}} =
                 NimbleOptions.validate([{key, value}], @schema)

        assert message =~ "invalid value for #{inspect(key)} option: #{expected}"
      end
    end

    test "описание: тип, doc по умолчанию и свой" do
      docs = Core.Options.docs(@schema ++ [other: StartOpts.name_option("Имя соседа.")])

      assert docs =~ "`:name` (`t:GenServer.name/0`) - Имя процесса; оно же `:id` в `child_spec/1`."

      assert docs =~
               "`:shutdown` (`t:timeout/0` или `:brutal_kill`) - `shutdown` ребёнка супервизора в " <>
                 "`child_spec/1`. The default value is `5000`."

      assert docs =~ "`:other` (`t:GenServer.name/0`) - Имя соседа."
    end
  end

  describe "child_spec/3" do
    test ":id — name:, без него модуль; :shutdown — опция, без неё default: схемы" do
      schema = [name: StartOpts.name_option(), shutdown: StartOpts.shutdown_option(7_000)]

      assert StartOpts.child_spec(MyProc, [name: :proc], schema) ==
               %{id: :proc, start: {MyProc, :start_link, [[name: :proc]]}, shutdown: 7_000}

      assert %{id: MyProc, shutdown: :brutal_kill} = StartOpts.child_spec(MyProc, [shutdown: :brutal_kill], schema)
      assert %{id: MyProc} = StartOpts.child_spec(MyProc, [name: nil], schema)
    end

    test "схема без shutdown: — :shutdown не задаётся" do
      assert StartOpts.child_spec(MyProc, [], name: StartOpts.name_option()) ==
               %{id: MyProc, start: {MyProc, :start_link, [[]]}}
    end
  end

  test "process!: {модуль, опции} с name: атомом, иначе ошибка с именем опции" do
    assert StartOpts.process!(@label, :writer, {MyWriter, name: MyWriter.Name, prefix: "p"}) ==
             %{module: MyWriter, opts: [name: MyWriter.Name, prefix: "p"], name: MyWriter.Name}

    for spec <- [{MyWriter, []}, {MyWriter, name: "w"}, {nil, name: :w}, {MyWriter, :w}, MyWriter] do
      assert_raise ArgumentError, ~r/:writer — ожидается \{модуль, опции с name: атомом\}/, fn ->
        StartOpts.process!(@label, :writer, spec)
      end
    end
  end

  test "unique!: повторы — ошибка с их списком" do
    assert StartOpts.unique!(@label, :pollers, "имена без повторов", [:a, :b]) == :ok

    assert_raise ArgumentError, ~r/:pollers — ожидается имена без повторов, получено \[:a\]/, fn ->
      StartOpts.unique!(@label, :pollers, "имена без повторов", [:a, :b, :a, :a])
    end
  end
end
