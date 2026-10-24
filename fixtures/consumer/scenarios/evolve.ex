defmodule ConsumerTest.BadEvolve do
  @moduledoc "Агрегат без clause `evolve/2` для `Frozen` и `Closed` и с опечаткой в суженной нагрузке."

  alias Consumer.Domain.Sales.Account.Cmd
  alias Consumer.Domain.Sales.Account.Event

  use Core.Es.Aggregate,
    event_codec: Consumer.Domain.Sales.Account.Event.Codec

  defstruct id: nil, version: nil, name: nil, status: nil

  @impl true
  def decide(%Cmd.Close{}, %__MODULE__{}), do: {:ok, [Event.Closed.draft()]}

  @impl true
  def evolve(state, %Event.Opened{payload: %Event.Opened.Payload{} = payload}),
    do: %{state | name: payload.name, status: :open}

  # C2b — опечатка в поле нагрузки, суженной `%Payload{}`
  def evolve(state, %Event.Renamed{payload: %Event.Renamed.Payload{} = payload}),
    # expect: unknown key .nmae
    do: %{state | name: payload.nmae}

  def evolve(state, %Event.HolderSet{}), do: state
end

defmodule ConsumerTest.BadEvolve.Repo do
  @moduledoc "Репозиторий агрегата без clauses `evolve/2` для `Frozen` и `Closed`."

  # C1 — нет clause `evolve/2` для `Closed` и `Frozen`: проверка полноты на строке `use`
  # expect: incompatible types given to ConsumerTest.BadEvolve.evolve/2
  # expect: incompatible types given to ConsumerTest.BadEvolve.evolve/2
  use Core.Es.Aggregate.Repo,
    aggregate: ConsumerTest.BadEvolve
end

defmodule ConsumerTest.BadEvolvePayload do
  @moduledoc "Агрегат с опечаткой в поле нагрузки, не суженной паттерном."

  alias Consumer.Domain.Sales.Account.Cmd
  alias Consumer.Domain.Sales.Account.Event

  use Core.Es.Aggregate,
    event_codec: Consumer.Domain.Sales.Account.Event.Codec

  defstruct id: nil, version: nil, name: nil, status: nil

  @impl true
  def decide(%Cmd.Close{}, %__MODULE__{}), do: {:ok, [Event.Closed.draft()]}

  @impl true
  def evolve(state, %Event.Opened{payload: payload}), do: %{state | name: payload.name}
  def evolve(state, %Event.Renamed{payload: payload}), do: %{state | name: payload.nmae}
  def evolve(state, %Event.HolderSet{}), do: state
  def evolve(state, %Event.Frozen{}), do: state
  def evolve(state, %Event.Closed{}), do: state
end

defmodule ConsumerTest.BadEvolvePayload.Repo do
  @moduledoc "Репозиторий агрегата с опечаткой в поле нагрузки."

  # C2a — опечатка в поле нагрузки без паттерна `%Payload{}`: при определении молчит
  # expect: incompatible types given to ConsumerTest.BadEvolvePayload.evolve/2
  use Core.Es.Aggregate.Repo,
    aggregate: ConsumerTest.BadEvolvePayload
end

defmodule ConsumerTest.BadEvolveState do
  @moduledoc "Агрегат с опечаткой в ключе обновления состояния."

  alias Consumer.Domain.Sales.Account.Cmd
  alias Consumer.Domain.Sales.Account.Event

  use Core.Es.Aggregate,
    event_codec: Consumer.Domain.Sales.Account.Event.Codec

  defstruct id: nil, version: nil, name: nil, status: nil

  @impl true
  def decide(%Cmd.Close{}, %__MODULE__{}), do: {:ok, [Event.Closed.draft()]}

  @impl true
  def evolve(state, %Event.Renamed{payload: %Event.Renamed.Payload{} = payload}),
    do: %{state | nmae: payload.name}

  def evolve(state, %Event.Opened{}), do: state
  def evolve(state, %Event.HolderSet{}), do: state
  def evolve(state, %Event.Frozen{}), do: state
  def evolve(state, %Event.Closed{}), do: state
end

defmodule ConsumerTest.BadEvolveState.Repo do
  @moduledoc "Репозиторий агрегата с опечаткой в ключе обновления состояния."

  # C4 — опечатка в ключе `%{state | …}`: при определении молчит
  # expect: incompatible types given to ConsumerTest.BadEvolveState.evolve/2
  use Core.Es.Aggregate.Repo,
    aggregate: ConsumerTest.BadEvolveState
end

