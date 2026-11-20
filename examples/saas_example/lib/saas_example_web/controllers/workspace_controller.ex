defmodule SaasExampleWeb.WorkspaceController do
  use SaasExampleWeb, :controller

  alias SaasExample.Workspace

  def assign_seat(conn, %{"member_email" => member_email}) do
    user = conn.assigns.current_user

    case Workspace.assign_seat(user, member_email) do
      {:ok, _seat} ->
        conn
        |> put_flash(:info, "Seat assigned to #{member_email}.")
        |> redirect(to: "/dashboard")

      {:error, {:seat_limit_reached, used, limit}} ->
        conn
        |> put_flash(
          :error,
          "Seat limit reached (#{used}/#{limit}). Increase subscription quantity to invite more members."
        )
        |> redirect(to: "/dashboard")

      {:error, :no_contracted_seats} ->
        conn
        |> put_flash(:error, "Subscription has no contracted seats (quantity is nil or 0).")
        |> redirect(to: "/dashboard")

      {:error, :subscription_required} ->
        conn
        |> put_flash(:error, "An active subscription is required to assign seats.")
        |> redirect(to: "/dashboard")

      {:error, :invalid_member_email} ->
        conn
        |> put_flash(:error, "Please enter a valid teammate email address.")
        |> redirect(to: "/dashboard")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Unable to assign seat (duplicate email or unauthorized).")
        |> redirect(to: "/dashboard")
    end
  end

  def revoke_seat(conn, %{"id" => seat_id}) do
    user = conn.assigns.current_user

    case Workspace.revoke_seat(user, seat_id) do
      {:ok, _seat} ->
        conn
        |> put_flash(:info, "Seat revoked.")
        |> redirect(to: "/dashboard")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Unable to revoke seat.")
        |> redirect(to: "/dashboard")
    end
  end

  def create_report(conn, params) do
    user = conn.assigns.current_user

    case Workspace.create_report(user, params) do
      {:ok, _report} ->
        conn
        |> put_flash(:info, "Report created.")
        |> redirect(to: "/dashboard")

      {:error, :invalid_title} ->
        conn
        |> put_flash(:error, "Report title is required.")
        |> redirect(to: "/dashboard")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Active subscription required to create workspace reports.")
        |> redirect(to: "/dashboard")
    end
  end

  def export_report(conn, %{"id" => report_id}) do
    user = conn.assigns.current_user

    case Workspace.export_report(user, report_id) do
      {:ok, _report} ->
        conn
        |> put_flash(:info, "Pro/Enterprise analytics export completed.")
        |> redirect(to: "/dashboard")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Forbidden: Pro or Enterprise plan required to export analytics.")
        |> redirect(to: "/dashboard")
    end
  end

  def audit_report(conn, %{"id" => report_id}) do
    user = conn.assigns.current_user

    case Workspace.audit_report(user, report_id) do
      {:ok, _report} ->
        conn
        |> put_flash(:info, "Enterprise compliance audit recorded.")
        |> redirect(to: "/dashboard")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Forbidden: Enterprise plan required for compliance audits.")
        |> redirect(to: "/dashboard")
    end
  end
end
