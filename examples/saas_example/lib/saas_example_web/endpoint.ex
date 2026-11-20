defmodule SaasExampleWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :saas_example

  @session_options [
    store: :cookie,
    key: "_saas_example_key",
    signing_salt: "ash_billing_saas_salt",
    same_site: "Lax",
    http_only: true
  ]

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # Preserve raw request body so AshBilling.Plug can verify Stripe HMAC signatures
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    body_reader: {AshBilling.Plug, :read_body, []},
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug SaasExampleWeb.Router
end
