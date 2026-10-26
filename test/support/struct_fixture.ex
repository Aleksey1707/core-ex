defmodule Core.StructFixture do
  @moduledoc false

  # Структуры живут здесь, а не в тест-файле: `@type t` проверяется по байткоду
  # (`Code.Typespec.fetch_types/1`), а он есть только у модулей, скомпилированных в ebin.

  defmodule Name do
    @moduledoc false

    use Core.Prim.String,
      name: "Название",
      min_len: 1,
      max_len: 50
  end

  defmodule Status do
    @moduledoc """
    Статус фикстуры

    | Значение | Описание |
    |---|---|
    | `:new` | создан |
    | `:done` | завершён |
    """

    use Core.Enum,
      name: "Статус",
      values: ~w(new done)a
  end

  defmodule Point do
    @moduledoc false

    use Core.Struct, fields: [x: [type: :integer]]
  end

  defmodule Shape do
    @moduledoc false
  end

  defmodule Wide do
    @moduledoc false

    use Core.Struct,
      fields: [
        name: [prim: Name],
        note: [prim: Name, optional: true],
        status: [enum: Status],
        point: [entity: Point],
        shape: [union: Shape],
        tags: [list: [prim: Name]],
        matrix: [list: [list: [type: :integer]]],
        roles: [set: [prim: Name]],
        grid: [set: [set: [type: :integer]], optional: true],
        stock: [map: [key: [prim: Name], value: [type: :integer]]],
        by_status: [
          map: [key: [enum: Status], value: [map: [key: [type: :string], value: [type: :integer]]]],
          optional: true
        ],
        count: [type: :non_neg_integer],
        title: [type: :string],
        attrs: [type: :map, optional: true]
      ]
  end

  defmodule Defaults do
    @moduledoc false

    use Core.Struct,
      fields: [
        count: [type: :integer, default: 0],
        note: [prim: Name, optional: true, default: nil]
      ]
  end

  defmodule Nested do
    @moduledoc false

    defmodule Title do
      @moduledoc false

      use Core.Prim.String,
        name: "Заголовок",
        min_len: 1,
        max_len: 50
    end

    use Core.Struct, fields: [title: [prim: Title]]
  end
end
