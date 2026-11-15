defmodule Core.Es.Aggregate.Load.Request do
  @moduledoc false

  import Core.Version, only: [is_version: 1]

  alias Core.Es.Aggregate.Repo.Pg.Config
  alias Core.Version

  @enforce_keys ~w(op opts streams)a

  defstruct op: nil,
            opts: [],
            streams: [],
            version: nil,
            pairs: nil

  @typedoc false
  @type op :: :get | :get_many | :get_at | :get_many_at

  @typedoc false
  @type stream :: %{
          state: struct(),
          version: Version.expected() | nil,
          upper: pos_integer() | nil,
          captures: [pos_integer()]
        }

  @typedoc false
  @type t :: %__MODULE__{
          op: op(),
          opts: keyword(),
          streams: [stream()],
          version: Version.t() | nil,
          pairs: [{struct(), pos_integer()}] | nil
        }

  @doc false
  @spec get(Config.t(), struct(), Version.expected(), keyword()) :: t()

  def get(cfg, id, version, opts) do
    %__MODULE__{
      op: :get,
      opts: opts,
      streams: [head(struct(cfg.aggregate, id: id), version)]
    }
  end

  @doc false
  @spec get_many(Config.t(), [{struct(), Version.expected()}], keyword()) :: t()

  def get_many(cfg, pairs, opts) do
    %__MODULE__{
      op: :get_many,
      opts: opts,
      streams: for(%{state: state, version: version} <- initial_states!(cfg, pairs), do: head(state, version))
    }
  end

  @doc false
  @spec get_at(Config.t(), struct(), Version.t(), keyword()) :: t()

  def get_at(cfg, id, version, opts) do
    %__MODULE__{
      op: :get_at,
      opts: opts,
      streams: [at(struct(cfg.aggregate, id: id), version)],
      version: version
    }
  end

  @doc false
  @spec get_many_at(Config.t(), [{struct(), Version.t()}], keyword()) :: t()

  def get_many_at(cfg, pairs, opts) do
    parsed = parse_pairs!(cfg, pairs)

    %__MODULE__{
      op: :get_many_at,
      opts: opts,
      streams: many_at(cfg, parsed),
      pairs: parsed
    }
  end

  # ---

  defp head(state, version), do: %{state: state, version: version, upper: nil, captures: []}

  defp at(state, %Version{} = version),
    do: %{state: state, version: version, upper: Version.value(version), captures: []}

  defp parse_pairs!(%Config{id: id_mod}, pairs) do
    Enum.map(pairs, fn
      {%^id_mod{} = id, %Version{} = version} -> {id, Version.value(version)}
    end)
  end

  defp many_at(%Config{} = cfg, parsed) do
    parsed
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.map(fn id ->
      captures =
        parsed
        |> Enum.flat_map(fn
          {^id, version} -> [version]
          {_other, _version} -> []
        end)
        |> Enum.uniq()
        |> Enum.sort()

      %{state: struct(cfg.aggregate, id: id), version: nil, upper: nil, captures: captures}
    end)
  end

  defp initial_states!(%Config{aggregate: aggregate, id: id_mod}, pairs) do
    states =
      Enum.map(pairs, fn {%^id_mod{} = id, version} when is_version(version) ->
        %{state: struct(aggregate, id: id), version: version}
      end)

    ids = Enum.map(states, & &1.state.id)

    case ids -- Enum.uniq(ids) do
      [] -> states
      repeated -> raise ArgumentError, "Es.Aggregate.Repo.Pg: повтор id в get_many: #{inspect(repeated)}"
    end
  end
end
