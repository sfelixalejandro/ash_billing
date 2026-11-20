defmodule SaasExampleWeb.PageHTML do
  @moduledoc """
  Clean server-rendered HTML views for authentication and the SaaS billing dashboard.
  Uses `Phoenix.HTML.html_escape/1` for all dynamic values to prevent XSS.
  """

  alias SaasExample.Billing.Catalog

  def login(conn) do
    csrf = Phoenix.Controller.get_csrf_token()

    layout("Sign In — AshBilling SaaS", conn, """
    <section class="card">
      <h1>Sign In</h1>
      <form method="post" action="/login">
        <input type="hidden" name="_csrf_token" value="#{esc(csrf)}" />
        <label>Email <input type="email" name="email" required /></label>
        <label>Password <input type="password" name="password" required /></label>
        <button type="submit">Sign In</button>
      </form>
      <p>New here? <a href="/register">Create an account</a></p>
      <p class="hint">Demo accounts (after <code>mix ecto.setup</code>, password <code>password1234</code>):
        <code>free@example.com</code>, <code>starter@example.com</code>, <code>pro@example.com</code>, <code>enterprise@example.com</code>
      </p>
    </section>
    """)
  end

  def register(conn) do
    csrf = Phoenix.Controller.get_csrf_token()

    layout("Register — AshBilling SaaS", conn, """
    <section class="card">
      <h1>Create Account</h1>
      <form method="post" action="/register">
        <input type="hidden" name="_csrf_token" value="#{esc(csrf)}" />
        <label>Name <input type="text" name="name" required /></label>
        <label>Email <input type="email" name="email" required /></label>
        <label>Password (min 8 chars) <input type="password" name="password" minlength="8" required /></label>
        <button type="submit">Create Account</button>
      </form>
      <p>Already registered? <a href="/login">Sign in</a></p>
    </section>
    """)
  end

  def dashboard(conn, %{
        user: user,
        subscription: sub,
        subscribed?: subscribed?,
        plans: plans,
        seats: seats,
        reports: reports
      }) do
    csrf = Phoenix.Controller.get_csrf_token()

    plan_cards =
      Enum.map_join(plans, "\n", fn plan ->
        """
        <div class="plan-card">
          <h3>#{esc(plan.name)}</h3>
          <p class="price">#{esc(plan.price_display)}</p>
          <p>#{esc(plan.description)}</p>
          <form method="post" action="/billing/checkout">
            <input type="hidden" name="_csrf_token" value="#{esc(csrf)}" />
            <input type="hidden" name="plan" value="#{esc(plan.slug)}" />
            <label>Seats <input type="number" name="quantity" value="1" min="1" /></label>
            <button type="submit">Subscribe (#{esc(plan.name)})</button>
          </form>
        </div>
        """
      end)

    sub_section =
      if sub do
        swap_buttons =
          Enum.map_join(plans, "\n", fn plan ->
            if plan.price_id == sub.price_id do
              "<span class=\"badge\">Current: #{esc(plan.name)}</span>"
            else
              """
              <form method="post" action="/billing/swap-plan" class="inline">
                <input type="hidden" name="_csrf_token" value="#{esc(csrf)}" />
                <input type="hidden" name="subscription_id" value="#{esc(sub.id)}" />
                <input type="hidden" name="plan" value="#{esc(plan.slug)}" />
                <button type="submit">Switch to #{esc(plan.name)}</button>
              </form>
              """
            end
          end)

        cancel_or_resume =
          if sub.cancel_at_period_end do
            """
            <form method="post" action="/billing/resume" class="inline">
              <input type="hidden" name="_csrf_token" value="#{esc(csrf)}" />
              <input type="hidden" name="subscription_id" value="#{esc(sub.id)}" />
              <button type="submit">Resume Subscription</button>
            </form>
            """
          else
            """
            <form method="post" action="/billing/cancel" class="inline">
              <input type="hidden" name="_csrf_token" value="#{esc(csrf)}" />
              <input type="hidden" name="subscription_id" value="#{esc(sub.id)}" />
              <button type="submit" class="danger">Cancel at Period End</button>
            </form>
            """
          end

        """
        <section class="card">
          <h2>Active Subscription</h2>
          <ul>
            <li><strong>Plan:</strong> #{esc(Catalog.plan_name_for_price(sub.price_id))} (<code>#{esc(sub.price_id || "none")}</code>)</li>
            <li><strong>Status:</strong> #{esc(to_string(sub.status))} (active access: #{esc(to_string(subscribed?))})</li>
            <li><strong>Contracted Seats (quantity):</strong> #{esc(if(is_nil(sub.quantity), do: "unset", else: Integer.to_string(sub.quantity)))} (used: #{length(seats)})</li>
            <li><strong>Cancel at period end:</strong> #{esc(to_string(sub.cancel_at_period_end))}</li>
            <li><strong>Last reconciled at:</strong> #{esc(if(sub.last_reconciled_at, do: DateTime.to_iso8601(sub.last_reconciled_at), else: "never"))}</li>
          </ul>
          <div class="actions">
            <form method="post" action="/billing/portal" class="inline">
              <input type="hidden" name="_csrf_token" value="#{esc(csrf)}" />
              <button type="submit">Open Stripe Billing Portal</button>
            </form>
            <form method="post" action="/billing/reconcile" class="inline">
              <input type="hidden" name="_csrf_token" value="#{esc(csrf)}" />
              <input type="hidden" name="subscription_id" value="#{esc(sub.id)}" />
              <button type="submit">Reconcile with Stripe</button>
            </form>
            #{cancel_or_resume}
          </div>
          <h3>Swap Plan</h3>
          <div class="actions">#{swap_buttons}</div>
          <h3>Update Seat Quantity</h3>
          <form method="post" action="/billing/quantity" class="inline">
            <input type="hidden" name="_csrf_token" value="#{esc(csrf)}" />
            <input type="hidden" name="subscription_id" value="#{esc(sub.id)}" />
            <input type="number" name="quantity" value="#{esc(to_string(sub.quantity || 1))}" min="1" required />
            <button type="submit">Update Seats</button>
          </form>
        </section>
        """
      else
        """
        <section class="card">
          <h2>Choose a Plan</h2>
          <p>No active subscription yet. Start a Stripe Test Mode Checkout session below.</p>
          <div class="grid">#{plan_cards}</div>
        </section>
        """
      end

    seats_list =
      Enum.map_join(seats, "\n", fn seat ->
        """
        <li>
          #{esc(to_string(seat.member_email))}
          <form method="post" action="/workspace/seats/#{esc(seat.id)}" class="inline">
            <input type="hidden" name="_csrf_token" value="#{esc(csrf)}" />
            <input type="hidden" name="_method" value="delete" />
            <button type="submit" class="danger">Revoke</button>
          </form>
        </li>
        """
      end)

    reports_list =
      Enum.map_join(reports, "\n", fn report ->
        """
        <li>
          <strong>#{esc(report.title)}</strong>
          #{if report.exported_at, do: " [Exported]", else: ""}
          #{if report.audited_at, do: " [Enterprise Audited]", else: ""}
          <form method="post" action="/workspace/reports/#{esc(report.id)}/export" class="inline">
            <input type="hidden" name="_csrf_token" value="#{esc(csrf)}" />
            <button type="submit">Pro Export (HasPrice)</button>
          </form>
          <form method="post" action="/workspace/reports/#{esc(report.id)}/audit" class="inline">
            <input type="hidden" name="_csrf_token" value="#{esc(csrf)}" />
            <button type="submit">Enterprise Audit (HasPrice)</button>
          </form>
        </li>
        """
      end)

    layout("Dashboard — AshBilling SaaS", conn, """
    <header class="topbar">
      <div><strong>AshBilling SaaS Reference App</strong> — #{esc(user.name)} (#{esc(to_string(user.email))})</div>
      <form method="post" action="/logout" class="inline">
        <input type="hidden" name="_csrf_token" value="#{esc(csrf)}" />
        <input type="hidden" name="_method" value="delete" />
        <button type="submit">Sign Out</button>
      </form>
    </header>
    #{sub_section}
    <section class="card">
      <h2>Team Seats (<code>AshBilling.Checks.Subscribed</code> + <code>quantity</code> Enforcement)</h2>
      <form method="post" action="/workspace/seats" class="inline">
        <input type="hidden" name="_csrf_token" value="#{esc(csrf)}" />
        <input type="email" name="member_email" placeholder="teammate@company.com" required />
        <button type="submit">Assign Seat</button>
      </form>
      <ul>#{seats_list}</ul>
    </section>
    <section class="card">
      <h2>Workspace Reports (<code>Subscribed</code> &amp; <code>HasPrice</code> Policies)</h2>
      <form method="post" action="/workspace/reports" class="inline">
        <input type="hidden" name="_csrf_token" value="#{esc(csrf)}" />
        <input type="text" name="title" placeholder="Quarterly Metrics" required />
        <button type="submit">Create Report</button>
      </form>
      <ul>#{reports_list}</ul>
    </section>
    """)
  end

  defp layout(title, conn, body) do
    info = Phoenix.Flash.get(conn.assigns[:flash] || %{}, :info)
    error = Phoenix.Flash.get(conn.assigns[:flash] || %{}, :error)

    flashes =
      [
        if(info, do: "<div class=\"flash info\">#{esc(info)}</div>"),
        if(error, do: "<div class=\"flash error\">#{esc(error)}</div>")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <title>#{esc(title)}</title>
      <style>
        body { font-family: system-ui, sans-serif; max-width: 960px; margin: 2rem auto; padding: 0 1rem; color: #1f2937; }
        .topbar { display: flex; justify-content: space-between; align-items: center; margin-bottom: 1.5rem; }
        .card { border: 1px solid #d1d5db; border-radius: 8px; padding: 1.25rem; margin-bottom: 1.25rem; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 1rem; }
        .plan-card { border: 1px solid #e5e7eb; border-radius: 6px; padding: 1rem; }
        .flash { padding: 0.75rem 1rem; border-radius: 6px; margin-bottom: 1rem; }
        .flash.info { background: #dcfce7; color: #166534; }
        .flash.error { background: #fee2e2; color: #991b1b; }
        .inline { display: inline-block; margin-right: 0.5rem; }
        button { padding: 0.4rem 0.8rem; cursor: pointer; }
        button.danger { background: #fee2e2; border: 1px solid #ef4444; color: #991b1b; }
        label { display: block; margin-bottom: 0.5rem; }
      </style>
    </head>
    <body>
      #{flashes}
      #{body}
    </body>
    </html>
    """
  end

  defp esc(val) do
    val |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end
end
