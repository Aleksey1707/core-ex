defmodule Core.UnionFixture do
  @moduledoc """
  Семейства вариантов, объявленные в модуле семейства (`use Core.Union`), и их Codec-плагины.

  Покрывают три формы адреса (тег, тег с дискриминатором, адрес среди полей) и три вида
  варианта: декларативную структуру, Prim и тип с ручным Codec.
  """

  defmodule Name do
    @moduledoc false

    use Core.Prim.String,
      name: "Имя",
      min_len: 1,
      max_len: 50
  end

  defmodule Phone do
    @moduledoc false

    use Core.Prim.String,
      name: "Телефон",
      min_len: 5,
      max_len: 20
  end

  defmodule Email do
    @moduledoc false

    use Core.Prim.String,
      name: "Почта",
      min_len: 3,
      max_len: 50
  end

  defmodule Circle do
    @moduledoc false

    use Core.Struct, fields: [radius: [type: :pos_integer]]
  end

  defmodule Square do
    @moduledoc false

    use Core.Struct, fields: [side: [type: :pos_integer]]
  end

  defmodule Shape do
    @moduledoc false

    use Core.Union,
      variants: [
        {Core.UnionFixture.Circle, "circle"},
        {Core.UnionFixture.Square, "square"}
      ]
  end

  defmodule Rect do
    @moduledoc false

    use Core.Struct,
      fields: [
        kind: [type: :string, default: "rect"],
        width: [type: :pos_integer],
        height: [type: :pos_integer]
      ]
  end

  defmodule Triangle do
    @moduledoc false

    use Core.Struct,
      fields: [
        kind: [type: :string, default: "triangle"],
        sides: [list: [type: :pos_integer]]
      ]
  end

  defmodule Polygon do
    @moduledoc false

    use Core.Union,
      variants: [
        {Core.UnionFixture.Rect, {"polygon", kind: "rect"}},
        {Core.UnionFixture.Triangle, {"polygon", kind: "triangle"}}
      ]
  end

  defmodule Cat do
    @moduledoc false

    use Core.Struct,
      fields: [
        kind: [type: :string, default: "cat"],
        name: [prim: Core.UnionFixture.Name]
      ]
  end

  defmodule Dog do
    @moduledoc false

    use Core.Struct,
      fields: [
        kind: [type: :string, default: "dog"],
        name: [prim: Core.UnionFixture.Name]
      ]
  end

  defmodule Pet do
    @moduledoc false

    use Core.Union,
      variants: [
        {Core.UnionFixture.Cat, [kind: "cat"]},
        {Core.UnionFixture.Dog, [kind: "dog"]}
      ]
  end

  defmodule Recipient do
    @moduledoc false

    use Core.Union,
      variants: [
        {Core.UnionFixture.Phone, "phone"},
        {Core.UnionFixture.Email, "email"}
      ]
  end

  defmodule Star do
    @moduledoc false

    use Core.Struct, fields: [points: [type: :pos_integer]]
  end

  defmodule Blob do
    @moduledoc false

    defstruct [:points]
  end

  defmodule Drawing do
    @moduledoc false

    use Core.Union,
      variants: [
        {Core.UnionFixture.Star, "star"},
        {Core.UnionFixture.Blob, "blob"}
      ]
  end

  defmodule Canvas do
    @moduledoc false

    use Core.Struct,
      fields: [
        shape: [union: Core.UnionFixture.Shape],
        recipient: [union: Core.UnionFixture.Recipient, optional: true, default: nil],
        drawing: [union: Core.UnionFixture.Drawing]
      ]
  end
end

defmodule Core.UnionFixture.ShapePlugin do
  @moduledoc false

  use Core.Codec.Plugin, union: Core.UnionFixture.Shape
end

defmodule Core.UnionFixture.PolygonPlugin do
  @moduledoc false

  use Core.Codec.Plugin, union: Core.UnionFixture.Polygon
end

defmodule Core.UnionFixture.PetPlugin do
  @moduledoc false

  use Core.Codec.Plugin, union: Core.UnionFixture.Pet
end

defmodule Core.UnionFixture.RecipientPlugin do
  @moduledoc false

  use Core.Codec.Plugin, union: Core.UnionFixture.Recipient
end

defmodule Core.UnionFixture.DrawingPlugin do
  @moduledoc false

  alias Core.UnionFixture.Blob

  require Core.Error

  use Core.Codec.Plugin, union: Core.UnionFixture.Drawing

  @impl true
  def dump_variant(%Blob{points: points}, _codec), do: %{"points" => Enum.join(points, ",")}

  @impl true
  def load_variant(Blob, fields, _codec) when is_map(fields) do
    case field(fields, :points) do
      points when is_binary(points) -> {:ok, %Blob{points: String.split(points, ",")}}
      _other -> {:error, Core.Error.domain(Blob, code: :invalid_value, ns: :codec, message: "нет точек")}
    end
  end
end

defmodule Core.UnionFixture.CanvasPlugin do
  @moduledoc false

  use Core.Codec.Plugin, types: [Core.UnionFixture.Canvas]
end

defmodule Core.UnionFixture.Facade do
  @moduledoc false

  use Core.Codec.Facade,
    prim: Core.CodecFixture.Prim.Internal,
    plugins: [
      Core.UnionFixture.ShapePlugin,
      Core.UnionFixture.PolygonPlugin,
      Core.UnionFixture.PetPlugin,
      Core.UnionFixture.RecipientPlugin,
      Core.UnionFixture.DrawingPlugin,
      Core.UnionFixture.CanvasPlugin
    ]
end
