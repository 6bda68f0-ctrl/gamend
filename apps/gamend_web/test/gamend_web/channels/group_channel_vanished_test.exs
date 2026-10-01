defmodule GamendWeb.GroupChannelVanishedTest do
  @moduledoc """
  A group deleted between the membership check and the read of the group
  refuses the join like any other, where a `get_group!` crashed it.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.ChannelTest

  alias Gamend.AccountsFixtures
  alias Gamend.Groups
  alias GamendWeb.Auth.Guardian
  alias GamendWeb.UserSocket

  @endpoint GamendWeb.Endpoint

  setup tags do
    Gamend.DataCase.setup_sandbox(tags)
    :ok
  end

  test "joining a group deleted after the membership check is refused" do
    owner = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()
    {:ok, group} = Groups.create_group(owner.id, %{"title" => "Vanishing", "type" => "public"})

    {:ok, token, _claims} = Guardian.encode_and_sign(owner)
    {:ok, socket} = connect(UserSocket, %{"token" => token})

    fired = :atomics.new(1, [])
    handler = {__MODULE__, System.unique_integer()}

    # The join runs in the channel's process: the first membership read it
    # makes is followed by the delete, before the group itself is read.
    :telemetry.attach(
      handler,
      [:gamend, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if meta[:source] == "group_members" and String.starts_with?(meta[:query], "SELECT") and
             :atomics.compare_exchange(fired, 1, 0, 1) == :ok do
          Gamend.Repo.delete_all(from g in Groups.Group, where: g.id == ^group.id)
        end
      end,
      nil
    )

    try do
      assert {:error, %{reason: "not_a_member_or_invalid"}} =
               subscribe_and_join(socket, "group:#{group.id}", %{})
    after
      :telemetry.detach(handler)
    end

    assert :atomics.get(fired, 1) == 1, "the membership was never read"
  end
end
