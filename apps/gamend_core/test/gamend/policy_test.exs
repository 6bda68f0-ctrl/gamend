defmodule Gamend.PolicyTest do
  use Gamend.DataCase

  alias Gamend.AccountsFixtures
  alias Gamend.Groups
  alias Gamend.Lobbies
  alias Gamend.Parties
  alias Gamend.Policy
  alias Gamend.Signaling

  describe "can?/3 routes to the context that owns the rule" do
    test "a lobby's host and its pinned WebRTC host both manage it" do
      host = AccountsFixtures.user_fixture()
      server = AccountsFixtures.user_fixture()
      stranger = AccountsFixtures.user_fixture()

      {:ok, lobby} = Lobbies.create_lobby(%{title: "room", host_id: host.id})

      {:ok, lobby} =
        Signaling.configure(lobby, enabled: true, topology: :star, host_id: server.id)

      assert Policy.can?(host, :manage, lobby)
      assert Policy.can?(server, :manage, lobby)
      refute Policy.can?(stranger, :manage, lobby)
      assert Policy.can?(stranger, :view, lobby)
    end

    test "a group's admins manage it" do
      admin = AccountsFixtures.user_fixture()
      member = AccountsFixtures.user_fixture()

      {:ok, group} =
        Groups.create_group(admin.id, %{"title" => "clan-#{System.unique_integer([:positive])}"})

      {:ok, _} = Groups.join_group(member.id, group.id)

      assert Policy.can?(admin, :manage, group)
      refute Policy.can?(member, :manage, group)
    end

    test "a party's leader manages it" do
      leader = AccountsFixtures.user_fixture()
      {:ok, party} = Parties.create_party(leader, %{})

      assert Policy.can?(leader, :manage, party)
      refute Policy.can?(AccountsFixtures.user_fixture(), :manage, party)
    end

    test "an unknown action or resource is false, not a raise" do
      user = AccountsFixtures.user_fixture()
      {:ok, lobby} = Lobbies.create_lobby(%{title: "room", host_id: user.id})

      refute Policy.can?(user, :launch_the_missiles, lobby)
      refute Policy.can?(user, :manage, nil)
      refute Policy.can?(nil, :manage, lobby)
    end
  end
end
