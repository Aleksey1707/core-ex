defmodule E03.Codec do
  def load!(raw) when is_map(raw), do: raw
end

defmodule E03.Repo do
  def get(id) when is_integer(id), do: {:ok, id}
end

defmodule E03 do
  @repo E03.Repo
  @codec E03.Codec

  def direct, do: E03.Repo.get("id")

  def attr, do: @repo.get("id")

  def local_literal_var do
    repo = E03.Repo
    repo.get("id")
  end

  def branch_var(flag) do
    codec = if flag, do: E03.Codec, else: E03.Repo
    codec.load!("raw")
  end

  def param_var(codec), do: codec.load!("raw")

  def param_var_guard(codec) when codec in [E03.Codec], do: codec.load!("raw")

  def via_map(cfg), do: cfg.codec.load!("raw")

  def via_map_literal do
    cfg = %{codec: @codec}
    cfg.codec.load!("raw")
  end

  def apply3, do: apply(E03.Repo, :get, ["id"])

  def apply3_var(mod), do: apply(mod, :get, ["id"])

  def apply3_fun_var(fun), do: apply(E03.Repo, fun, ["id"])

  def attr_result do
    case @repo.get(1) do
      {:ok, _} -> :ok
      :error -> :never
    end
  end

  def param_result(repo) do
    case repo.get(1) do
      {:ok, _} -> :ok
      :error -> :never
    end
  end

  def not_a_module(%{} = m), do: m.get(1)

  def from_app_env do
    repo = Application.fetch_env!(:e03, :repo)
    repo.get("id")
  end

  def module_concat, do: Module.concat([E03, Repo]).get("id")
end
