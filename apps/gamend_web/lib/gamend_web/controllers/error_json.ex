defmodule GamendWeb.ErrorJSON do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on JSON requests.

  See config/config.exs.
  """

  # If you want to customize a particular status code,
  # you may add your own clauses, such as:
  #
  # def render("500.json", _assigns) do
  #   %{errors: %{detail: "Internal Server Error"}}
  # end

  # By default, Phoenix returns the status message from
  # the template name. For example, "404.json" becomes
  # "Not Found".
  #
  # Every JSON error takes the one shape (api-conventions.md, R15): a
  # snake_case code from the status, and the status text as the message —
  # `{"error": "not_found", "message": "Not Found"}`.
  def render(template, _assigns) do
    message = Phoenix.Controller.status_message_from_template(template)

    code =
      message
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    %{error: code, message: message}
  end
end
