defmodule Consumer.S.BadEvolve do
  @moduledoc "Агрегат без clause `evolve/2` для `Frozen` и `Closed` и с опечаткой в суженной нагрузке."

  alias Consumer.Account.Cmd
  alias Consumer.Account.Event

  use Core.Es.Aggregate,
    event_codec: Consumer.Account.Event.Codec

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
end

defmodule Consumer.S.BadEvolve.Repo do
  @moduledoc "Репозиторий агрегата без clauses `evolve/2` для `Frozen` и `Closed`."

  # C1 — нет clause `evolve/2` для `Closed` и `Frozen`: проверка полноты на строке `use`
  # expect: incompatible types given to Consumer.S.BadEvolve.evolve/2
  # expect: incompatible types given to Consumer.S.BadEvolve.evolve/2
  use Core.Es.Aggregate.Repo,
    aggregate: Consumer.S.BadEvolve,
    id: Consumer.Account.ID
end

defmodule Consumer.S.BadEvolvePayload do
  @moduledoc "Агрегат с опечаткой в поле нагрузки, не суженной паттерном."

  alias Consumer.Account.Cmd
  alias Consumer.Account.Event

  use Core.Es.Aggregate,
    event_codec: Consumer.Account.Event.Codec

  defstruct id: nil, version: nil, name: nil, status: nil

  @impl true
  def decide(%Cmd.Close{}, %__MODULE__{}), do: {:ok, [Event.Closed.draft()]}

  @impl true
  def evolve(state, %Event.Opened{payload: payload}), do: %{state | name: payload.name}
  def evolve(state, %Event.Renamed{payload: payload}), do: %{state | name: payload.nmae}
  def evolve(state, %Event.Frozen{}), do: state
  def evolve(state, %Event.Closed{}), do: state
end

defmodule Consumer.S.BadEvolvePayload.Repo do
  @moduledoc "Репозиторий агрегата с опечаткой в поле нагрузки."

  # C2a — опечатка в поле нагрузки без паттерна `%Payload{}`: при определении молчит
  # expect: incompatible types given to Consumer.S.BadEvolvePayload.evolve/2
  use Core.Es.Aggregate.Repo,
    aggregate: Consumer.S.BadEvolvePayload,
    id: Consumer.Account.ID
end

defmodule Consumer.S.BadEvolveState do
  @moduledoc "Агрегат с опечаткой в ключе обновления состояния."

  alias Consumer.Account.Cmd
  alias Consumer.Account.Event

  use Core.Es.Aggregate,
    event_codec: Consumer.Account.Event.Codec

  defstruct id: nil, version: nil, name: nil, status: nil

  @impl true
  def decide(%Cmd.Close{}, %__MODULE__{}), do: {:ok, [Event.Closed.draft()]}

  @impl true
  def evolve(state, %Event.Renamed{payload: %Event.Renamed.Payload{} = payload}),
    do: %{state | nmae: payload.name}

  def evolve(state, %Event.Opened{}), do: state
  def evolve(state, %Event.Frozen{}), do: state
  def evolve(state, %Event.Closed{}), do: state
end

defmodule Consumer.S.BadEvolveState.Repo do
  @moduledoc "Репозиторий агрегата с опечаткой в ключе обновления состояния."

  # C4 — опечатка в ключе `%{state | …}`: при определении молчит
  # expect: incompatible types given to Consumer.S.BadEvolveState.evolve/2
  use Core.Es.Aggregate.Repo,
    aggregate: Consumer.S.BadEvolveState,
    id: Consumer.Account.ID
end

defmodule Consumer.S.LongName.Event do
  @moduledoc "События, у одного из которых имя модуля длиннее, чем помещается в атом имени функции-проверки."

  alias Consumer.Account
  alias Consumer.UserID

  defmodule QualityControlInspectionAcceptanceCommissioning.ConstructionObjectTechnicalSupervisionRegistry.SubcontractorDocumentationPackageVerification.ExecutiveDocumentationDiscrepancyResolution.RemarkCorrectionDeadlineExtended do
    use Core.Es.Event,
      aggregate_id: Account.ID,
      by: UserID,
      payload: nil
  end

  defmodule Closed do
    use Core.Es.Event,
      aggregate_id: Account.ID,
      by: UserID,
      payload: nil
  end
end

defmodule Consumer.S.LongName.Event.Codec do
  @moduledoc "Кодек с событием длинного имени; в фасад не входит."

  alias Consumer.S.LongName.Event
  alias Consumer.S.LongName.Event.QualityControlInspectionAcceptanceCommissioning.ConstructionObjectTechnicalSupervisionRegistry.SubcontractorDocumentationPackageVerification.ExecutiveDocumentationDiscrepancyResolution.RemarkCorrectionDeadlineExtended

  use Core.Es.Event.Codec,
    event: Event,
    type: "long_name",
    tags: %{RemarkCorrectionDeadlineExtended => "long_name.extended", Event.Closed => "long_name.closed"}
end

defmodule Consumer.S.LongName do
  @moduledoc "Агрегат без clause `evolve/2` для события с длинным именем модуля."

  alias Consumer.Account.Cmd
  alias Consumer.S.LongName.Event

  use Core.Es.Aggregate,
    event_codec: Consumer.S.LongName.Event.Codec

  defstruct id: nil, version: nil, closed?: false

  @impl true
  def decide(%Cmd.Close{}, %__MODULE__{}), do: {:ok, [Event.Closed.draft()]}

  @impl true
  def evolve(state, %Event.Closed{}), do: %{state | closed?: true}
end

defmodule Consumer.S.LongName.Repo do
  @moduledoc "Репозиторий агрегата с событием длинного имени."

  # C1l — C1 у события, чьё имя модуля в имени функции-проверки укорачивается до последних сегментов
  # expect: incompatible types given to Consumer.S.LongName.evolve/2
  use Core.Es.Aggregate.Repo,
    aggregate: Consumer.S.LongName,
    id: Consumer.Account.ID
end

defmodule Consumer.S.Evolve do
  @moduledoc "Прямые вызовы `evolve/2`."

  alias Consumer.Account
  alias Consumer.S.BadEvolve
  alias Consumer.S.BadEvolveState

  # C1d — прямой `evolve/2` с событием без clause
  def c1_direct_missing_clause(%BadEvolve{} = state, %Account.Event.Closed{} = event),
    # expect: incompatible types given to Consumer.S.BadEvolve.evolve/2
    do: BadEvolve.evolve(state, event)

  # C3d — прямой `evolve/2` с не-событием
  def c3_direct_not_event(%Account{} = state),
    # expect: incompatible types given to Consumer.Account.evolve/2
    do: Account.evolve(state, "bad")

  # C4, прямой вызов — `evolve/2` с опечаткой в ключе обновления состояния
  def c4_direct_state_key_typo(%BadEvolveState{} = state, %Account.Event.Renamed{} = event),
    # expect: incompatible types given to Consumer.S.BadEvolveState.evolve/2
    do: BadEvolveState.evolve(state, event)
end
