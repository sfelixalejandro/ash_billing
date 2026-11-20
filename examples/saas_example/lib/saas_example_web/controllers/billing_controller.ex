defmodule SaasExampleWeb.BillingController do
  use SaasExampleWeb, :controller

  alias SaasExample.Billing

  def checkout(conn, params) do
    user = conn.assigns.current_user
    plan = Map.get(params, "plan", "")
    quantity = parse_positive_int(Map.get(params, "quantity", "1"))

    base_url = SaasExampleWeb.Endpoint.url()

    case Billing.start_checkout(user, plan, quantity,
           success_url: "#{base_url}/dashboard?billing=success",
           cancel_url: "#{base_url}/dashboard?billing=canceled"
         ) do
      {:ok, %{url: checkout_url}} when is_binary(checkout_url) ->
        redirect(conn, external: checkout_url)

      {:error, :unknown_plan} ->
        conn
        |> put_flash(:error, "Selected plan is not in the server billing catalog.")
        |> redirect(to: "/dashboard")

      {:error, :invalid_quantity} ->
        conn
        |> put_flash(:error, "Quantity must be a positive integer.")
        |> redirect(to: "/dashboard")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Unable to initiate Stripe Checkout. Please try again.")
        |> redirect(to: "/dashboard")
    end
  end

  def portal(conn, _params) do
    user = conn.assigns.current_user
    return_url = "#{SaasExampleWeb.Endpoint.url()}/dashboard"

    case Billing.open_portal(user, return_url) do
      {:ok, %{url: portal_url}} when is_binary(portal_url) ->
        redirect(conn, external: portal_url)

      {:error, :no_stripe_customer} ->
        conn
        |> put_flash(:error, "Start a subscription first to access the Stripe Billing Portal.")
        |> redirect(to: "/dashboard")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Unable to open Stripe Billing Portal.")
        |> redirect(to: "/dashboard")
    end
  end

  def swap_plan(conn, %{"subscription_id" => sub_id, "plan" => plan}) do
    user = conn.assigns.current_user

    case Billing.swap_plan(user, sub_id, plan) do
      {:ok, _remote} ->
        conn
        |> put_flash(
          :info,
          "Plan swap requested in Stripe. Local state will sync via webhook or Reconcile."
        )
        |> redirect(to: "/dashboard")

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "Subscription not found.")
        |> redirect(to: "/dashboard")

      {:error, :unknown_plan} ->
        conn
        |> put_flash(:error, "Requested plan is not in the server catalog.")
        |> redirect(to: "/dashboard")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Failed to swap subscription plan with Stripe.")
        |> redirect(to: "/dashboard")
    end
  end

  def update_quantity(conn, %{"subscription_id" => sub_id, "quantity" => qty_param}) do
    user = conn.assigns.current_user
    quantity = parse_positive_int(qty_param)

    case Billing.update_quantity(user, sub_id, quantity) do
      {:ok, _remote} ->
        conn
        |> put_flash(
          :info,
          "Seat quantity updated in Stripe to #{quantity}. Local state syncs via webhook or Reconcile."
        )
        |> redirect(to: "/dashboard")

      {:error, {:seats_exceed_new_quantity, active_seats}} ->
        conn
        |> put_flash(
          :error,
          "Cannot reduce contracted seats below #{active_seats} active workspace seat(s). Revoke seats first."
        )
        |> redirect(to: "/dashboard")

      {:error, :invalid_quantity} ->
        conn
        |> put_flash(:error, "Quantity must be a positive integer.")
        |> redirect(to: "/dashboard")

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "Subscription not found.")
        |> redirect(to: "/dashboard")

      {:error, {:price_mismatch, _actual}} ->
        conn
        |> put_flash(
          :error,
          "Plan changed concurrently in Stripe. Reconcile before updating seats."
        )
        |> redirect(to: "/dashboard")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Failed to update seat quantity with Stripe.")
        |> redirect(to: "/dashboard")
    end
  end

  def cancel(conn, %{"subscription_id" => sub_id}) do
    user = conn.assigns.current_user

    case Billing.cancel_subscription(user, sub_id, at_period_end: true) do
      {:ok, _remote} ->
        conn
        |> put_flash(:info, "Subscription scheduled to cancel at period end.")
        |> redirect(to: "/dashboard")

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "Subscription not found.")
        |> redirect(to: "/dashboard")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Failed to schedule subscription cancellation.")
        |> redirect(to: "/dashboard")
    end
  end

  def resume(conn, %{"subscription_id" => sub_id}) do
    user = conn.assigns.current_user

    case Billing.resume_subscription(user, sub_id) do
      {:ok, _remote} ->
        conn
        |> put_flash(:info, "Subscription resumed in Stripe.")
        |> redirect(to: "/dashboard")

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "Subscription not found.")
        |> redirect(to: "/dashboard")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Failed to resume subscription.")
        |> redirect(to: "/dashboard")
    end
  end

  def reconcile(conn, %{"subscription_id" => sub_id}) do
    user = conn.assigns.current_user

    case Billing.reconcile_user_subscription(user, sub_id) do
      {:ok, _updated} ->
        conn
        |> put_flash(:info, "Subscription reconciled authoritatively against Stripe.")
        |> redirect(to: "/dashboard")

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "Subscription not found.")
        |> redirect(to: "/dashboard")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Reconciliation failed against Stripe; local state preserved.")
        |> redirect(to: "/dashboard")
    end
  end

  defp parse_positive_int(val) when is_integer(val) and val > 0, do: val

  defp parse_positive_int(val) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {n, ""} when n > 0 -> n
      _ -> :invalid
    end
  end

  defp parse_positive_int(_), do: :invalid
end
