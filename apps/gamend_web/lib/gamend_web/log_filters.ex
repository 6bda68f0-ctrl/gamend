defmodule GamendWeb.LogFilters do
  @moduledoc """
  Primary `:logger` filters for crash reports that are noise, not defects.

  A **primary** filter (rather than a per-handler one) because these reports are
  worthless everywhere: console, file log and the admin Logs buffer alike.
  Filtering once at the source also keeps them from consuming the admin buffer,
  which is a fixed-size ring — a steady stream of noise evicts the real entries
  long before anyone reads them.

  ## The TLS client alerts

  When a client closes a TLS connection by sending a `user_canceled` alert
  (Safari and iOS do this routinely on navigation away), Erlang's `:ssl` sends
  the owning process `{:ssl_error, socket, {:tls_alert, {:user_canceled, _}}}`.
  Thousand Island turns that straight into `{:stop, reason, state}`:

      def handle_info({msg, raw_socket, reason}, {socket, state})
          when msg in [:tcp_error, :ssl_error] do
        {:stop, reason, {socket, state}}
      end

  The reason is neither `:normal` nor `:shutdown`, so OTP logs a full
  `gen_server terminate` crash report with the entire socket struct inlined —
  one per closing client. Note this path ignores Thousand Island's
  `silent_terminate_on_error` option, which only covers the *handler-return*
  error path, so there is no configuration knob that suppresses it.

  ## Why an allowlist rather than "drop all TLS alerts"

  Most TLS alerts are worth seeing. `handshake_failure`, `unknown_ca` and
  `certificate_expired` on a server that terminates TLS itself (this one binds
  443 directly — no proxy) are how a broken or expired certificate announces
  itself. Dropping every `:tls_alert` would silence the one class of TLS error
  that actually needs a human. Only alerts that mean "the peer went away or
  never spoke TLS" are listed.

  ## The corruption alerts

  Binding 443 straight to the internet puts every scanner, broken middlebox and
  half-open mobile connection in front of the TLS stack, and each one costs a
  full crash report:

    * `bad_record_mac` — a record failed its authentication check, in either
      direction (`decryption_failed`, `record_type_mismatch`). Bytes were
      altered, truncated or replayed in transit; nothing on this side can
      repair a network path that mangles packets.
    * `unexpected_message` carrying `unsupported_record_type` — the byte where
      a TLS content type belongs is not one of the four legal values (20, 21,
      22, 23). Whatever connected is not speaking TLS at all.

  Both are peer faults by construction. A genuine misconfiguration on this side
  fails during the *handshake*, as one of the alerts deliberately kept above.

  ## The one alert placed by direction, not by name

  `protocol_version` is both: this server choosing a version the client will not
  accept is a real misconfiguration, while a client that completed the
  handshake, exchanged HTTP/2 frames and *then* sends a fatal
  `protocol_version` is tearing down a connection over a version it already
  agreed to — Apple's `NetworkingExtension` does exactly this. The atom is the
  same in both cases, so the description decides: only `In state connection
  received CLIENT ALERT` is dropped, which is post-handshake *and* peer-sent.
  Anything during the handshake, and anything this server generates, still
  reaches the log.

  ## The non-alert noise

  `Bandit.TransportError` "Unable to obtain conn_data" is a socket that died
  between accept and first read: `:inet.peername/1` answers `:einval` because
  there is no longer a connection to name. Scanners that connect and instantly
  reset produce a steady trickle of these.

  Bandit's "Connection that looks like TLS received on a clear channel" is a
  client speaking TLS to port 80. This app serves 80 only to redirect and to
  answer ACME challenges, so that is the client's mistake, not a fault here.

  Bandit's own protocol-error lines — malformed request lines, forbidden HTTP/2
  headers, bodies cut short — are deliberately *not* handled here. They are
  switched off at the source, `log_protocol_errors: false` on both listeners in
  `GamendWeb.HostRuntime`, because every one of them is the peer's fault by
  construction and matching their message strings here would be a patch on top
  of a patch. The dead-socket rule below still applies to a host that builds
  its own endpoint config and leaves Bandit's default in place.
  """

  @filter_id :drop_benign_tls_alerts

  # Alerts that mean the peer hung up, or that what arrived was corrupt or was
  # never TLS. Everything else — anything implicating our certificate or our
  # TLS configuration — stays visible.
  # Alerts that are noise only in one direction and one state, so the alert atom
  # alone cannot place them: the peer *sending* `protocol_version` after the
  # handshake already completed is a client tearing a live connection down over
  # a version it accepted a moment earlier — iOS `NetworkingExtension` does
  # this. The same atom during the handshake is a genuine version mismatch, and
  # one this server generates is a misconfiguration here, so both stay visible.
  @peer_only_alerts [:protocol_version]

  # Erlang's `ssl` names the direction and the state machine's state in the
  # alert description, and `connection` is the post-handshake state.
  @established_peer_alert "In state connection received CLIENT ALERT"

  @benign_alerts [
    :user_canceled,
    :close_notify,
    :closure_alert,
    :bad_record_mac,
    :decryption_failed,
    :decrypt_error,
    :record_overflow,
    :unexpected_message,
    :decode_error
  ]

  # Socket errors meaning the connection was gone before it could be used.
  @dead_socket_errors [:einval, :closed, :enotconn, :econnreset, :epipe, :etimedout]

  @clear_channel_warning "Connection that looks like TLS received on a clear channel"

  @doc """
  Installs the filters. Idempotent: re-installing is a no-op, so a supervisor
  restart cannot stack duplicates.
  """
  def install do
    case :logger.add_primary_filter(@filter_id, {&__MODULE__.filter_tls_alert/2, []}) do
      :ok -> :ok
      {:error, {:already_exist, _}} -> :ok
      other -> other
    end
  end

  @doc false
  def uninstall do
    _ = :logger.remove_primary_filter(@filter_id)
    :ok
  end

  @doc """
  Drops crash reports and warnings caused by the peer rather than by this server.

  Returns `:stop` to drop the event, or `:ignore` to leave it for the remaining
  filters and handlers — never the event itself, since this filter only ever
  rejects and must not short-circuit other filters by accepting.

  `extra` is the filter config `:logger` was given at install. A `:host_filters`
  list there wins over the application env; `install/0` passes none, so
  production reads the host's config live, and a caller (or a test) can pin
  its own list without touching global state.
  """
  def filter_tls_alert(event, extra) do
    if peer_fault?(event, extra), do: :stop, else: :ignore
  end

  defp peer_fault?(event, extra) do
    reason = reason(event)

    benign_tls_alert?(reason) or dead_socket?(reason) or clear_channel_warning?(event) or
      host_filters_drop?(event, extra)
  end

  @doc """
  The host-supplied `GamendWeb.LogFilter` modules, in configuration order.

  Noise from a host's own code is the host's to describe; this is how it says
  so without patching core.
  """
  def host_filters, do: Application.get_env(:gamend_web, :log_filters, [])

  defp host_filters(extra) when is_list(extra),
    do: Keyword.get(extra, :host_filters) || host_filters()

  defp host_filters(_extra), do: host_filters()

  defp host_filters_drop?(event, extra),
    do: Enum.any?(host_filters(extra), &safe_drop?(&1, event))

  # A raise here is treated as "do not drop". It deliberately goes unreported:
  # this runs inside the logging pipeline, so logging the failure would recurse
  # through this very filter. A broken host filter therefore loses only its own
  # noise, never the log itself, and never the events core knows how to drop.
  defp safe_drop?(module, event) do
    module.drop?(event) == true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # Bandit raises this when the socket is already gone, so the crash carries an
  # exception rather than a `:tls_alert` tuple.
  defp dead_socket?({%Bandit.TransportError{error: error}, stack}) when is_list(stack),
    do: error in @dead_socket_errors

  defp dead_socket?(%Bandit.TransportError{error: error}), do: error in @dead_socket_errors
  defp dead_socket?({:shutdown, inner}), do: dead_socket?(inner)
  defp dead_socket?(_reason), do: false

  # A plain `Logger.warning/2` from Bandit, not a crash report — matched on its
  # message because that is all the event carries.
  defp clear_channel_warning?(%{msg: {:string, message}}),
    do: to_string(message) =~ @clear_channel_warning

  defp clear_channel_warning?(%{msg: {format, args}}) when is_binary(format) and is_list(args),
    do: format =~ @clear_channel_warning

  defp clear_channel_warning?(_event), do: false

  # `gen_server`/`gen_statem` terminate reports carry the reason as a map key.
  defp reason(%{msg: {:report, %{reason: reason}}}), do: reason

  # `proc_lib` crash reports nest it in a keyword-ish list of error info.
  defp reason(%{msg: {:report, %{report: [error_info | _]}}}) when is_list(error_info) do
    case :proplists.get_value(:error_info, error_info, nil) do
      {_kind, reason, _stack} -> reason
      _ -> nil
    end
  end

  # Bandit logs protocol errors itself rather than letting the process crash:
  # `Bandit.Logger.maybe_log_protocol_error/4` calls `Logger.error/2` with
  # `Exception.format_banner/3` output. The event that reaches here is therefore
  # a plain *string* — "** (Bandit.TransportError) Unable to obtain conn_data" —
  # and the exception survives only in metadata, under `crash_reason`. Both
  # report clauses above look at `msg`, so this path went unfiltered and the
  # dead-socket trickle reached production logs despite being described here.
  defp reason(%{meta: %{crash_reason: {reason, stack}}}) when is_list(stack), do: {reason, stack}

  defp reason(_event), do: nil

  defp benign_tls_alert?({:tls_alert, {alert, description}}) do
    alert in @benign_alerts or
      (alert in @peer_only_alerts and established_peer_alert?(description))
  end

  # A stop reason can wrap the alert, e.g. `{:shutdown, {:tls_alert, ...}}`.
  defp benign_tls_alert?({:shutdown, inner}), do: benign_tls_alert?(inner)
  defp benign_tls_alert?(_reason), do: false

  # The description is a charlist from `ssl`, so it is flattened before matching.
  defp established_peer_alert?(description) when is_list(description) or is_binary(description),
    do: to_string(description) =~ @established_peer_alert

  defp established_peer_alert?(_description), do: false
end
