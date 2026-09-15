defmodule Core.Es.FixtureProjectionCaseTest do
  use Core.Es.ProjectionCase,
    projection: Core.EsFixture.Projection,
    async: false
end
