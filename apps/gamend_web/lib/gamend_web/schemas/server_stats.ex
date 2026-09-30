defmodule GamendWeb.Schemas.ServerTime do
  @moduledoc "The server's clock, for a client estimating its offset."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ServerTime",
    description: "The server's clock",
    type: :object,
    properties: %{
      server_now: %Schema{type: :integer, description: "Milliseconds since the Unix epoch"}
    },
    required: [:server_now]
  })
end

defmodule GamendWeb.Schemas.SignalingStats do
  @moduledoc "The counters `Gamend.Signaling.stats/0` returns."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "SignalingStats",
    description: "WebRTC room counts, cached for up to a minute",
    type: :object,
    properties: %{
      rooms_enabled: %Schema{type: :integer, description: "Lobbies with WebRTC on"},
      rooms_active: %Schema{type: :integer, description: "Of those, with someone connected"},
      peers_connected: %Schema{type: :integer}
    },
    required: [:rooms_enabled, :rooms_active, :peers_connected]
  })
end

defmodule GamendWeb.Schemas.ActivityStats do
  @moduledoc "Active and new players over the last day, week and month."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ActivityStats",
    description: "Active and new player counts",
    type: :object,
    properties: %{
      dau: %Schema{type: :integer},
      wau: %Schema{type: :integer},
      mau: %Schema{type: :integer},
      new_users_1d: %Schema{type: :integer},
      new_users_7d: %Schema{type: :integer},
      new_users_30d: %Schema{type: :integer}
    },
    required: [:dau, :wau, :mau, :new_users_1d, :new_users_7d, :new_users_30d]
  })
end

defmodule GamendWeb.Schemas.TournamentMatchCounts do
  @moduledoc "Tournament matches: all, still open, and open past their deadline."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "TournamentMatchCounts",
    description: "Tournament match counts",
    type: :object,
    properties: %{
      total: %Schema{type: :integer},
      open: %Schema{type: :integer},
      overdue: %Schema{type: :integer}
    },
    required: [:total, :open, :overdue]
  })
end

defmodule GamendWeb.Schemas.TournamentStats do
  @moduledoc "The counters `Gamend.Tournaments.stats/0` returns."
  require OpenApiSpex
  alias GamendWeb.Schemas.TournamentMatchCounts
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "TournamentStats",
    description: "Tournaments and entries per state, and match counts",
    type: :object,
    properties: %{
      tournaments: %Schema{
        type: :object,
        description: "Tournament count per state",
        additionalProperties: %Schema{type: :integer}
      },
      entries: %Schema{
        type: :object,
        description: "Entry count per state",
        additionalProperties: %Schema{type: :integer}
      },
      matches: TournamentMatchCounts
    },
    required: [:tournaments, :entries, :matches]
  })
end

defmodule GamendWeb.Schemas.ServerStats do
  @moduledoc """
  Every public counter in one answer, from `Gamend.Analytics.snapshot/0`: each
  part is what that domain's own `/stats` endpoint answers.
  """
  require OpenApiSpex

  alias GamendWeb.Schemas.{
    ActivityStats,
    LobbyStats,
    MatchmakingStats,
    PartyStats,
    PlayerStats,
    QuestStats,
    SignalingStats,
    TournamentStats
  }

  OpenApiSpex.schema(%{
    title: "ServerStats",
    description: "All public server counters, cached for up to a minute",
    type: :object,
    properties: %{
      players: PlayerStats,
      activity: ActivityStats,
      lobbies: LobbyStats,
      parties: PartyStats,
      quests: QuestStats,
      signaling: SignalingStats,
      matchmaking: MatchmakingStats,
      tournaments: TournamentStats
    },
    required: [
      :players,
      :activity,
      :lobbies,
      :parties,
      :quests,
      :signaling,
      :matchmaking,
      :tournaments
    ]
  })
end

defmodule GamendWeb.Schemas.ServerTimeResponse do
  @moduledoc "The server's clock under `data`."
  use GamendWeb.Schemas.Envelope, data: GamendWeb.Schemas.ServerTime
end

defmodule GamendWeb.Schemas.SignalingStatsResponse do
  @moduledoc "WebRTC room counts under `data`."
  use GamendWeb.Schemas.Envelope, data: GamendWeb.Schemas.SignalingStats
end

defmodule GamendWeb.Schemas.ServerStatsResponse do
  @moduledoc "Every public counter under `data`."
  use GamendWeb.Schemas.Envelope, data: GamendWeb.Schemas.ServerStats
end
