defmodule Consumer.Codec.External do
  use Core.Codec.Facade,
    prim: Consumer.Codec.Prim.External,
    plugins: Consumer.Codec.plugins()
end
