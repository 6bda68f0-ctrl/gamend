[
  # `use Gettext.Backend` generates plural handling that passes Expo's opaque
  # plural-forms term through a call Dialyzer cannot see into, on OTP 29 /
  # Elixir 1.20. Not our code.
  {"lib/gamend_web/gettext.ex", :call_without_opaque}
]