defmodule ConsumerTest.LongName.Event do
  @moduledoc "События, у одного из которых имя модуля длиннее, чем помещается в атом имени функции-проверки."

  alias Consumer.Domain.Sales.Account
  alias Consumer.Domain.Sales.Values.UserID
  alias ConsumerTest.LongName.Event.Closed
  alias ConsumerTest.LongName.Event.AlphaBravoCharlieDeltaEchoFoxtrotGolfHotelIndia.JulietKiloLimaMikeNovemberOscarPapaQuebecRomeo.SierraTangoUniformVictorWhiskeyXrayYankeeZulu.AlphaBravoCharlieDeltaEchoFoxtrotGolfHotel.IndiaJulietKiloLimaMikeNovember

  use Core.Es.Event.Family,
    aggregate: ConsumerTest.LongName,
    aggregate_id: Account.ID,
    by: UserID,
    codec: ConsumerTest.LongName.Event.Codec

  @type t :: IndiaJulietKiloLimaMikeNovember.t() | Closed.t()
end

defmodule ConsumerTest.LongName.Event.AlphaBravoCharlieDeltaEchoFoxtrotGolfHotelIndia.JulietKiloLimaMikeNovemberOscarPapaQuebecRomeo.SierraTangoUniformVictorWhiskeyXrayYankeeZulu.AlphaBravoCharlieDeltaEchoFoxtrotGolfHotel.IndiaJulietKiloLimaMikeNovember do
  use Core.Es.Event,
    family: ConsumerTest.LongName.Event,
    payload: nil
end

defmodule ConsumerTest.LongName.Event.Closed do
  use Core.Es.Event,
    family: ConsumerTest.LongName.Event,
    payload: nil
end

defmodule ConsumerTest.LongName.Event.Codec do
  @moduledoc "Кодек с событием длинного имени; в фасад не входит."

  alias ConsumerTest.LongName.Event
  alias ConsumerTest.LongName.Event.AlphaBravoCharlieDeltaEchoFoxtrotGolfHotelIndia.JulietKiloLimaMikeNovemberOscarPapaQuebecRomeo.SierraTangoUniformVictorWhiskeyXrayYankeeZulu.AlphaBravoCharlieDeltaEchoFoxtrotGolfHotel.IndiaJulietKiloLimaMikeNovember

  use Core.Es.Event.Codec,
    family: Event,
    type: "long_name",
    tags: %{IndiaJulietKiloLimaMikeNovember => "long_name.extended", Event.Closed => "long_name.closed"}
end

defmodule ConsumerTest.LongName do
  @moduledoc "Агрегат без clause `evolve/2` для события с длинным именем модуля."

  alias Consumer.Domain.Sales.Account.Cmd
  alias ConsumerTest.LongName.Event

  use Core.Es.Aggregate,
    event_codec: ConsumerTest.LongName.Event.Codec

  defstruct id: nil, version: nil, closed?: false

  @impl true
  def decide(%Cmd.Close{}, %__MODULE__{}), do: {:ok, [Event.Closed.draft()]}

  @impl true
  def evolve(state, %Event.Closed{}), do: %{state | closed?: true}
end

defmodule ConsumerTest.LongName.Repo do
  @moduledoc "Репозиторий агрегата с событием длинного имени."

  # C1l — C1 у события, чьё имя модуля в имени функции-проверки укорачивается до последних сегментов
  # expect: incompatible types given to ConsumerTest.LongName.evolve/2
  use Core.Es.Aggregate.Repo,
    aggregate: ConsumerTest.LongName
end

defmodule ConsumerTest.Evolve do
  @moduledoc "Прямые вызовы `evolve/2`."

  alias Consumer.Domain.Sales.Account
  alias ConsumerTest.BadEvolve
  alias ConsumerTest.BadEvolveState

  # C1d — прямой `evolve/2` с событием без clause
  def c1_direct_missing_clause(%BadEvolve{} = state, %Account.Event.Closed{} = event),
    # expect: incompatible types given to ConsumerTest.BadEvolve.evolve/2
    do: BadEvolve.evolve(state, event)

  # C3d — прямой `evolve/2` с не-событием
  def c3_direct_not_event(%Account{} = state),
    # expect: incompatible types given to Consumer.Domain.Sales.Account.evolve/2
    do: Account.evolve(state, "bad")

  # C4, прямой вызов — `evolve/2` с опечаткой в ключе обновления состояния
  def c4_direct_state_key_typo(%BadEvolveState{} = state, %Account.Event.Renamed{} = event),
    # expect: incompatible types given to ConsumerTest.BadEvolveState.evolve/2
    do: BadEvolveState.evolve(state, event)
end
