defmodule Core.CodecFixture.Internal do
  @moduledoc "Entity-фасад (Internal): Prim.Internal + плагины."

  use Core.Codec.Facade,
    prim: Core.CodecFixture.Prim.Internal,
    plugins: Core.CodecFixture.plugins()
end
