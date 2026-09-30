#!/usr/bin/env node
/**
 * check_js.js
 *
 * Call a live server through the built JS SDK and check each answer is an
 * instance of its named model class (`SessionResponse`, `Lobby`, `GroupPage`
 * ...). smoke_package.js proves the package loads; this proves the document
 * and the server agree. It found the operations whose missing `security`
 * kept the SDK from sending its token.
 *
 *   node clients/check_js.js http://127.0.0.1:4000
 *
 * Signs in with a fresh device id (device login must be on) and writes a
 * user, a lobby and a party it leaves, and a group it keeps.
 */
const path = require('path')
const sdk = require(path.join(__dirname, 'javascript', 'dist', 'index.js'))
const client = new sdk.ApiClient()
client.basePath = process.argv[2] || 'http://127.0.0.1:4000'
let failures = 0
function expect (label, value, Model) {
  if (value instanceof Model) console.log(`ok   ${label} -> ${Model.name}`)
  else { failures++; console.log(`FAIL ${label}: got ${JSON.stringify(value).slice(0, 120)}`) }
  return value
}
;(async () => {
  const auth = new sdk.AuthenticationApi(client)
  const session = expect('deviceLogin', await auth.deviceLogin({ deviceLoginRequest: { device_id: `js-check-${Date.now()}` } }), sdk.SessionResponse)
  expect('deviceLogin.data', session.data, sdk.Session)
  client.authentications.authorization.accessToken = session.data.access_token
  const me = expect('getCurrentUser', await new sdk.UsersApi(client).getCurrentUser(), sdk.CurrentUserResponse)
  expect('getCurrentUser.data', me.data, sdk.CurrentUser)
  expect('getCurrentUser.data.linked_providers', me.data.linked_providers, sdk.LinkedProviders)
  const lobbies = new sdk.LobbiesApi(client)
  const lobby = expect('quickJoin', await lobbies.quickJoin({ quickJoinRequest: { title: 'js-check', max_users: 2 } }), sdk.LobbyResponse).data
  const detail = expect('getLobby', await lobbies.getLobby(lobby.id), sdk.LobbyResponse)
  expect('getLobby.data', detail.data, sdk.Lobby)
  expect('getLobby.data.members[0]', detail.data.members[0], sdk.UserBrief)
  const page = expect('listLobbies', await lobbies.listLobbies({}), sdk.LobbyPage)
  expect('listLobbies.meta', page.meta, sdk.PageMeta)
  expect('listFriends', await new sdk.FriendsApi(client).listFriends({}), sdk.FriendPage)
  await lobbies.leaveLobby()
  const groups = new sdk.GroupsApi(client)
  const group = expect('createGroup', await groups.createGroup({ createGroupRequest: { title: `js-check-${Date.now()}` } }), sdk.GroupResponse).data
  expect('listGroupMembers', await groups.listGroupMembers(group.id, {}), sdk.GroupMemberPage)
  expect('getGroup', await groups.getGroup(group.id), sdk.GroupResponse)
  const party = expect('createParty', await new sdk.PartiesApi(client).createParty({ createPartyRequest: { max_size: 4 } }), sdk.PartyResponse)
  expect('createParty.data.members[0]', party.data.members[0], sdk.UserBrief)
  await new sdk.PartiesApi(client).leaveParty()
  const boards = new sdk.LeaderboardsApi(client)
  const boardPage = expect('listLeaderboards', await boards.listLeaderboards({}), sdk.LeaderboardPage)
  if (boardPage.data.length) {
    const board = expect('listLeaderboards.data[0]', boardPage.data[0], sdk.Leaderboard)
    expect('getLeaderboard', await boards.getLeaderboard(board.id), sdk.LeaderboardResponse)
    expect('listLeaderboardRecords', await boards.listLeaderboardRecords(board.id, {}), sdk.LeaderboardRecordPage)
  }
  const cups = new sdk.TournamentsApi(client)
  const cupPage = expect('listTournaments', await cups.listTournaments({}), sdk.TournamentPage)
  if (cupPage.data.length) {
    const cup = expect('listTournaments.data[0]', cupPage.data[0], sdk.Tournament)
    expect('getTournament', await cups.getTournament(cup.id), sdk.TournamentResponse)
    const brackets = expect('tournamentBracket', await cups.tournamentBracket(cup.id, {}), sdk.TournamentBracketPage)
    expect('tournamentBracket.meta', brackets.meta, sdk.PageMeta)
    expect('tournamentStandings', await cups.tournamentStandings(cup.id), sdk.TournamentStandingsResponse)
  }
  const quests = new sdk.QuestsApi(client)
  const questPage = expect('myQuests', await quests.myQuests({}), sdk.QuestPage)
  if (questPage.data.length) expect('myQuests.data[0]', questPage.data[0], sdk.Quest)
  expect('questStats', await quests.questStats(), sdk.QuestStatsResponse)
  const economy = new sdk.EconomyApi(client)
  expect('getCurrentUserWallet', await economy.getCurrentUserWallet(), sdk.WalletBalancesResponse)
  expect('listCurrentUserLedger', await economy.listCurrentUserLedger({}), sdk.LedgerEntryPage)
  const payments = new sdk.PaymentsApi(client)
  expect('paymentsCatalog', await payments.paymentsCatalog({}), sdk.PaymentCatalogEntryPage)
  expect('paymentsEntitlements', await payments.paymentsEntitlements({}), sdk.EntitlementPage)
  expect('health', await new sdk.HealthApi(client).index(), sdk.HealthResponse)
  expect('getServerTime', await new sdk.TimeApi(client).getServerTime(), sdk.ServerTimeResponse)
  const stats = expect('getStats', await new sdk.StatsApi(client).getStats(), sdk.ServerStatsResponse)
  expect('getStats.data', stats.data, sdk.ServerStats)
  expect('listHooks', await new sdk.HooksApi(client).listHooks({}), sdk.HookFunctionPage)
  expect('getMyReadyCheck', await new sdk.ReadyChecksApi(client).getMyReadyCheck(), sdk.MyReadyChecksResponse)
  expect('matchmakingStats', await new sdk.MatchmakingApi(client).matchmakingStats(), sdk.MatchmakingStatsResponse)
  console.log(`failures=${failures}`)
  process.exit(failures ? 1 : 0)
})().catch(e => { console.log('FAIL', e.message, e.response && e.response.text); process.exit(1) })
