defmodule AshBilling.Plug do
  @moduledoc """
  A Plug for receiving and verifying incoming webhooks from billing providers.

  Handlers must return `:ok`, `{:ok, value}`, or `{:error, reason}`. Unexpected
  returns and exceptions fail closed. PostgreSQL writes in the configured shared
  Repo transaction roll back on synchronization or handler failure. Leases are
  released/marked failed after rollback; HTTP responses are sent after commit.
  External effects cannot be rolled back and require event/effect idempotency.

  ## Usage in Phoenix Router

      forward "/webhooks/stripe", AshBilling.Plug,
        provider: AshBilling.Providers.Stripe,
        webhook_secret: {System, :get_env, ["STRIPE_WEBHOOK_SECRET"]},
        handler: MyApp.Billing.WebhookHandler
  """

  @behaviour Plug

  import Plug.Conn, except: [read_body: 2]

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
    case AshBilling.ResourceLock.http_boundary(transaction_resources(opts)) do
      :ok ->
        call_with_boundary(conn, opts)

      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          503,
          Jason.encode!(%{error: "transaction_boundary", details: inspect(reason)})
        )
        |> halt()
    end
  end

  defp transaction_resources(opts) do
    [
      Keyword.get(opts, :customer_resource) || Keyword.get(opts, :resource),
      Keyword.get(opts, :subscription_resource)
    ] ++ AshBilling.Deduplication.transaction_resources(opts)
  end

  defp call_with_boundary(conn, opts) do
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

                  dedup_status =
                    cond do
                      deduplicate? and (not is_binary(event_id) or event_id == "") ->
                        {:error, :invalid_event_id}

                      deduplicate? ->
                        AshBilling.Deduplication.acquire(event_id, opts)

                      true ->
                        {:ok, nil}
                    end

                  case dedup_status do
                    {:error, :already_processed} ->
                      resp_conn =
                        conn
                        |> put_resp_content_type("application/json")
                        |> send_resp(200, Jason.encode!(%{status: "already_processed"}))
                        |> halt()

                      {resp_conn,
                       %{status: :already_processed, event_id: event_id, event_type: event_type}}

                    {:error, :already_processing} ->
                      resp_conn =
                        conn
                        |> put_resp_header("retry-after", "5")
                        |> put_resp_content_type("application/json")
                        |> send_resp(
                          503,
                          Jason.encode!(%{
                            error: "already_processing",
                            message: "Event is currently being processed by another worker"
                          })
                        )
                        |> halt()

                      {resp_conn,
                       %{
                         status: :already_processing,
                         event_id: event_id,
                         event_type: event_type
                       }}

                    {:error, dedup_reason} ->
                      require Logger

                      status_code = 500

                      Logger.error(
                        "AshBilling.Plug: Failed to acquire deduplication lease for event #{inspect(event_id)} (#{inspect(event_type)}): #{inspect(dedup_reason)}. Returning HTTP #{status_code}."
                      )

                      resp_conn =
                        conn
                        |> put_resp_content_type("application/json")
                        |> send_resp(
                          status_code,
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

                    {:ok, lease_token} ->
                      result = execute_event(event, handler, lease_token, opts)

                      case result do
                        {:ok, :processed} ->
                          response =
                            conn
                            |> put_resp_content_type("application/json")
                            |> send_resp(200, ~s({"status":"received"}))
                            |> halt()

                          {response,
                           %{status: :received, event_id: event_id, event_type: event_type}}

                        {:error, reason} ->
                          failure_response(conn, event_id, event_type, lease_token, reason, opts)
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

  # PostgreSQL billing mutations and handlers share a transaction. Durable
  # completion participates in it; memory completion must wait for its COMMIT.
  defp execute_event(event, handler, token, opts) do
    event_id = event["id"]
    deduplicate? = Keyword.get(opts, :deduplicate?, true)

    durable? =
      case AshBilling.Deduplication.transaction_resources(opts) do
        [resource] -> Ash.DataLayer.data_layer(resource) == AshPostgres.DataLayer
        _ -> false
      end

    work = fn ->
      result =
        AshBilling.ResourceLock.run(
          transaction_resources(opts),
          {:webhook, event_id},
          fn ->
            with {:ok, _} <- sync_event(event, opts),
                 :ok <- run_handler(handler, event),
                 :ok <- if(durable?, do: complete_event(event_id, token, opts), else: :ok) do
              :processed
            end
          end,
          rollback_on_error?: true
        )

      case result do
        :processed when not durable? ->
          case complete_event(event_id, token, opts) do
            :ok -> :processed
            {:error, _} = error -> error
          end

        other ->
          other
      end
    end

    if deduplicate? do
      AshBilling.Deduplication.with_lease(event_id, token, opts, work)
    else
      case work.() do
        {:error, _} = error -> error
        result -> {:ok, result}
      end
    end
  rescue
    error -> {:error, {:processing_exception, error}}
  end

  defp sync_event(event, opts) do
    if Enum.any?(
         [:subscription_resource, :customer_resource, :resource],
         &Keyword.has_key?(opts, &1)
       ) do
      AshBilling.WebhookSync.sync_event(event, opts)
    else
      {:ok, :not_configured}
    end
  end

  defp run_handler(handler, event) do
    case invoke_handler(handler, event) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:handler_failed, reason}}
      other -> {:error, {:handler_failed, {:invalid_handler_return, other}}}
    end
  end

  defp complete_event(event_id, token, opts) do
    if Keyword.get(opts, :deduplicate?, true) do
      case AshBilling.Deduplication.complete(event_id, [lease_token: token] ++ opts) do
        :ok -> :ok
        {:error, reason} -> {:error, {:completion_failed, reason}}
      end
    else
      :ok
    end
  end

  defp failure_response(conn, event_id, event_type, token, reason, opts) do
    busy? = reason in [:already_processed, :already_processing, :lease_token_mismatch]

    release =
      if Keyword.get(opts, :deduplicate?, true) and not busy?,
        do: release_after_failure(event_id, token, reason, opts),
        else: :ok

    {kind, detail} =
      case reason do
        {:handler_failed, detail} -> {:handler_failed, detail}
        {:completion_failed, detail} -> {:completion_failed, detail}
        _ when busy? -> {:lease_not_owned, reason}
        _ -> {:synchronization_failed, reason}
      end

    # Acknowledgment opt-out applies only to business failures, after rollback
    # AND successful failure recording. Infrastructure failures always retry.
    status =
      cond do
        reason == :already_processed -> 200
        busy? -> 503
        release != :ok -> 500
        kind == :completion_failed -> 500
        match?({:transaction_failed, _}, reason) -> 500
        match?({:processing_exception, _}, reason) -> 500
        match?({:invalid_webhook_handler, _}, detail) -> 500
        match?({:invalid_handler_return, _}, detail) -> 500
        match?({:handler_exception, _}, detail) -> 500
        Keyword.get(opts, :return_500_on_sync_error, true) -> 500
        true -> 200
      end

    require Logger

    Logger.error(
      "AshBilling.Plug: event #{inspect(event_id)} failed: #{inspect(reason)}. " <>
        if(status == 500,
          do: "Returning HTTP 500 to trigger Stripe retry.",
          else: "Returning HTTP #{status}."
        )
    )

    response =
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(%{error: kind, details: inspect(detail)}))
      |> halt()

    telemetry_status = if kind == :synchronization_failed, do: :sync_failed, else: kind

    {response,
     %{status: telemetry_status, event_id: event_id, event_type: event_type, error: detail}}
  end

  defp release_after_failure(event_id, token, reason, opts) do
    case AshBilling.Deduplication.release(event_id, [lease_token: token, error: reason] ++ opts) do
      :ok ->
        :ok

      {:error, release_reason} ->
        require Logger

        Logger.error(
          "AshBilling.Plug: lease cleanup failed after transaction failure: #{inspect(release_reason)}"
        )

        # A failed cleanup COMMIT must still produce 5xx. Make one bounded
        # cleanup attempt for transient transaction failures to allow prompt retry.
        if match?({:transaction_failed, _}, release_reason) do
          AshBilling.Deduplication.release(event_id, [lease_token: token, error: reason] ++ opts)
        end

        {:error, release_reason}
    end
  end

  defp invoke_handler(nil, _event), do: :ok

  defp invoke_handler(handler, event) when is_atom(handler) do
    with {:module, _} <- Code.ensure_loaded(handler),
         true <- function_exported?(handler, :handle_event, 1) do
      handler.handle_event(event)
    else
      _ -> {:error, {:invalid_webhook_handler, handler}}
    end
  rescue
    error -> {:error, {:handler_exception, error}}
  catch
    kind, reason -> {:error, {:handler_exception, {kind, reason}}}
  end

  defp invoke_handler(handler, _event), do: {:error, {:invalid_webhook_handler, handler}}

  @doc """
  A `Plug.Parsers` body reader that preserves the exact signed request bytes in
  `conn.assigns[:raw_body]`, including bodies delivered in multiple chunks.

      plug Plug.Parsers,
        parsers: [:json],
        json_decoder: Jason,
        body_reader: {AshBilling.Plug, :read_body, []}
  """
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {status, body, conn} when status in [:ok, :more] ->
        raw_body = Map.get(conn.assigns, :raw_body, "") <> body
        {status, body, assign(conn, :raw_body, raw_body)}

      error ->
        error
    end
  end

  defp read_raw_body(%{assigns: %{raw_body: body}} = conn, _opts) when is_binary(body) do
    {:ok, body, conn}
  end

  defp read_raw_body(conn, opts) do
    read_opts = Keyword.get(opts, :read_body_opts, [])

    case Plug.Conn.read_body(conn, read_opts) do
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
