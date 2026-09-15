defmodule Core.Es.EventFixtureCompatTest do
  use Core.Es.EventCompatCase,
    event_codec: Core.EventFixture.Event.Codec,
    async: true
end
