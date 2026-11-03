defmodule AshBillingConsumer.State do
  use Agent

  def start_link(_) do
    state =
      case System.get_env("ASH_BILLING_TEST_STATE") do
        nil -> %{}
        path -> if File.exists?(path), do: Jason.decode!(File.read!(path)), else: %{}
      end

    allowed = [
      :run_id,
      :user_id,
      :customer,
      :product,
      :first_price,
      :second_price,
      :subscription_checkout,
      :subscription_id,
      :payment_checkout
    ]

    state =
      Map.new(allowed, fn key -> {key, state[Atom.to_string(key)]} end)
      |> Map.reject(fn {_, value} -> is_nil(value) end)
      |> Map.put_new(:run_id, "ashbilling_" <> String.replace(Ash.UUID.generate(), "-", ""))

    Agent.start_link(fn -> state end, name: __MODULE__)
  end
end

defmodule AshBillingConsumer.Application do
  use Application

  def start(_type, _args) do
    key = System.get_env("STRIPE_SECRET_KEY", "")

    if not String.starts_with?(key, "sk_test_"),
      do: raise("Stripe test secret key required; live mode is forbidden")

    if System.get_env("STRIPE_WEBHOOK_SECRET", "") == "",
      do: raise("Test listener signing secret required")

    {:ok, supervisor} =
      Supervisor.start_link(
        [
          AshBillingConsumer.Repo,
          AshBillingConsumer.State,
          {Bandit, plug: AshBillingConsumer.Router, ip: {127, 0, 0, 1}, port: 4089}
        ],
        strategy: :one_for_one
      )

    AshBillingConsumer.Runner.restore_policies()
    {:ok, supervisor}
  end
end

defmodule AshBillingConsumer.Remote do
  @version "2025-04-30.basil"
  def opts do
    [
      api_key: fn -> System.fetch_env!("STRIPE_SECRET_KEY") end,
      req_opts: [headers: [{"stripe-version", @version}], retry: false]
    ]
  end

  def request(method, path, params \\ %{}) do
    key = System.fetch_env!("STRIPE_SECRET_KEY")
    if not String.starts_with?(key, "sk_test_"), do: raise("Live/unknown key rejected")

    options = [
      method: method,
      url: "https://api.stripe.com" <> path,
      auth: {:bearer, key},
      headers: [{"stripe-version", @version}],
      retry: false
    ]

    options =
      if method == :get,
        do: options,
        else: Keyword.put(options, :form, AshBilling.Providers.Stripe.to_form_params(params))

    case Req.request(options) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        if body["livemode"] == true, do: raise("Live object rejected")
        body

      {:ok, %{status: status}} ->
        raise("Stripe test request failed (HTTP #{status})")

      {:error, _} ->
        raise("Stripe test transport failure")
    end
  end
end

defmodule AshBillingConsumer.Handler do
  alias AshBillingConsumer.Repo

  def handle_event(event) do
    object = event["data"]["object"] || %{}

    Repo.query!(
      "INSERT INTO handler_effects(event_id, event_type, payment_status, payload) VALUES ($1,$2,$3,$4::jsonb) ON CONFLICT (event_id) DO NOTHING",
      [event["id"], event["type"], object["payment_status"], event]
    )

    case {event["type"], Application.get_env(:ash_billing_consumer, :inject_failures, true)} do
      {"validation.error", true} -> {:error, :injected_handler_error}
      {"validation.exception", true} -> raise "injected handler exception"
      _ -> :ok
    end
  end
end

defmodule AshBillingConsumer.Router do
  use Plug.Router
  plug :match
  plug :dispatch

  forward "/webhooks/stripe",
    to: AshBilling.Plug,
    init_opts: [
      customer_resource: AshBillingConsumer.User,
      subscription_resource: AshBillingConsumer.Subscription,
      deduplication_resource: AshBillingConsumer.WebhookEvent,
      domain: AshBillingConsumer.Domain,
      handler: AshBillingConsumer.Handler,
      expected_livemode: false,
      webhook_secret: {System, :get_env, ["STRIPE_WEBHOOK_SECRET"]},
      api_key: {System, :get_env, ["STRIPE_SECRET_KEY"]}
    ]

  get "/health" do
    send_resp(conn, 200, Jason.encode!(%{ready: true, mode: "test"}))
  end

  get "/report" do
    snapshot =
      AshBillingConsumer.Runner.state() |> Jason.encode!(pretty: true) |> Plug.HTML.html_escape()

    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> send_resp(
      200,
      "<html><body><h1>AshBilling — Stripe Sandbox</h1><p>Consumer PostgreSQL state and refreshed native Ash policy results.</p><pre>" <>
        snapshot <> "</pre></body></html>"
    )
  end

  get "/state" do
    send_resp(conn, 200, Jason.encode!(AshBillingConsumer.Runner.state()))
  end

  post "/control/:operation" do
    result = AshBillingConsumer.Runner.command(operation)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(result))
  end

  get "/success" do
    send_resp(
      conn,
      200,
      "Checkout returned. Remote payment and signed webhook must still be verified."
    )
  end

  get "/cancel" do
    send_resp(conn, 200, "Checkout canceled")
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end
end
