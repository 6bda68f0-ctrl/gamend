defmodule GamendWeb.ResponseContractTest do
  # The contract check only proves anything while it runs: a route lookup that
  # stopped matching would pass every controller test by checking nothing.
  # These feed it a real response, then the same response with drift in it.
  use GamendWeb.ConnCase

  alias Gamend.AccountsFixtures
  alias Gamend.Lobbies
  alias GamendWeb.ResponseContract
  alias GamendWeb.ResponseContract.Violation

  setup %{conn: conn} do
    host = AccountsFixtures.user_fixture()
    {:ok, _lobby} = Lobbies.create_lobby(%{title: "contract-room", host_id: host.id})
    %{sent: get(conn, "/api/v1/lobbies")}
  end

  test "a response matching its schema passes", %{sent: sent} do
    assert %Plug.Conn{} = ResponseContract.check(sent)
  end

  test "a key the schema does not declare fails", %{sent: sent} do
    body =
      update_in(
        Jason.decode!(sent.resp_body),
        ["data", Access.at(0)],
        &Map.put(&1, "surprise", 1)
      )

    assert_raise Violation, ~r/list_lobbies.*undeclared keys: \.data\[0\]\.surprise/, fn ->
      ResponseContract.check(%{sent | resp_body: Jason.encode!(body)})
    end
  end

  test "a value of the wrong type fails", %{sent: sent} do
    body = put_in(Jason.decode!(sent.resp_body), ["meta", "page"], "one")

    assert_raise Violation, ~r/list_lobbies.*meta\/page/, fn ->
      ResponseContract.check(%{sent | resp_body: Jason.encode!(body)})
    end
  end

  test "an undocumented success status fails", %{sent: sent} do
    assert_raise Violation, ~r/status 202 is not documented/, fn ->
      ResponseContract.check(%{sent | status: 202})
    end
  end

  test "an undocumented error status must still be an ErrorResponse", %{sent: sent} do
    assert %Plug.Conn{} =
             ResponseContract.check(%{sent | status: 418, resp_body: ~s({"error":"teapot"})})

    assert_raise Violation, ~r/undeclared keys: \.detail/, fn ->
      ResponseContract.check(%{
        sent
        | status: 418,
          resp_body: ~s({"error":"teapot","detail":"short and stout"})
      })
    end
  end
end
