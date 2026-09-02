defmodule Core.Repo.Pg.EsTest do
  use ExUnit.Case, async: true

  alias Core.Error
  require Error

  defmodule FakeId do
    @moduledoc false

    use Core.Prim.UUID,
      name: "Идентификатор",
      version: 7
  end

  defmodule Entity do
    @moduledoc false

    defstruct ~w(id events)a

    @type t :: %__MODULE__{}
  end

  defmodule Event do
    @moduledoc false

    @type t :: term()
  end

  defmodule Errors do
    @moduledoc false

    def domain(module, code, detail) do
      Error.domain(module, code: code, ns: :fake, message: "Ошибка", detail: detail)
    end
  end

  defmodule Event.Repo do
    @moduledoc false

    use Core.Es.Event.Repo,
      event: Core.Repo.Pg.EsTest.Event,
      aggregate_id: Core.Repo.Pg.EsTest.FakeId
  end

  defmodule Outbox do
    @moduledoc false

    def from_events(events) when is_list(events), do: {:ok, events}
  end

  defmodule Behaviour do
    @moduledoc false

    use Core.Repo, only: [:get, :insert, :update, :save, :exists?]
  end

  defmodule ReadOnlyBehaviour do
    @moduledoc false

    use Core.Repo, only: :read
  end

  defmodule Child do
    @moduledoc false

    use Ecto.Schema

    @primary_key false

    schema "es_children" do
      field :role_id, :string, primary_key: true
      field :code, :string, primary_key: true
      field :name, :string
    end

    def to_models(_entity), do: []
  end

  defmodule SoloChild do
    @moduledoc false

    use Ecto.Schema

    @primary_key false

    schema "es_solo_children" do
      field :role_id, :string, primary_key: true
      field :name, :string
    end

    def to_models(_entity), do: []
  end

  defmodule StrictErrors do
    @moduledoc false

    def domain(module, code, detail)
        when code in ~w(not_found version_mismatch incomplete_result no_ids)a do
      Error.domain(module, code: code, ns: :fake, message: "Ошибка", detail: detail)
    end
  end

  defp base_opts do
    [
      behaviour: Behaviour,
      schema: Entity,
      to_entity: quote(do: &Function.identity/1),
      to_model: quote(do: &Function.identity/1),
      entity: Entity,
      errors: Errors,
      event_repo: Event.Repo,
      outbox: Outbox
    ]
  end

  defp compile!(name, overrides) do
    opts =
      base_opts()
      |> Keyword.merge(overrides)
      |> Enum.reject(&match?({_, :__drop__}, &1))

    Code.eval_quoted(
      quote do
        defmodule unquote(Module.concat(__MODULE__, name)) do
          use Core.Repo.Pg.Es, unquote(opts)
        end
      end
    )
  end

  test "требует event_repo и outbox" do
    assert_raise CompileError, ~r/Repo\.Pg\.Es: missing required option\(s\): \[:outbox\]/, fn ->
      compile!(NoOutbox, outbox: :__drop__)
    end
  end

  test "отклоняет неизвестную собственную опцию" do
    assert_raise CompileError, ~r/Repo\.Pg\.Es: unknown option\(s\): \[:childrens\]/, fn ->
      compile!(BadOwnOpt, childrens: [])
    end
  end

  test "требует entity" do
    assert_raise CompileError, ~r/Repo\.Pg\.Es: missing required option\(s\): \[:entity\]/, fn ->
      compile!(NoEntity, entity: :__drop__)
    end
  end

  test "требует behaviour с insert/update/save" do
    assert_raise CompileError, ~r/должен объявлять \[:insert, :update, :save\]/, fn ->
      compile!(ReadOnly, behaviour: ReadOnlyBehaviour)
    end
  end

  test "валидирует описание дочерней таблицы" do
    assert_raise CompileError, ~r/children: fk: ожидается атом/, fn ->
      compile!(BadFk, children: [[schema: Child, fk: "role_id"]])
    end

    assert_raise CompileError,
                 ~r/children: schema: модуль .* должен экспортировать to_models\/1/,
                 fn -> compile!(BadChildSchema, children: [[schema: Entity, fk: :role_id]]) end
  end

  test "отклоняет неизвестную опцию внутри children" do
    assert_raise CompileError, ~r/children: unknown option\(s\): \[:keys\]/, fn ->
      compile!(BadChildOpt, children: [[schema: Child, fk: :role_id, keys: [:code]]])
    end
  end

  test "требует, чтобы fk был колонкой схемы" do
    assert_raise CompileError, ~r/children: fk: колонки :owner_id нет в/, fn ->
      compile!(UnknownFk, children: [[schema: Child, fk: :owner_id]])
    end
  end

  test "без ключа помимо fk требует key:" do
    assert_raise CompileError, ~r/нет первичного ключа помимо :role_id — задайте key:/, fn ->
      compile!(NoChildKey, children: [[schema: SoloChild, fk: :role_id]])
    end
  end

  test "отклоняет key: с несуществующей колонкой" do
    assert_raise CompileError, ~r/children: key: колонок \[:missing\] нет в/, fn ->
      compile!(BadChildKey, children: [[schema: Child, fk: :role_id, key: ~w(missing)a]])
    end
  end

  test "отклоняет key: с fk внутри" do
    assert_raise CompileError, ~r/children: key: :role_id — это fk/, fn ->
      compile!(FkInChildKey, children: [[schema: Child, fk: :role_id, key: ~w(role_id code)a]])
    end
  end

  test "проверяет коды constraint_errors дочерней таблицы" do
    children = [[schema: Child, fk: :role_id, constraint_errors: [some_fkey: :nope]]]

    assert_raise CompileError, ~r/отсутствует clause для :nope в .*StrictErrors/, fn ->
      compile!(BadChildErrorCode, children: children, errors: StrictErrors)
    end
  end

  test "отклоняет нелитеральные opts" do
    assert_raise CompileError, ~r/Repo\.Pg\.Es: ожидается литеральный keyword opts/, fn ->
      Code.eval_quoted(
        quote do
          defmodule Core.Repo.Pg.EsTest.DynamicOpts do
            use Core.Repo.Pg.Es, Keyword.new()
          end
        end
      )
    end
  end
end
