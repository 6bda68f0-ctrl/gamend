defmodule Gamend.Accounts.OAuthProfileTest do
  use Gamend.DataCase, async: true

  alias Gamend.Accounts

  describe "OAuth profile_url handling" do
    test "saves google profile_url on create" do
      attrs = %{
        google_id: "g_123",
        email: "guser@example.com",
        profile_url: "https://example.com/g.png"
      }

      assert {:ok, user} = Accounts.find_or_create_from_google(attrs)
      assert user.google_id == "g_123"
      assert user.profile_url == "https://example.com/g.png"
    end

    test "saves facebook profile_url on create" do
      attrs = %{
        facebook_id: "f_123",
        email: "fuser@example.com",
        profile_url: "https://example.com/f.png"
      }

      assert {:ok, user} = Accounts.find_or_create_from_facebook(attrs)
      assert user.facebook_id == "f_123"
      assert user.profile_url == "https://example.com/f.png"
    end

    test "saves github profile_url and display_name on create" do
      attrs = %{
        github_id: "583231",
        email: "octocat@example.com",
        profile_url: "https://avatars.githubusercontent.com/u/583231",
        display_name: "The Octocat"
      }

      assert {:ok, user} = Accounts.find_or_create_from_github(attrs)
      assert user.github_id == "583231"
      assert user.profile_url == "https://avatars.githubusercontent.com/u/583231"
      assert user.display_name == "The Octocat"
      assert Accounts.get_user_by_github_id("583231").id == user.id
      assert Accounts.get_linked_providers(user).github == true
    end

    test "creates a github user with no email, as a Steam user is" do
      assert {:ok, user} = Accounts.find_or_create_from_github(%{github_id: "7", email: nil})
      assert user.github_id == "7"
      assert user.email == nil
    end

    test "links github to an existing account only on a verified email" do
      {:ok, user} = Gamend.Accounts.register_user(%{email: "ghlink@example.com"})

      assert {:error, _} =
               Accounts.find_or_create_from_github(%{
                 github_id: "gh_unverified",
                 email: user.email,
                 email_verified: false
               })

      assert {:ok, linked} =
               Accounts.find_or_create_from_github(%{
                 github_id: "gh_verified",
                 email: user.email,
                 email_verified: true
               })

      assert linked.id == user.id
      assert linked.github_id == "gh_verified"
    end

    test "saves display_name from google and facebook on create" do
      gattrs = %{
        google_id: "g_name",
        email: "gname@example.com",
        profile_url: "https://example.com/g.png",
        display_name: "Google Guy"
      }

      fattrs = %{
        facebook_id: "f_name",
        email: "fname@example.com",
        profile_url: "https://example.com/f.png",
        display_name: "FB Person"
      }

      assert {:ok, gu} = Accounts.find_or_create_from_google(gattrs)
      assert gu.display_name == "Google Guy"

      assert {:ok, fu} = Accounts.find_or_create_from_facebook(fattrs)
      assert fu.display_name == "FB Person"
    end

    test "does not overwrite existing profile_url when updating via provider" do
      # create initial user with profile_url already set
      {:ok, user} = Gamend.Accounts.register_user(%{email: "exist@example.com"})

      user =
        Ecto.Changeset.change(user, profile_url: "https://existing.example/old.png")
        |> Gamend.Repo.update!()

      # Attempt to link google with new profile_url; existing profile_url should remain
      attrs = %{
        google_id: "g_999",
        email: user.email,
        email_verified: true,
        profile_url: "https://example.com/new.png"
      }

      assert {:ok, updated} = Accounts.find_or_create_from_google(attrs)
      assert updated.id == user.id
      assert updated.profile_url == "https://existing.example/old.png"
      # ensure display_name is not overwritten when linking if already set
      # create a user with a manually set display_name and attempt to link a provider
      {:ok, user2} = Gamend.Accounts.register_user(%{email: "display@example.com"})

      user2 =
        Ecto.Changeset.change(user2, display_name: "Local Name") |> Gamend.Repo.update!()

      attrs = %{
        google_id: "g_link",
        email: user2.email,
        email_verified: true,
        display_name: "Provider Name"
      }

      assert {:ok, updated2} = Accounts.find_or_create_from_google(attrs)
      assert updated2.display_name == "Local Name"
    end

    test "an over-long provider profile_url is dropped rather than failing the sign-in" do
      long_url = oversized_url("x")
      assert String.length(long_url) > Gamend.Limits.get(:max_profile_url)

      attrs = %{
        google_id: "g_long_url",
        email: "glongurl@example.com",
        email_verified: true,
        profile_url: long_url
      }

      assert {:ok, user} = Accounts.find_or_create_from_google(attrs)
      assert user.google_id == "g_long_url"
      assert user.profile_url == nil
    end

    test "a profile_url exactly at the limit is still saved" do
      max = Gamend.Limits.get(:max_profile_url)
      prefix = "https://example.com/"
      url = prefix <> String.duplicate("y", max - String.length(prefix))
      assert String.length(url) == max

      attrs = %{
        google_id: "g_max_url",
        email: "gmaxurl@example.com",
        email_verified: true,
        profile_url: url
      }

      assert {:ok, user} = Accounts.find_or_create_from_google(attrs)
      assert user.profile_url == url
    end

    test "an over-long provider profile_url leaves an existing avatar untouched" do
      {:ok, user} = Gamend.Accounts.register_user(%{email: "keepavatar@example.com"})

      user =
        Ecto.Changeset.change(user, profile_url: "https://existing.example/keep.png")
        |> Gamend.Repo.update!()

      attrs = %{
        google_id: "g_keep_avatar",
        email: user.email,
        email_verified: true,
        profile_url: oversized_url("z")
      }

      assert {:ok, updated} = Accounts.find_or_create_from_google(attrs)
      assert updated.id == user.id
      assert updated.profile_url == "https://existing.example/keep.png"
    end

    # Built from the configured limit rather than a literal, so raising
    # max_profile_url cannot quietly turn these into tests of nothing.
    defp oversized_url(char) do
      prefix = "https://lh3.googleusercontent.com/a/"
      pad = Gamend.Limits.get(:max_profile_url) - String.length(prefix) + 1
      prefix <> String.duplicate(char, pad)
    end
  end
end
