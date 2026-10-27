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
    handler = Keyword.get(opts, :handler)

    case resolve_secret(Keyword.get(opts, :webhook_secret)) do
      {:error, :missing_webhook_secret} ->
        require Logger

        Logger.error(
          "AshBilling.Plug: Webhook secret is not configured or is empty. Rejecting incoming webhook to prevent unauthorized access."
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(%{error: "unconfigured_webhook_secret"}))
        |> halt()

      {:ok, secret} ->
        :telemetry.span([:ash_billing, :webhook], %{conn: conn, provider: provider}, fn ->
          case read_raw_body(conn, opts) do
            {:ok, raw_body, conn} ->
              signature_header = get_req_header(conn, "stripe-signature") |> List.first()

              case provider.verify_webhook(raw_body, signature_header, secret, opts) do
                {:ok, event} ->
                  event_id = Map.get(event, "id")
                  event_type = Map.get(event, "type")
                  deduplicate? = Keyword.get(opts, :deduplicate?, true)
                  return_500? = Keyword.get(opts, :return_500_on_sync_error, true)

                  dedup_status =
                    if deduplicate? do
                      AshBilling.Deduplication.acquire(event_id, opts)
                    else
                      {:ok, :acquired}
                    end

                  case dedup_status do
                    {:error, already} when already in [:already_processed, :already_processing] ->
                      resp_conn =
                        conn
                        |> put_resp_content_type("application/json")
                        |> send_resp(200, Jason.encode!(%{status: to_string(already)}))
                        |> halt()

                      {resp_conn, %{status: already, event_id: event_id, event_type: event_type}}

                    {:error, dedup_reason} when return_500? ->
                      require Logger

                      Logger.error(
                        "AshBilling.Plug: Failed to acquire deduplication lease for event #{inspect(event_id)} (#{inspect(event_type)}): #{inspect(dedup_reason)}. Returning HTTP 500."
                      )

                      resp_conn =
                        conn
                        |> put_resp_content_type("application/json")
                        |> send_resp(
                          500,
                          Jason.encode!(%{
                            error: "deduplication_failed",
                            details: inspect(dedup_reason)
                          })
                        )
                        |> halt()

                      {resp_conn,
                       %{
                         status: :dedup_failed,
                         event_id: event_id,
                         event_type: event_type,
                         error: dedup_reason
                       }}

                    {:ok, :acquired} ->
                      sync_result =
                        if Keyword.has_key?(opts, :subscription_resource) or
                             Keyword.has_key?(opts, :customer_resource) or
                             Keyword.has_key?(opts, :resource) do
                          AshBilling.WebhookSync.sync_event(event, opts)
                        else
                          {:ok, :not_configured}
                        end

                      case sync_result do
                        {:error, reason} when return_500? ->
                          require Logger

                          Logger.error(
                            "AshBilling.Plug: Webhook synchronization failed for event #{inspect(event_id)} (#{inspect(event_type)}): #{inspect(reason)}. Releasing lease. Returning HTTP 500 to trigger Stripe retry."
                          )

                          if deduplicate? do
                            AshBilling.Deduplication.release(event_id, [error: reason] ++ opts)
                          end

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
                          handler_result =
                            if is_atom(handler) and function_exported?(handler, :handle_event, 1) do
                              try do
                                handler.handle_event(event)
                              rescue
                                e -> {:error, e}
                              catch
                                kind, reason -> {:error, {kind, reason}}
                              end
                            else
                              :ok
                            end

                          case handler_result do
                            {:error, handler_reason} when return_500? ->
                              require Logger

                              Logger.error(
                                "AshBilling.Plug: Custom handler #{inspect(handler)} failed for event #{inspect(event_id)} (#{inspect(event_type)}): #{inspect(handler_reason)}. Releasing lease and returning HTTP 500 to trigger retry."
                              )

                              if deduplicate? do
                                AshBilling.Deduplication.release(
                                  event_id,
                                  [error: handler_reason] ++ opts
                                )
                              end

                              resp_conn =
                                conn
                                |> put_resp_content_type("application/json")
                                |> send_resp(
                                  500,
                                  Jason.encode!(%{
                                    error: "handler_failed",
                                    details: inspect(handler_reason)
                                  })
                                )
                                |> halt()

                              {resp_conn,
                               %{
                                 status: :handler_failed,
                                 event_id: event_id,
                                 event_type: event_type,
                                 error: handler_reason
                               }}

                            _ ->
                              if deduplicate?,
                                do: AshBilling.Deduplication.complete(event_id, opts)

                              resp_conn =
                                conn
                                |> put_resp_content_type("application/json")
                                |> send_resp(200, ~s({"status":"received"}))
                                |> halt()

                              {resp_conn,
                               %{status: :received, event_id: event_id, event_type: event_type}}
                          end
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
    case apply(module, function, args) do
      secret when is_binary(secret) and byte_size(secret) > 0 -> {:ok, secret}
      _ -> {:error, :missing_webhook_secret}
    end
  rescue
    _ -> {:error, :missing_webhook_secret}
  end

  defp resolve_secret(fun) when is_function(fun, 0) do
    case fun.() do
      secret when is_binary(secret) and byte_size(secret) > 0 -> {:ok, secret}
      _ -> {:error, :missing_webhook_secret}
    end
  rescue
    _ -> {:error, :missing_webhook_secret}
  end

  defp resolve_secret(secret) when is_binary(secret) and byte_size(secret) > 0, do: {:ok, secret}
  defp resolve_secret(_), do: {:error, :missing_webhook_secret}
end
