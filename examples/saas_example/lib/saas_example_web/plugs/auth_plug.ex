defmodule SaasExampleWeb.Plugs.AuthPlug do
  @moduledoc """
  Session authentication plugs that reload the current actor and `:subscriptions`
  fresh from PostgreSQL on every request so billing revocation is immediate.
  """

  import Plug.Conn
  import Phoenix.Controller

  alias SaasExample.Accounts

  def fetch_current_user(conn, _opts) do
    case get_session(conn, :user_id) do
      user_id when is_binary(user_id) ->
        case Accounts.load_fresh_actor(user_id) do
          {:ok, user} ->
            assign(conn, :current_user, user)

          {:error, _} ->
            conn
            |> delete_session(:user_id)
            |> assign(:current_user, nil)
        end

      _ ->
        assign(conn, :current_user, nil)
    end
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "Please sign in to access this page.")
      |> redirect(to: "/login")
      |> halt()
    end
  end
end
