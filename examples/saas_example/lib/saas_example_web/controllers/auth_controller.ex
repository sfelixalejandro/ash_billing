defmodule SaasExampleWeb.AuthController do
  use SaasExampleWeb, :controller

  alias SaasExample.Accounts
  alias SaasExampleWeb.PageHTML

  def new_registration(conn, _params) do
    html(conn, PageHTML.register(conn))
  end

  def register(conn, params) do
    case Accounts.register_user(params) do
      {:ok, user} ->
        conn
        |> configure_session(renew: true)
        |> put_session(:user_id, user.id)
        |> put_flash(:info, "Account created! Choose a plan to unlock workspace features.")
        |> redirect(to: "/dashboard")

      {:error, reason} ->
        conn =
          conn
          |> put_status(422)
          |> put_flash(:error, format_auth_error(reason))

        html(conn, PageHTML.register(conn))
    end
  end

  def new_session(conn, _params) do
    html(conn, PageHTML.login(conn))
  end

  def login(conn, %{"email" => email, "password" => password}) do
    case Accounts.authenticate_user(email, password) do
      {:ok, user} ->
        conn
        |> configure_session(renew: true)
        |> put_session(:user_id, user.id)
        |> put_flash(:info, "Signed in as #{user.email}.")
        |> redirect(to: "/dashboard")

      {:error, :invalid_credentials} ->
        conn =
          conn
          |> put_status(401)
          |> put_flash(:error, "Invalid email or password.")

        html(conn, PageHTML.login(conn))
    end
  end

  def login(conn, _params) do
    conn =
      conn
      |> put_status(401)
      |> put_flash(:error, "Invalid email or password.")

    html(conn, PageHTML.login(conn))
  end

  def logout(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: "/login")
  end

  defp format_auth_error(:invalid_email), do: "Please provide a valid email address."
  defp format_auth_error(:invalid_name), do: "Please provide your name."
  defp format_auth_error(:password_too_short), do: "Password must be at least 8 characters."
  defp format_auth_error(_), do: "Unable to create account (email may already be registered)."
end
