defmodule GamendWeb.LogFiltersTest do
  @moduledoc """
  The filter has to be narrow. Dropping every `:tls_alert` would also silence
  `handshake_failure` / `unknown_ca` / `certificate_expired`, which on a server
  that terminates TLS itself are how an expired or misconfigured certificate
  announces itself — the one TLS error that genuinely needs a human.
  """
  use ExUnit.Case, async: true

  alias GamendWeb.LogFilters

  defp terminate_report(reason) do
    %{
      level: :error,
      msg: {:report, %{label: {:gen_server, :terminate}, reason: reason, name: self()}}
    }
  end

  # Built the way `Bandit.Logger.maybe_log_protocol_error/4` builds it, banner
  # and all, so the test cannot drift from what Bandit really emits.
  defp bandit_protocol_error(errno) do
    error = %Bandit.TransportError{message: "Unable to obtain conn_data", error: errno}
    stack = [{Bandit.SocketHelpers, :transport_error!, 2, []}]

    %{
      level: :error,
      msg: {:string, Exception.format_banner(:error, error, stack)},
      meta: %{domain: [:bandit], crash_reason: {error, stack}}
    }
  end

  describe "peer-initiated alerts" do
    test "a user_canceled terminate report is dropped" do
      # The actual flood: Safari and iOS send this on navigation away, and
      # Thousand Island turns it into a non-shutdown stop reason.
      alert = {:tls_alert, {:user_canceled, ~c"TLS server: ... User Canceled\n"}}

      assert LogFilters.filter_tls_alert(terminate_report(alert), []) == :stop
    end

    test "close_notify is dropped too" do
      alert = {:tls_alert, {:close_notify, ~c"TLS server: ... Close Notify\n"}}

      assert LogFilters.filter_tls_alert(terminate_report(alert), []) == :stop
    end

    test "the alert is still recognised when wrapped in a shutdown tuple" do
      alert = {:shutdown, {:tls_alert, {:user_canceled, ~c"..."}}}

      assert LogFilters.filter_tls_alert(terminate_report(alert), []) == :stop
    end

    test "it is recognised inside a proc_lib crash report" do
      alert = {:tls_alert, {:user_canceled, ~c"..."}}

      event = %{
        level: :error,
        msg:
          {:report,
           %{
             label: {:proc_lib, :crash},
             report: [[error_info: {:exit, alert, []}], []]
           }}
      }

      assert LogFilters.filter_tls_alert(event, []) == :stop
    end
  end

  describe "corrupt or non-TLS traffic" do
    # Verbatim reasons taken from the production log — the flood this exists for.
    test "bad_record_mac from a client alert is dropped" do
      alert =
        {:tls_alert,
         {:bad_record_mac,
          ~c"TLS server: In state connection received CLIENT ALERT: Fatal - Bad Record MAC\n"}}

      assert LogFilters.filter_tls_alert(terminate_report(alert), []) == :stop
    end

    test "bad_record_mac we generate ourselves is dropped" do
      alert =
        {:tls_alert,
         {:bad_record_mac,
          ~c"TLS server: In state connection at tls_record_1_3.erl:372 generated SERVER ALERT: Fatal - Bad Record MAC\n decryption_failed"}}

      assert LogFilters.filter_tls_alert(terminate_report(alert), []) == :stop
    end

    test "a record type that is not TLS at all is dropped" do
      alert =
        {:tls_alert,
         {:unexpected_message,
          ~c"TLS server: In state connection at tls_record.erl:524 generated SERVER ALERT: Fatal - Unexpected Message\n {unsupported_record_type,43}"}}

      assert LogFilters.filter_tls_alert(terminate_report(alert), []) == :stop
    end
  end

  describe "protocol_version, which is placed by direction and not by name" do
    # Verbatim from the production log: an iOS NetworkingExtension that had
    # already completed the handshake and been served a favicon over HTTP/2.
    test "a peer alert after the handshake is dropped" do
      alert =
        {:tls_alert,
         {:protocol_version,
          ~c"TLS server: In state connection received CLIENT ALERT: Fatal - Protocol Version\n"}}

      assert LogFilters.filter_tls_alert(terminate_report(alert), []) == :stop
    end

    test "a peer alert during the handshake survives" do
      # Still the client's alert, but before `connection`: this is the shape a
      # client rejecting the version this server offered actually takes, and it
      # is the one that can mean the TLS config here is wrong.
      alert =
        {:tls_alert,
         {:protocol_version,
          ~c"TLS server: In state hello received CLIENT ALERT: Fatal - Protocol Version\n"}}

      assert LogFilters.filter_tls_alert(terminate_report(alert), []) == :ignore
    end

    test "one this server generates survives" do
      alert =
        {:tls_alert,
         {:protocol_version,
          ~c"TLS server: In state hello at tls_record.erl:253 generated SERVER ALERT: Fatal - Protocol Version\n"}}

      assert LogFilters.filter_tls_alert(terminate_report(alert), []) == :ignore
    end
  end

  describe "sockets that died before first use" do
    test "Bandit's conn_data failure is dropped" do
      reason =
        {%Bandit.TransportError{message: "Unable to obtain conn_data", error: :einval},
         [{Bandit.SocketHelpers, :transport_error!, 2, []}]}

      assert LogFilters.filter_tls_alert(terminate_report(reason), []) == :stop
    end

    test "a transport error that is not a dead socket survives" do
      reason =
        {%Bandit.TransportError{message: "something else", error: :eacces},
         [{Bandit.SocketHelpers, :transport_error!, 2, []}]}

      assert LogFilters.filter_tls_alert(terminate_report(reason), []) == :ignore
    end

    # The shape production actually emits. Bandit does not let the process
    # crash — `Bandit.Logger.maybe_log_protocol_error/4` logs the banner itself
    # — so the event is a string and the exception is only in `crash_reason`.
    # The terminate-report tests above passed while this trickled into the logs.
    test "Bandit's own protocol-error log is dropped" do
      assert LogFilters.filter_tls_alert(bandit_protocol_error(:einval), []) == :stop
    end

    test "Bandit's protocol-error log survives when the socket was alive" do
      assert LogFilters.filter_tls_alert(bandit_protocol_error(:eacces), []) == :ignore
    end
  end

  describe "TLS spoken to the clear-text port" do
    test "Bandit's warning is dropped" do
      event = %{
        level: :warning,
        msg: {:string, ~c"Connection that looks like TLS received on a clear channel"}
      }

      assert LogFilters.filter_tls_alert(event, []) == :stop
    end

    test "an unrelated warning survives" do
      event = %{level: :warning, msg: {:string, ~c"Slow Request: GET /admin took 618ms"}}

      assert LogFilters.filter_tls_alert(event, []) == :ignore
    end
  end

  describe "alerts that mean something is wrong on our side" do
    for alert <- [:handshake_failure, :unknown_ca, :certificate_expired, :bad_certificate] do
      test "#{alert} survives the filter" do
        reason = {:tls_alert, {unquote(alert), ~c"TLS server: ..."}}

        assert LogFilters.filter_tls_alert(terminate_report(reason), []) == :ignore
      end
    end
  end

  describe "everything else" do
    test "an ordinary crash is untouched" do
      report = terminate_report({:badmatch, nil})

      assert LogFilters.filter_tls_alert(report, []) == :ignore
    end

    test "a plain log message is untouched" do
      assert LogFilters.filter_tls_alert(%{level: :info, msg: {:string, ~c"hello"}}, []) ==
               :ignore
    end

    test "a report with no reason at all is untouched" do
      event = %{level: :error, msg: {:report, %{label: {:gen_server, :terminate}}}}

      assert LogFilters.filter_tls_alert(event, []) == :ignore
    end
  end

  describe "host-supplied filters" do
    defmodule DropsGreetings do
      @behaviour GamendWeb.LogFilter

      @impl true
      def drop?(%{msg: {:string, message}}), do: to_string(message) =~ "hello"
      def drop?(_event), do: false
    end

    defmodule Raises do
      @behaviour GamendWeb.LogFilter

      @impl true
      def drop?(_event), do: raise("boom")
    end

    # The filters go in through the logger filter's `extra` config rather than
    # `Application.put_env`: this module is async, and the installed filter
    # reads `:log_filters` on every log event, so a global put_env here would
    # apply these test filters to every other concurrent test's logging.

    test "a host filter can drop an event core knows nothing about" do
      event = %{level: :info, msg: {:string, ~c"hello there"}}

      assert LogFilters.filter_tls_alert(event, host_filters: [DropsGreetings]) == :stop
    end

    test "events it does not recognise are left alone" do
      event = %{level: :info, msg: {:string, ~c"something else"}}

      assert LogFilters.filter_tls_alert(event, host_filters: [DropsGreetings]) == :ignore
    end

    test "a raising host filter does not drop, and does not take the log down" do
      event = %{level: :error, msg: {:string, ~c"a real error"}}

      assert LogFilters.filter_tls_alert(event, host_filters: [Raises]) == :ignore
    end

    test "a raising host filter cannot stop core's own rules from applying" do
      alert = {:tls_alert, {:bad_record_mac, ~c"..."}}

      assert LogFilters.filter_tls_alert(terminate_report(alert), host_filters: [Raises]) ==
               :stop
    end
  end

  describe "install/0" do
    test "is idempotent, so a supervisor restart cannot stack duplicates" do
      on_exit(&LogFilters.uninstall/0)

      assert LogFilters.install() == :ok
      assert LogFilters.install() == :ok
    end
  end
end
