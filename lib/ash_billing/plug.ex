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

    {:ok, raw_body, conn} = read_raw_body(conn)
    signature_header = get_req_header(conn, "stripe-signature") |> List.first()

    case provider.verify_webhook(raw_body, signature_header, secret, opts) do
      {:ok, event} ->
        if is_atom(handler) and function_exported?(handler, :handle_event, 1) do
          handler.handle_event(event)
        end

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, ~s({"status":"received"}))
        |> halt()

      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: to_string(reason)}))
        |> halt()
    end
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
