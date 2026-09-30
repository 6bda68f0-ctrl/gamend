import Config

# The core's base configuration (repo adapter, jobs, cache, mailer, storage)
# and, under test, its test settings. The web app is published and tested
# standalone, so it reads them from the core rather than keeping a copy.
import_config "../../gamend_core/config/config.exs"

# `mix cmd` (how host precommits run this app's tasks) pipes child output, so
# this BEAM boots with ANSI off even when the invoking terminal supports
# color. The parent sets FORCE_ANSI=true only when its own stdout is a TTY,
# so CI logs stay escape-free.
if System.get_env("FORCE_ANSI") == "true" do
  config :elixir, :ansi_enabled, true
end

config :gamend_web, :scopes,
  user: [
    default: true,
    module: Gamend.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :binary_id,
    schema_table: :users,
    test_data_fixture: Gamend.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :gamend_web,
  ecto_repos: [Gamend.Repo],
  generators: [timestamp_type: :utc_datetime],
  environment: config_env(),
  router: GamendWeb.Router,
  host_router: GamendWeb.Router,
  host_gettext_backend: GamendWeb.Gettext,
  home_banner_link: nil,
  host_static_app: :gamend_web,
  asset_static_app: :gamend_web,
  well_known_static_app: :gamend_web,
  host_static_paths: ~w(images game favicon.ico robots.txt .well-known theme.css)

config :gamend_web, GamendWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: GamendWeb.ErrorHTML, json: GamendWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Gamend.PubSub,
  live_view: [signing_salt: "ZPmggGLv"]

config :phoenix,
  gzippable_exts: ~w(.js .map .css .txt .text .html .json .svg .eot .ttf .wasm .pck)

config :esbuild,
  version: "0.25.4",
  gamend_web: [
    args:
      ~w(js/app.js js/theme-init.js js/mermaid.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{
      "NODE_PATH" => [
        Path.expand("../deps", __DIR__),
        Mix.Project.build_path(),
        Path.join(Mix.Project.build_path(), Atom.to_string(config_env()))
      ]
    }
  ]

config :tailwind,
  version: "4.1.7",
  gamend_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# `client_session` joins a server line to the game client that caused it (see
# `GamendWeb.Plugs.ClientSession`). The formatter emits only the keys named
# here, and stdout is what a log aggregator scrapes — so omitting it would mean
# the correlation worked on the admin page and nowhere else.
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :client_session]

config :phoenix, :json_library, Jason

config :phoenix, :filter_parameters, ["password", "token", "secret", "authorization", "api_key"]

config :gamend_web, GamendWeb.Auth.Guardian,
  issuer: "gamend",
  secret_key: "REPLACE_THIS_IN_RUNTIME_CONFIG"

config :gamend_web, :webrtc,
  enabled: true,
  ice_servers: [%{urls: "stun:stun.l.google.com:19302"}]

import_config "#{config_env()}.exs"

config :mime, :types, %{
  "application/octet-stream" => ["pck"]
}

# Ueberauth drives Steam only: its OpenID 2.0 callback verification has no
# OAuth-shaped equivalent. Discord, Google, Facebook, GitHub and Apple run through
# GamendWeb.AuthController and Gamend.OAuth.Exchanger directly, so that one
# code path can serve the browser redirect flow, the SDK session-polling flow
# and the native-token endpoints alike. ueberauth_apple stays a dependency for
# its client-secret JWT generation (Gamend.Apple), not as a strategy.
config :ueberauth, Ueberauth,
  providers: [
    steam: {Ueberauth.Strategy.Steam, []}
  ]

# Provider credentials are not set here. Ueberauth reads them from its own
# application env, which the host's config/host_runtime.exs fills from the
# declared Gamend.OAuth.Providers settings — one source, resolved at boot.
config :ueberauth, Ueberauth.Strategy.Apple.OAuth,
  client_secret: {Gamend.Apple, :client_secret}
