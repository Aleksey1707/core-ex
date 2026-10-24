defmodule Core.Labels.CompletenessCaseTest do
  use ExUnit.Case, async: true

  alias Core.EventFixture.ActorID
  alias Core.Labels.CompletenessCase
  alias Core.LabelsBrokenFixture
  alias Core.LabelsBrokenFixture.Event.ByID
  alias Core.LabelsBrokenFixture.Event.ByRef
  alias Core.LabelsBrokenFixture.Event.Marked
  alias Core.LabelsBrokenFixture.Event.Unlabelled
  alias Core.LabelsFixture

  # Полный набор: кодеки событий с подписями и плагин семейства их нагрузки. Сломанный — кодек и
  # плагин `Core.LabelsBrokenFixture`: в нём по пробелу каждого вида.
  @full [LabelsFixture.Event.Codec, LabelsFixture.Event.ManualFamily.Codec, LabelsFixture.Shape.Codec]
  @broken [LabelsBrokenFixture.Event.Codec, LabelsBrokenFixture.Mark.Codec]

  describe "check_found/1" do
    test "события кодеков найдены — :ok" do
      assert :ok = CompletenessCase.check_found(@full)
    end

    test "среди модулей нет кодека событий — пустой обход, провал" do
      assert {:error, :empty} = CompletenessCase.check_found([LabelsFixture.Status, LabelsFixture.Shape.Codec])
      assert {:error, :empty} = CompletenessCase.check_found([])
    end
  end

  describe "check_titles/1" do
    test "у каждого события название — :ok" do
      assert :ok = CompletenessCase.check_titles(@full)
    end

    test "событие без названия — модуль события" do
      assert {:error, %{untitled: [Unlabelled]}} = CompletenessCase.check_titles(@broken)
    end
  end

  describe "check_fields/1" do
    test "у каждого struct'а нагрузки решение по полям — :ok" do
      assert :ok = CompletenessCase.check_fields(@full)
    end

    test "нагрузка и вариант семейства без решения — владелец, поле и struct" do
      assert {:error, %{undecided: undecided}} = CompletenessCase.check_fields(@broken)

      assert undecided == [
               {Marked.Payload, :mark, LabelsBrokenFixture.Mark.Bare},
               {Unlabelled, :payload, Unlabelled.Payload}
             ]
    end
  end

  describe "check_values/1" do
    test "у каждого Enum подписи — :ok" do
      assert :ok = CompletenessCase.check_values(@full)
    end

    test "Enum без подписей — каждое поле, где он достижим, и сам список" do
      assert {:error, %{unlabelled: unlabelled}} = CompletenessCase.check_values(@broken)

      assert unlabelled == [
               {Marked.Payload, :kind, LabelsBrokenFixture.Kind},
               {Marked.Payload, :kinds, LabelsBrokenFixture.Kind}
             ]
    end
  end

  describe "check_ids/1" do
    test "у каждого id вид — свой, базы композита или текст — :ok" do
      assert :ok = CompletenessCase.check_ids(@full)
    end

    test "id без вида — владелец, поле и Prim" do
      assert {:error, %{unkinded: [{Marked.Payload, :ref, LabelsFixture.BareID}]}} =
               CompletenessCase.check_ids(@broken)
    end
  end

  describe "check_authors/1" do
    test "автор каждого события — учётная запись с резолвером — :ok" do
      assert :ok = CompletenessCase.check_authors(@full)
    end

    test "автор без вида id — событие, :by и Prim автора" do
      assert {:error, %{unnamed: unnamed}} = CompletenessCase.check_authors(@broken)

      assert unnamed == [{Marked, :by, ActorID}, {Unlabelled, :by, ActorID}]
    end

    test "автор — ссылка на запись (`kind: :ref`), а не учётная запись — провал" do
      assert {:error, %{unnamed: [{ByRef, :by, LabelsFixture.ItemID}]}} =
               CompletenessCase.check_authors([ByRef.Codec])
    end

    # `kind: :user` без резолвера не собирается (`Core.Labels.ID`): автор без резолвера — `kind: :id`.
    test "автор без резолвера (`kind: :id`) — провал" do
      assert {:error, %{unnamed: [{ByID, :by, LabelsFixture.SnapshotID}]}} =
               CompletenessCase.check_authors([ByID.Codec])
    end
  end

  describe "check_variants/1" do
    test "спека варианта совпадает со спекой плагина, дискриминатор скрыт — :ok" do
      assert :ok = CompletenessCase.check_variants(@full)
    end

    test "расходящаяся спека — вариант, поле и обе спеки; видимый дискриминатор не сверяется" do
      assert {:error, %{diverged: diverged}} = CompletenessCase.check_variants(@broken)

      assert diverged == [{LabelsBrokenFixture.Mark.Skewed, :size, {{:type, :integer}, {:type, :pos_integer}}}]
    end

    test "семейство без плагина среди модулей — владелец, поле и семейство" do
      assert {:error, %{unknown_family: [{Marked.Payload, :loose, LabelsBrokenFixture.Loose}]}} =
               CompletenessCase.check_variants(@broken)
    end
  end

  describe "modules!/1" do
    test "модули приложения — с кодеками событий" do
      modules = CompletenessCase.modules!(:core)

      assert LabelsFixture.Event.Codec in modules
      assert LabelsBrokenFixture.Event.Codec in modules
    end

    test "незагруженное приложение — ArgumentError" do
      assert_raise ArgumentError, ~r/не загружено/, fn -> CompletenessCase.modules!(:no_such_app) end
    end
  end

  describe "опции" do
    test "без otp_app: — CompileError" do
      assert_raise CompileError, ~r/^Labels\.CompletenessCase: нет обязательных опций: \[:otp_app\]$/, fn ->
        use_case(async: true)
      end
    end

    test "otp_app: не атом — CompileError" do
      assert_raise CompileError, ~r/^Labels\.CompletenessCase: otp_app: ожидается атом, получено "core"$/, fn ->
        use_case(otp_app: "core")
      end
    end

    test "async: не boolean — CompileError" do
      assert_raise CompileError, ~r/^Labels\.CompletenessCase: async: ожидается boolean, получено :yes$/, fn ->
        use_case(otp_app: :core, async: :yes)
      end
    end

    test "отклоняет неизвестную опцию" do
      assert_raise CompileError, ~r/^Labels\.CompletenessCase: неизвестные опции: \[:app\]$/, fn ->
        use_case(otp_app: :core, app: :core)
      end
    end

    test "опечатка в ключе — при раскрытии, с меткой" do
      assert_raise CompileError, ~r/^Labels\.CompletenessCase: неизвестные опции: \[:asnyc\]$/, fn ->
        expand(otp_app: :core, asnyc: true)
      end
    end

    test "атрибут в опции — «ожидается литерал»" do
      assert_raise CompileError, ~r/^Labels\.CompletenessCase: otp_app: ожидается литерал, получено @app$/, fn ->
        use_case(otp_app: quote(do: @app))
      end
    end
  end

  # ---

  defp expand(opts) do
    {:ok, env} = Macro.Env.define_require(__ENV__, [], CompletenessCase)
    Macro.expand(quote(do: Core.Labels.CompletenessCase.__using__(unquote(opts))), env)
  end

  defp use_case(opts) do
    Code.eval_quoted(
      quote do
        defmodule Core.Labels.CompletenessCaseTest.Completeness do
          use Core.Labels.CompletenessCase, unquote(opts)
        end
      end
    )
  end
end
