defmodule SaasExampleWeb.HealthController do
  use SaasExampleWeb, :controller

  alias SaasExample.Repo

  def index(conn, _params) do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", []) do
      {:ok, _} ->
        json(conn, %{status: "ok", database: "connected"})

      {:error, _reason} ->
        conn
        |> put_status(503)
        |> json(%{status: "error", database: "unavailable"})
    end
  end
end
