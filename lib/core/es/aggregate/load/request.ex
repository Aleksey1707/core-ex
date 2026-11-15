defmodule Core.Es.Aggregate.Load.Request do
  @moduledoc false

  import Core.Version, only: [is_version: 1]

  alias Core.Result
  alias Core.Version

  @enforce_keys ~w(op opts)a

  defstruct op: nil,
            opts: [],
            source: nil,
            write_snapshots?: false,
            states: nil,
            state: nil,
            pairs: nil,
            version: nil,
            born?: false,
            many?: false,
            decide: nil

  @typedoc false
  @type source :: module()

  @typedoc false
  @type t(decision, reason) :: %__MODULE__{
          op: atom(),
          opts: keyword(),
          source: source(),
          write_snapshots?: boolean(),
          states: [%{state: struct(), version: Version.expected()}] | nil,
          state: struct() | nil,
          pairs: [{struct(), Version.t()}] | nil,
          version: Version.t() | nil,
          born?: boolean(),
          many?: boolean(),
          decide: (struct() -> Result.t(decision, reason)) | nil
        }

  @typedoc false
  @type t :: t(term(), term())

  @doc false
  @spec get(map(), struct(), Version.expected(), keyword(), source() | nil) :: t(term(), term())

  def get(cfg, id, version, opts, source \\ nil) do
    %__MODULE__{
      op: :get,
      opts: opts,
      source: source || cfg.source,
      write_snapshots?: true,
      states: [%{state: struct(cfg.aggregate, id: id), version: version}]
    }
  end

  @doc false
  @spec get_decision(
          map(),
          struct(),
          Version.expected(),
          (struct() -> Result.t(decision, reason)),
          keyword(),
          source() | nil
        ) :: t(decision, reason)
        when decision: var, reason: var

  def get_decision(cfg, id, version, fun, opts, source \\ nil) do
    %__MODULE__{
      op: :get_decision,
      opts: opts,
      source: source || cfg.source,
      write_snapshots?: true,
      states: [%{state: struct(cfg.aggregate, id: id), version: version}],
      born?: true,
      decide: fun
    }
  end

  @doc false
  @spec get_many(map(), [{struct(), Version.expected()}], keyword(), source() | nil) :: t(term(), term())

  def get_many(cfg, pairs, opts, source \\ nil) do
    %__MODULE__{
      op: :get_many,
      opts: opts,
      source: source || cfg.source,
      write_snapshots?: true,
      states: initial_states!(cfg, pairs),
      many?: true
    }
  end

  @doc false
  @spec refresh(map(), struct(), Version.expected(), keyword(), source() | nil) :: t(term(), term())

  def refresh(cfg, state, version, opts, source \\ nil) do
    %__MODULE__{
      op: :refresh,
      opts: opts,
      source: source || cfg.source,
      write_snapshots?: true,
      states: [%{state: state, version: version}]
    }
  end

  @doc false
  @spec get_at(map(), struct(), Version.t(), keyword(), source() | nil) :: t(term(), term())

  def get_at(cfg, id, version, opts, source \\ nil) do
    %__MODULE__{
      op: :get_at,
      opts: opts,
      source: source || cfg.source,
      state: struct(cfg.aggregate, id: id),
      version: version
    }
  end

  @doc false
  @spec get_many_at(map(), [{struct(), Version.t()}], keyword(), source() | nil) :: t(term(), term())

  def get_many_at(cfg, pairs, opts, source \\ nil) do
    %__MODULE__{op: :get_many_at, opts: opts, source: source || cfg.source, pairs: pairs}
  end

  # ---

  defp initial_states!(%{aggregate: aggregate, id: id_mod}, pairs) do
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
