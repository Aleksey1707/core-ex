defmodule Core.Es.Personal.KeyStoreCase do
  @moduledoc """
  Контрактный набор порта хранилища ключей `Core.Es.Personal.KeyStore` — для своей реализации и
  для встроенной.

      defmodule MyApp.Infra.KeyStoreTest do
        use Core.Es.Personal.KeyStoreCase,
          impl: MyApp.Infra.KeyStore,
          async: true
      end

  Набор зовёт реализацию напрямую, а не через фасад, поверх `ExUnit.Case` с sandbox-владельцем
  базы `Core.Config.dao()` на тест: встроенная реализация пишет в неё, своей sandbox не мешает.

  ## Генерируемые тесты

  1. пачка туда-обратно в порядке пачки, пустая пачка — пустой ответ;
  2. после `destroy/1` значения субъекта — `:destroyed`, соседний субъект читается;
  3. чужой и испорченный шифротекст, изменённый адрес (`event_id`, wire-ключ) — `:unreadable`;
     ключ, созданный в откатанной транзакции, — не `:destroyed`;
  4. `seal/1` уничтоженного субъекта — `:subject_destroyed` на всю пачку;
  5. субъект без ключа: `destroy/1` оставляет след, `seal/1` отказывает;
  6. повтор `destroy/1` — `:ok`;
  7. `index/1` детерминирован и различает область и части.

  Сбой хранилища, откат ключа вместе с транзакцией и байты своей схемы проверяют тесты самой
  реализации.

  ## Opts

  - `impl:` — модуль реализации порта, обязательная
  - `async:` — опция `ExUnit.Case`, необязательная, по умолчанию `true`
  """

  alias Core.Helper

  @label "Es.Personal.KeyStoreCase"
  @required_keys ~w(impl)a
  @optional_keys ~w(async)a
  @expression_keys ~w()a

  @doc "Сгенерировать контрактные тесты реализации порта хранилища ключей."
  defmacro __using__(opts) do
    opts = Helper.Opts.expand!(opts, __CALLER__, @label)
    Helper.Opts.validate!(opts, @required_keys, @optional_keys, @label)
    opts = Helper.Opts.literal!(opts, @expression_keys, @label)
    impl = Helper.Opts.module!(opts, :impl, @label)
    async = async!(opts)

    quote do
      use ExUnit.Case, async: unquote(async)

      alias Core.Error
      alias Core.Es.Personal.Port

      @store unquote(impl)

      setup tags do
        pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Core.Config.dao(), shared: not tags[:async])
        on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
      end

      test "пачка туда-обратно в порядке пачки" do
        [first, second] = subjects(2)
        items = [{first, address("name"), "Иван"}, {second, address("phone"), "+7 900"}, {first, address("note"), ""}]

        assert {:ok, sealed} = @store.seal(items)
        assert length(sealed) == 3

        opened = Enum.zip_with(sealed, items, fn ciphertext, {_subject, aad, _plain} -> {ciphertext, aad} end)

        assert {:ok, [{:ok, "Иван"}, {:ok, "+7 900"}, {:ok, ""}]} = @store.open(opened)
      end

      test "пустая пачка — пустой ответ" do
        assert {:ok, []} = @store.seal([])
        assert {:ok, []} = @store.open([])
        assert {:ok, []} = @store.index([])
      end

      test "после destroy — :destroyed, соседний субъект читается" do
        [gone, kept] = subjects(2)
        aad = address("name")
        {:ok, [sealed_gone, sealed_kept]} = @store.seal([{gone, aad, "Иван"}, {kept, aad, "Пётр"}])

        assert :ok = @store.destroy(gone)
        assert {:ok, [:destroyed, {:ok, "Пётр"}]} = @store.open([{sealed_gone, aad}, {sealed_kept, aad}])
      end

      test "чужой и испорченный шифротекст — :unreadable, а не :destroyed" do
        [subject] = subjects(1)
        aad = address("name")
        {:ok, [sealed]} = @store.seal([{subject, aad, "Иван"}])

        assert {:ok, [:unreadable, :unreadable]} =
                 @store.open([{:crypto.strong_rand_bytes(64), aad}, {tamper(sealed), aad}])
      end

      # Ключ, созданный в откатанной транзакции, хранилище не знает; реализации мимо транзакции
      # ключ-сирота разрешён, и значение открывается. «Уничтожен» — ни в одном случае.
      test "ключ, которого хранилище не знает, — не :destroyed" do
        [subject] = subjects(1)
        aad = address("name")
        dao = Core.Config.dao()

        {:error, sealed} =
          dao.transaction(fn ->
            {:ok, [sealed]} = @store.seal([{subject, aad, "Иван"}])
            dao.rollback(sealed)
          end)

        assert {:ok, [outcome]} = @store.open([{sealed, aad}])
        assert outcome in [:unreadable, {:ok, "Иван"}]
      end

      test "изменённый адрес — :unreadable" do
        [subject] = subjects(1)
        event_id = Ecto.UUID.generate()
        aad = Port.address([event_id, "name"])
        {:ok, [sealed]} = @store.seal([{subject, aad, "Иван"}])

        other_event = Port.address([Ecto.UUID.generate(), "name"])
        other_field = Port.address([event_id, "title"])

        assert {:ok, [{:ok, "Иван"}, :unreadable, :unreadable]} =
                 @store.open([{sealed, aad}, {sealed, other_event}, {sealed, other_field}])
      end

      test "seal уничтоженного субъекта — :subject_destroyed на всю пачку" do
        [gone, kept] = subjects(2)
        {:ok, _sealed} = @store.seal([{gone, address("name"), "Иван"}])
        :ok = @store.destroy(gone)

        assert {:error, %Error{kind: :domain, ns: :key_store, code: :subject_destroyed} = error} =
                 @store.seal([{kept, address("name"), "Пётр"}, {gone, address("name"), "Иван"}])

        assert error.detail == %{subject: gone}
        assert error.message == "Персональные данные субъекта уничтожены"
      end

      test "субъект без ключа: destroy оставляет след, seal отказывает" do
        [subject] = subjects(1)

        assert :ok = @store.destroy(subject)

        assert {:error, %Error{code: :subject_destroyed}} = @store.seal([{subject, address("name"), "Иван"}])
      end

      test "повтор destroy — :ok" do
        [subject] = subjects(1)
        {:ok, _sealed} = @store.seal([{subject, address("name"), "Иван"}])

        assert :ok = @store.destroy(subject)
        assert :ok = @store.destroy(subject)
      end

      test "index детерминирован и различает область и части" do
        items = [
          {"user.email", ["a@b.c"]},
          {"user.email", ["a@b.c"]},
          {"user.phone", ["a@b.c"]},
          {"user.email", ["a@b.cd"]},
          {"user.email", ["a@", "b.c"]},
          {"user.emaila", ["@b.c"]},
          {"user.email", ["a@b.c", ""]}
        ]

        assert {:ok, [same, same | rest] = indexes} = @store.index(items)
        assert Enum.all?(indexes, &is_binary/1)
        assert length(Enum.uniq([same | rest])) == length(rest) + 1
      end

      defp subjects(count), do: for(_ <- 1..count, do: Ecto.UUID.generate())

      defp address(wire), do: Port.address([Ecto.UUID.generate(), wire])

      defp tamper(ciphertext) do
        size = byte_size(ciphertext) - 1
        <<head::binary-size(^size), last>> = ciphertext

        head <> <<Bitwise.bxor(last, 1)>>
      end
    end
  end

  # ---

  defp async!(opts) do
    case Keyword.get(opts, :async, true) do
      async when is_boolean(async) ->
        async

      other ->
        Helper.Opts.reject!("#{@label}: async", "ожидается boolean, получено #{inspect(other)}")
    end
  end
end
