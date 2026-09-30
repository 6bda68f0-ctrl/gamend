defmodule GamendWeb.ApiSecurityTest do
  # A generated client sends the bearer token only on operations whose
  # OpenAPI entry declares `security`. An operation behind `:api_auth` that
  # declares none is unreachable from the JavaScript SDK: `get_lobby` answered
  # every call from it with 401 while its description said anyone could read
  # it. The router is the truth here, so the document is checked against it.
  use ExUnit.Case, async: true

  @router GamendWeb.Router

  defp operations do
    spec = GamendWeb.ApiSpec.spec()

    for route <- Phoenix.Router.routes(@router),
        String.starts_with?(route.path, "/api/v1/"),
        verb = String.upcase(to_string(route.verb)),
        %{pipe_through: pipes} <- [Phoenix.Router.route_info(@router, verb, route.path, "")],
        %OpenApiSpex.PathItem{} = item <-
          [Map.get(spec.paths, Regex.replace(~r/:(\w+)/, route.path, "{\\1}"))],
        %OpenApiSpex.Operation{} = operation <- [Map.get(item, route.verb)] do
      {operation, pipes}
    end
  end

  defp bearer?(%OpenApiSpex.Operation{security: security}),
    do: Enum.any?(security || [], &Map.has_key?(&1, "authorization"))

  test "every operation behind :api_auth declares the bearer token" do
    missing =
      for {operation, pipes} <- operations(),
          :api_auth in pipes,
          not bearer?(operation),
          do: operation.operationId

    assert missing == [], "declare security: [%{\"authorization\" => []}] on #{inspect(missing)}"
  end

  # Optional authentication is `[%{}, %{"authorization" => []}]`: the empty
  # requirement says the call works anonymously, the second that a signed-in
  # caller should still send its token, because it sees more (a hidden group
  # it belongs to, members' presence, its own quest progress).
  defp optional?(%OpenApiSpex.Operation{security: security}),
    do:
      %{} in (security || []) and
        Enum.any?(security, &Map.has_key?(&1, "authorization"))

  test "every operation behind :api_optional_auth declares the token as optional" do
    wrong =
      for {operation, pipes} <- operations(),
          :api_optional_auth in pipes,
          not optional?(operation),
          do: operation.operationId

    assert wrong == [], "declare security: [%{}, %{\"authorization\" => []}] on #{inspect(wrong)}"
  end

  test "no operation behind :api_auth declares anonymous access" do
    wrong =
      for {operation, pipes} <- operations(),
          :api_auth in pipes,
          %{} in (operation.security || []),
          do: operation.operationId

    assert wrong == [], "these routes require a token: #{inspect(wrong)}"
  end

  test "every security requirement names a scheme the document defines" do
    schemes = Map.keys(GamendWeb.ApiSpec.spec().components.securitySchemes)

    undefined =
      for {operation, _pipes} <- operations(),
          requirement <- operation.security || [],
          name <- Map.keys(requirement),
          name not in schemes,
          uniq: true,
          do: {operation.operationId, name}

    # A generator skips a scheme it cannot find, so `%{"bearer" => []}` sent no
    # token at all from eight operations.
    assert undefined == [], "undefined security schemes: #{inspect(undefined)}"
  end

  test "no operation without authentication declares the bearer token" do
    extra =
      for {operation, pipes} <- operations(),
          :api_auth not in pipes and :api_optional_auth not in pipes,
          bearer?(operation),
          do: operation.operationId

    assert extra == [], "these routes do not authenticate: #{inspect(extra)}"
  end
end
