defmodule Consumer.Codec.Internal do
  use Core.Codec.Facade,
    prim: Consumer.Codec.Prim.Internal,
    plugins: Consumer.Codec.plugins()
end
