defmodule SaasExampleWeb.Router do
  use SaasExampleWeb, :router

  import SaasExampleWeb.Plugs.AuthPlug

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  pipeline :require_auth do
    plug :require_authenticated_user
  end

  # Public health & signed Stripe webhook endpoint (no CSRF / session cookies)
  get "/health", SaasExampleWeb.HealthController, :index
  forward "/webhooks/stripe", SaasExampleWeb.Plugs.StripeWebhookPlug

  scope "/", SaasExampleWeb do
    pipe_through :browser

    get "/", DashboardController, :index
    get "/register", AuthController, :new_registration
    post "/register", AuthController, :register
    get "/login", AuthController, :new_session
    post "/login", AuthController, :login
    delete "/logout", AuthController, :logout
  end

  scope "/", SaasExampleWeb do
    pipe_through [:browser, :require_auth]

    get "/dashboard", DashboardController, :show

    post "/billing/checkout", BillingController, :checkout
    post "/billing/portal", BillingController, :portal
    post "/billing/swap-plan", BillingController, :swap_plan
    post "/billing/quantity", BillingController, :update_quantity
    post "/billing/cancel", BillingController, :cancel
    post "/billing/resume", BillingController, :resume
    post "/billing/reconcile", BillingController, :reconcile

    post "/workspace/seats", WorkspaceController, :assign_seat
    delete "/workspace/seats/:id", WorkspaceController, :revoke_seat
    post "/workspace/reports", WorkspaceController, :create_report
    post "/workspace/reports/:id/export", WorkspaceController, :export_report
    post "/workspace/reports/:id/audit", WorkspaceController, :audit_report
  end
end
