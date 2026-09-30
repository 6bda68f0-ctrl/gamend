defmodule Gamend.OAuth.Providers do
  @moduledoc """
  Credentials and availability for the social sign-in providers.

  A provider is live when its credentials are set and its `<provider>_enabled`
  setting has not been switched off. `enabled/0` drives everything that varies
  by provider — the sign-in buttons, the `/auth/:provider` routes, and the
  `GET /api/v1/auth/providers` listing — so they can never disagree.

  The id and secret are declared as a pair, so half-configuring one is a
  warning rather than a silent failure at the first login attempt.
  """

  use Gamend.Settings.Provider,
    app: :gamend_core,
    group: :oauth,
    label: "OAuth providers"

  @providers [:discord, :google, :apple, :facebook, :github, :steam]

  # One key marks a provider as configured; its partner keys are enforced by
  # the `with:` groups below.
  @presence_key %{
    discord: :discord_client_id,
    google: :google_client_id,
    apple: :apple_client_id,
    facebook: :facebook_client_id,
    github: :github_client_id,
    steam: :steam_api_key
  }

  for provider <- @providers do
    setting(:"#{provider}_enabled", :boolean,
      default: true,
      doc: "Offer #{provider} sign-in. Only takes effect once its credentials are set."
    )
  end

  for provider <- [:discord, :google, :facebook, :github] do
    id_key = :"#{provider}_client_id"
    secret_key = :"#{provider}_client_secret"

    setting(id_key, :string, required: :warn, with: [secret_key])

    setting(secret_key, :string,
      secret: true,
      required: :warn,
      with: [id_key]
    )
  end

  setting(:google_web_client_id, :string,
    doc: "Native-app client id used to verify Google ID tokens from SDK sign-in."
  )

  # Sign in with Apple needs all four together: the client secret is a JWT this
  # server signs from the .p8 key, so a missing piece means no login at all.
  @apple [:apple_client_id, :apple_team_id, :apple_key_id, :apple_private_key]

  setting(:apple_client_id, :string,
    required: :warn,
    with: @apple,
    doc: "Services id (web audience) for Sign in with Apple."
  )

  setting(:apple_ios_client_id, :string,
    doc: "Bundle id (iOS audience) used when verifying Apple ID tokens."
  )

  setting(:apple_team_id, :string, required: :warn, with: @apple)

  setting(:apple_key_id, :string,
    required: :warn,
    with: @apple,
    doc: "Key id of the Sign in with Apple auth key (Apple Developer -> Keys)."
  )

  setting(:apple_private_key, :string,
    secret: true,
    required: :warn,
    with: @apple,
    doc: "Contents of the Sign in with Apple .p8 key."
  )

  setting(:steam_api_key, :string,
    secret: true,
    doc: "Steam Web API key, used for OpenID sign-in."
  )

  setting(:steam_app_id, :string)

  @doc "Every provider this server knows, in display order."
  @spec all() :: [atom()]
  def all, do: @providers

  @doc "The providers a player may currently sign in with."
  @spec enabled() :: [atom()]
  def enabled, do: Enum.filter(@providers, &enabled?/1)

  @doc "Whether `provider` is configured and switched on."
  @spec enabled?(atom()) :: boolean()
  def enabled?(provider) when provider in @providers do
    configured?(provider) and
      Gamend.Settings.get(__MODULE__, :"#{provider}_enabled") != false
  end

  def enabled?(_provider), do: false

  @doc "Whether `provider` has credentials set."
  @spec configured?(atom()) :: boolean()
  def configured?(provider) when provider in @providers do
    Gamend.Settings.get(__MODULE__, Map.fetch!(@presence_key, provider)) not in [nil, ""]
  end

  def configured?(_provider), do: false
end
