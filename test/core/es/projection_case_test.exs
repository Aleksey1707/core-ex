defmodule Core.Es.ProjectionCaseTest do
  use Core.DataCase, async: true

  alias Core.Error
  alias Core.Es.Personal.Event.KeyDestroyed
  alias Core.Es.ProjectionCase
  alias Core.EsFixture
  alias Core.EsFixture.Account
  alias Core.EventFixture

  require Error

  @fixtures "test/support/fixtures/events"

  # Сломанный каталог фикстур: фикстур счёта нет вовсе, у `fixture.closed` — тоже.
  @broken "test/support/fixtures/events_broken"

  defmodule Silent do
    @moduledoc false

    use Core.Es.Projection,
      name: "projection_case_silent",
      events: [Account.Event.Opened]

    @impl true
    def project(%Account.Event.Opened{}), do: :ok

    @impl true
    def clear, do: :ok
  end

  defmodule Uncleared do
    @moduledoc false

    use Core.Es.Projection,
      name: "projection_case_uncleared",
      events: [Account.Event.Opened]

    @impl true
    def project(%Account.Event.Opened{} = event), do: EsFixture.Projection.project(event)

    @impl true
    def clear, do: {:error, Error.app(code: :clear_failed, ns: :projection_case)}
  end

  defmodule Holders do
    @moduledoc false

    # Строки проекций теста — в таблице сломанной пары: проверка откатывает их вместе с транзакцией.
    import Ecto.Query, only: [from: 2]

    alias Core.Config
    alias Core.EsFixture.PersonalBrokenProjection.Holder

    def put(id, value) do
      codec = Config.codec()
      {1, nil} = Config.dao().insert_all(Holder, [%{aggregate_id: codec.dump(id), holder: codec.dump(value)}])
      :ok
    end

    def delete(subject) do
      id = Config.codec().dump(subject)
      {_count, nil} = Config.dao().delete_all(from(h in Holder, where: h.aggregate_id == ^id))
      :ok
    end
  end

  defmodule Unpersonal do
    @moduledoc false

    # Объявила, что ПДн не держит, а владельца пишет открытым.
    use Core.Es.Projection,
      name: "projection_case_unpersonal",
      events: [Account.Event.HolderSet],
      personal: false

    @impl true
    def project(%Account.Event.HolderSet{payload: %Account.Event.HolderSet.Payload{holder: holder}} = event),
      do: Core.Es.ProjectionCaseTest.Holders.put(event.aggregate_id, holder)

    @impl true
    def clear, do: :ok
  end

  defmodule Contacts do
    @moduledoc false

    # Два субъекта в одном событии: строка контакта — по лицу, строка заметки — по агрегату.
    use Core.Es.Projection,
      name: "projection_case_contacts",
      events: [EventFixture.Event.ContactSet, KeyDestroyed]

    @impl true
    def project(%EventFixture.Event.ContactSet{payload: %EventFixture.Event.ContactSet.Payload{} = payload} = event) do
      :ok = Core.Es.ProjectionCaseTest.Holders.put(payload.person_id, payload.contact)
      Core.Es.ProjectionCaseTest.Holders.put(event.aggregate_id, payload.note)
    end

    def project(%KeyDestroyed{aggregate_id: subject}), do: Core.Es.ProjectionCaseTest.Holders.delete(subject)

    @impl true
    def clear, do: :ok
  end

  describe "check_destroyed/2" do
    test "проекция принимает уничтоженное значение — :ok" do
      assert :ok = ProjectionCase.check_destroyed(EsFixture.Projection, @fixtures)
    end

    test "открытый вариант прошёл, уничтоженный упал — путь и причина" do
      path = Path.join(@fixtures, "account/account.holder_set.json")

      assert {:error, %{destroyed_failed: [{^path, %FunctionClauseError{}}]}} =
               ProjectionCase.check_destroyed(EsFixture.PersonalBrokenProjection, @fixtures)
    end

    test "событий с полями subject: нет — :ok" do
      assert :ok = ProjectionCase.check_destroyed(Silent, @fixtures)
    end
  end

  describe "check_personal/2" do
    test "проекция чистит ПДн по событию уничтожения ключа — :ok" do
      assert :ok = ProjectionCase.check_personal(EsFixture.Projection, @fixtures)
    end

    test "событие уничтожения ключа приходит каждому субъекту фикстуры" do
      assert :ok = ProjectionCase.check_personal(Contacts, @fixtures)
    end

    test "ПДн после события уничтожения ключа — путь, таблица, колонка и поле" do
      path = Path.join(@fixtures, "account/account.holder_set.json")
      left = [{"public.fixture_broken_projection_holders", "holder", :holder}]

      assert {:error, %{personal_left: [{^path, ^left}]}} =
               ProjectionCase.check_personal(EsFixture.PersonalBrokenProjection, @fixtures)

      assert TestRepo.aggregate("fixture_broken_projection_holders", :count) == 0
    end

    test "personal: false — поиск сразу после фикстуры" do
      path = Path.join(@fixtures, "account/account.holder_set.json")

      assert {:error, %{personal_left: [{^path, [{"public.fixture_broken_projection_holders", "holder", :holder}]}]}} =
               ProjectionCase.check_personal(Unpersonal, @fixtures)
    end
  end

  describe "check_clear/2" do
    test "строки read-модели откатываются" do
      assert {:error, %{not_cleared: _not_cleared}} =
               ProjectionCase.check_clear(EsFixture.BrokenProjection, @fixtures)

      assert TestRepo.aggregate("fixture_broken_projection_names", :count) == 0
    end

    test "clear/0 не очистил таблицу — таблица и число строк в ней" do
      assert {:error, %{not_cleared: [{"public.fixture_broken_projection_names", 1}]}} =
               ProjectionCase.check_clear(EsFixture.BrokenProjection, @fixtures)
    end

    test "project/1 не записал ни одной таблицы — провал" do
      assert {:error, %{tables: []}} = ProjectionCase.check_clear(Silent, @fixtures)
    end

    test "отказ clear/0 — ошибка колбэка" do
      assert {:error, %{clear: %Error{code: :clear_failed}}} =
               ProjectionCase.check_clear(Uncleared, @fixtures)
    end
  end

  describe "фикстуры" do
    test "у модуля события нет фикстуры — путь и модуль" do
      # Событие уничтожения ключа case строит сам: его фикстуры не ищет.
      missing = [
        {Path.join(@broken, "account/account.opened.json"), Account.Event.Opened},
        {Path.join(@broken, "account/account.closed.json"), Account.Event.Closed},
        {Path.join(@broken, "account/account.holder_set.json"), Account.Event.HolderSet},
        {Path.join(@broken, "fixture/fixture.closed.json"), EventFixture.Event.Closed}
      ]

      assert {:error, %{missing: ^missing}} = ProjectionCase.check_clear(EsFixture.Projection, @broken)
    end

    @tag :tmp_dir
    test "в фикстуре не текущий тег модуля — путь и тег конверта", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "account/account.opened.json")
      File.mkdir_p!(Path.dirname(path))
      File.cp!(Path.join(@fixtures, "account/account.opened.v1.json"), path)

      assert {:error, %{failed: [{^path, %{type: "account.opened.v1"}}]}} =
               ProjectionCase.check_clear(Silent, tmp_dir)
    end
  end

  describe "опции" do
    test "нет projection: — CompileError" do
      assert_raise CompileError, ~r/нет обязательных опций: \[:projection\]/, fn ->
        use_case([])
      end
    end

    test "projection: не проекция — CompileError" do
      assert_raise CompileError,
                   ~r/projection: модуль .* должен экспортировать __es_projection__\/0/,
                   fn ->
                     use_case(projection: Account)
                   end
    end

    test "fixtures: не непустая строка — CompileError" do
      for fixtures <- ["", :fixtures] do
        assert_raise CompileError, ~r/fixtures: ожидается непустая строка/, fn ->
          use_case(projection: EsFixture.Projection, fixtures: fixtures)
        end
      end
    end

    test "async: не false — CompileError" do
      for async <- [true, :no] do
        assert_raise CompileError, ~r/async: допускается только false/, fn ->
          use_case(projection: EsFixture.Projection, async: async)
        end
      end
    end

    test "отклоняет неизвестную опцию" do
      assert_raise CompileError, ~r/неизвестные опции: \[:codec\]/, fn ->
        use_case(projection: EsFixture.Projection, codec: Core.CodecFixture.Internal)
      end
    end
  end

  # ---

  defp use_case(opts) do
    Code.eval_quoted(
      quote do
        defmodule Core.Es.ProjectionCaseTest.Case do
          use Core.Es.ProjectionCase, unquote(opts)
        end
      end
    )
  end
end
