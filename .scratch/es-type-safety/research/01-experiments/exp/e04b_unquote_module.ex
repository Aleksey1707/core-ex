defmodule E04b.Codec do
  def load!(raw) when is_map(raw), do: raw
end

defmodule E04b.Using do
  defmacro __using__(opts) do
    codec = Keyword.fetch!(opts, :codec)

    quote do
      def load(raw), do: unquote(codec).load!(raw)
      def load_literal_bug, do: unquote(codec).load!("not a map")
    end
  end
end

defmodule E04b.Repo do
  use E04b.Using, codec: E04b.Codec
end

defmodule E04b.Caller do
  def via_generated_wrapper, do: E04b.Repo.load("not a map")
  def direct, do: E04b.Codec.load!("not a map")
end
