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

  defmodule Recipient do
    @moduledoc false

    use Core.Struct, fields: [phone: [prim: Name, personal: true], label: [prim: Name]]
  end

  defmodule Personal do
    @moduledoc false

    use Core.Struct,
      fields: [
        holder: [prim: Name, personal: true],
        phone: [prim: Name, optional: true, personal: true],
        point: [entity: Point, personal: true],
        recipients: [list: [entity: Recipient]],
        names: [list: [prim: Name, personal: true]],
        matrix: [list: [list: [prim: Name, personal: true]]],
        tags: [list: [prim: Name], personal: true],
        roles: [set: [prim: Core.PrimFixture.Personal]],
        by_key: [map: [key: [type: :string, personal: true], value: [prim: Name]]],
        by_id: [map: [key: [type: :string], value: [prim: Name, personal: true]]],
        open: [prim: Name]
      ]
  end

  defmodule Inspectable do
    @moduledoc false

    use Core.Struct,
      fields: [
        holder: [prim: Name],
        secret: [prim: Core.PrimFixture.Personal],
        tags: [list: [prim: Core.PrimFixture.Personal]],
        step: [entity: Recipient],
        sealed: [entity: Point, personal: true]
      ]
  end

  defmodule Command do
    @moduledoc false

    use Core.Es.Cmd

    use Core.Struct,
      fields: [
        name: [prim: Core.PrimFixture.Personal],
        by: [prim: Core.EsFixture.UserID],
        at: [prim: Core.Es.Event.At]
      ]
  end

  defmodule Events do
    @moduledoc false

    use Core.Struct,
      fields: [name: [prim: Name]],
      events: Core.EventFixture.Event
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
