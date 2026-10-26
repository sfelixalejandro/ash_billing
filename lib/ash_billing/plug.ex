defmodule AshBilling.Plug do
  @moduledoc """
  A Plug for receiving and verifying incoming webhooks from billing providers.

  ## Usage in Phoenix Router

      forward "/webhooks/stripe", AshBilling.Plug,
        provider: AshBilling.Providers.Stripe,
        webhook_secret: {System, :get_env, ["STRIPE_WEBHOOK_SECRET"]},
        handler: MyApp.Billing.WebhookHandler
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    provider = Keyword.get(opts, :provider, AshBilling.Providers.Stripe)
    secret = resolve_secret(Keyword.get(opts, :webhook_secret))
    handler = Keyword.get(opts, :handler)

    :telemetry.span([:ash_billing, :webhook], %{conn: conn, provider: provider}, fn ->
      {:ok, raw_body, conn} = read_raw_body(conn)
      signature_header = get_req_header(conn, "stripe-signature") |> List.first()

      case provider.verify_webhook(raw_body, signature_header, secret, opts) do
        {:ok, event} ->
          event_id = Map.get(event, "id")
          event_type = Map.get(event, "type")
          deduplicate? = Keyword.get(opts, :deduplicate?, true)

          if deduplicate? and AshBilling.Deduplication.processed?(event_id, opts) do
            resp_conn =
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(200, ~s({"status":"already_processed"}))
              |> halt()

            {resp_conn, %{status: :already_processed, event_id: event_id, event_type: event_type}}
          else
            if deduplicate?, do: AshBilling.Deduplication.mark_processed(event_id, opts)

            if Keyword.has_key?(opts, :subscription_resource) or
                 Keyword.has_key?(opts, :customer_resource) do
              AshBilling.WebhookSync.sync_event(event, opts)
            end

            if is_atom(handler) and function_exported?(handler, :handle_event, 1) do
              handler.handle_event(event)
            end

            resp_conn =
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(200, ~s({"status":"received"}))
              |> halt()

            {resp_conn, %{status: :received, event_id: event_id, event_type: event_type}}
          end

        {:error, reason} ->
          resp_conn =
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(400, Jason.encode!(%{error: to_string(reason)}))
            |> halt()

          {resp_conn, %{status: :error, error: reason}}
      end
    end)
  end

  defp read_raw_body(%{assigns: %{raw_body: body}} = conn) when is_binary(body) do
    {:ok, body, conn}
  end

  defp read_raw_body(conn) do
    case read_body(conn) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:error, :body_too_large, conn}
      {:error, reason} -> {:error, reason, conn}
    end
  end

  defp resolve_secret({module, function, args}) when is_atom(module) and is_atom(function) do
    apply(module, function, args)
  end

  defp resolve_secret(fun) when is_function(fun, 0), do: fun.()
  defp resolve_secret(secret) when is_binary(secret), do: secret
  defp resolve_secret(_), do: ""
end
