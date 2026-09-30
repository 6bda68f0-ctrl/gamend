defmodule GamendWeb.Auth.OAuthExchangeAppleNameTest do
  use ExUnit.Case, async: true

  alias GamendWeb.Auth.OAuthExchange

  describe "apple_name/2" do
    test "joins and trims the parts" do
      assert OAuthExchange.apple_name(" Ada ", "Lovelace") == "Ada Lovelace"
      assert OAuthExchange.apple_name("Ada", nil) == "Ada"
      assert OAuthExchange.apple_name(nil, "Lovelace") == "Lovelace"
    end

    test "is nil when there is nothing to use" do
      assert OAuthExchange.apple_name(nil, nil) == nil
      assert OAuthExchange.apple_name("  ", "") == nil
      assert OAuthExchange.apple_name(%{}, 3) == nil
    end

    test "drops a name past the display-name limit instead of cutting it" do
      max = Gamend.Limits.get(:max_display_name)
      assert max == 255
      assert OAuthExchange.apple_name(String.duplicate("a", max + 10), "b") == nil

      assert OAuthExchange.apple_name(String.duplicate("a", max), nil) ==
               String.duplicate("a", max)
    end
  end

  describe "apple_web_name/1" do
    test "reads Apple's user JSON" do
      user = ~s({"name":{"firstName":"Ada","lastName":"Lovelace"},"email":"a@b.c"})
      assert OAuthExchange.apple_web_name(user) == "Ada Lovelace"
    end

    test "is nil for a missing, nameless or malformed field" do
      assert OAuthExchange.apple_web_name(nil) == nil
      assert OAuthExchange.apple_web_name(~s({"email":"a@b.c"})) == nil
      assert OAuthExchange.apple_web_name("{not json") == nil
    end
  end

  describe "put_apple_name/2" do
    test "keeps the params when there is no name" do
      assert OAuthExchange.put_apple_name(%{apple_id: "x"}, nil) == %{apple_id: "x"}
      assert OAuthExchange.put_apple_name(%{}, "Ada") == %{display_name: "Ada"}
    end
  end
end
