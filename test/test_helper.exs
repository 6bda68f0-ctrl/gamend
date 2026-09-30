ExUnit.start()

# `mix test` here goes on to run the core and web suites as child processes
# while this VM waits for them. The host app it booted would sit through both,
# and `IpBanSync` and `Moderation.Sync` each hold the sandbox connection they
# checked out at boot — until the 120s ownership timeout logged them as errors
# in the middle of another suite's output. This suite is over, so is the app.
ExUnit.after_suite(fn _results -> Application.stop(:gamend_host) end)
