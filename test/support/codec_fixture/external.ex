defmodule Core.CodecFixture.External do
  @moduledoc "Entity-фасад (External): Prim.External + плагины."

  use Core.Codec.Facade,
    prim: Core.CodecFixture.Prim.External,
    plugins: Core.CodecFixture.plugins()
end
