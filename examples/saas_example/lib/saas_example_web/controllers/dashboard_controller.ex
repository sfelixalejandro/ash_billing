defmodule SaasExampleWeb.DashboardController do
  use SaasExampleWeb, :controller

  alias SaasExample.{Billing, Workspace}
  alias SaasExample.Billing.Catalog
  alias SaasExampleWeb.PageHTML

  def index(conn, _params) do
    if conn.assigns[:current_user] do
      redirect(conn, to: "/dashboard")
    else
      redirect(conn, to: "/login")
    end
  end

  def show(conn, _params) do
    user = conn.assigns.current_user
    subscription = Billing.primary_subscription(user)
    subscribed? = AshBilling.subscribed?(user)

    seats =
      case Workspace.list_seats(user) do
        {:ok, list} -> list
        {:error, _} -> []
      end

    reports =
      case Workspace.list_reports(user) do
        {:ok, list} -> list
        {:error, _} -> []
      end

    html(
      conn,
      PageHTML.dashboard(conn, %{
        user: user,
        subscription: subscription,
        subscribed?: subscribed?,
        plans: Catalog.plans(),
        seats: seats,
        reports: reports
      })
    )
  end
end
