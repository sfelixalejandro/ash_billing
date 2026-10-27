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
  def init(opts) do
    if Keyword.has_key?(opts, :resource) and not Keyword.has_key?(opts, :customer_resource) do
      Keyword.put(opts, :customer_resource, Keyword.get(opts, :resource))
    else
      opts
    end
  end

  @impl true
  def call(conn, opts) do
    provider = Keyword.get(opts, :provider, AshBilling.Providers.Stripe)
    secret = resolve_secret(Keyword.get(opts, :webhook_secret))
    handler = Keyword.get(opts, :handler)

    :telemetry.span([:ash_billing, :webhook], %{conn: conn, provider: provider}, fn ->
      case read_raw_body(conn, opts) do
        {:ok, raw_body, conn} ->
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

                {resp_conn,
                 %{status: :already_processed, event_id: event_id, event_type: event_type}}
              else
                sync_result =
                  if Keyword.has_key?(opts, :subscription_resource) or
                       Keyword.has_key?(opts, :customer_resource) or
                       Keyword.has_key?(opts, :resource) do
                    AshBilling.WebhookSync.sync_event(event, opts)
                  else
                    {:ok, :not_configured}
                  end

                return_500? = Keyword.get(opts, :return_500_on_sync_error, true)

                case sync_result do
                  {:error, reason} when return_500? ->
                    require Logger

                    Logger.error(
                      "AshBilling.Plug: Webhook synchronization failed for event #{inspect(event_id)} (#{inspect(event_type)}): #{inspect(reason)}. Returning HTTP 500 to trigger Stripe retry."
                    )

                    resp_conn =
                      conn
                      |> put_resp_content_type("application/json")
                      |> send_resp(
                        500,
                        Jason.encode!(%{
                          error: "synchronization_failed",
                          details: inspect(reason)
                        })
                      )
                      |> halt()

                    {resp_conn,
                     %{
                       status: :sync_failed,
                       event_id: event_id,
                       event_type: event_type,
                       error: reason
                     }}

                  _ ->
                    if deduplicate?, do: AshBilling.Deduplication.mark_processed(event_id, opts)

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
              end

            {:error, reason} ->
              resp_conn =
                conn
                |> put_resp_content_type("application/json")
                |> send_resp(400, Jason.encode!(%{error: to_string(reason)}))
                |> halt()

              {resp_conn, %{status: :error, error: reason}}
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

  defp read_raw_body(%{assigns: %{raw_body: body}} = conn, _opts) when is_binary(body) do
    {:ok, body, conn}
  end

  defp read_raw_body(conn, opts) do
    read_opts = Keyword.get(opts, :read_body_opts, [])

    case read_body(conn, read_opts) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, _conn} -> {:error, :body_too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_secret({module, function, args}) when is_atom(module) and is_atom(function) do
    apply(module, function, args)
  end

  defp resolve_secret(fun) when is_function(fun, 0), do: fun.()
  defp resolve_secret(secret) when is_binary(secret), do: secret
  defp resolve_secret(_), do: ""
end
