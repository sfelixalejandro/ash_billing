defmodule SaasExampleWeb do
  @moduledoc false

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      import Plug.Conn
      alias SaasExampleWeb.Router
    end
  end

  def html do
    quote do
      import Phoenix.HTML
      import Phoenix.HTML.Form
      import Phoenix.Controller, only: [get_csrf_token: 0]
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
