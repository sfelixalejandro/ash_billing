defmodule SaasExample.Workspace do
  @moduledoc """
  Workspace Ash domain managing team seats (enforcing contracted `subscription.quantity`
  under PostgreSQL row locks) and tier-gated reports (`Subscribed` & `HasPrice`).
  """
  use Ash.Domain, otp_app: :saas_example

  require Ash.Query

  alias SaasExample.Accounts
  alias SaasExample.Accounts.User
  alias SaasExample.Repo
  alias SaasExample.Workspace.{Report, Seat}

  resources do
    resource SaasExample.Workspace.Seat
    resource SaasExample.Workspace.Report
  end

  @doc """
  Lists active seats owned by the actor (authorized via `Subscribed` + owner policy).
  """
  @spec list_seats(User.t()) :: {:ok, [Seat.t()]} | {:error, term()}
  def list_seats(%User{} = actor) do
    Seat
    |> Ash.Query.filter(status == :active)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read(domain: __MODULE__, actor: actor, authorize?: true)
  end

  @doc """
  Counts currently active seats for an account owner.
  """
  @spec active_seat_count(User.t()) :: non_neg_integer()
  def active_seat_count(%User{id: owner_id}) do
    Seat
    |> Ash.Query.filter(owner_id == ^owner_id and status == :active)
    |> Ash.count!(domain: __MODULE__, authorize?: false)
  end

  @doc """
  Assigns a new workspace seat inside a PostgreSQL transaction serialized by a
  `FOR UPDATE` lock on the owner's row, preventing concurrent requests (including
  concurrent `SaasExample.Billing.update_quantity/4` reductions) from exceeding
  `subscription.quantity`.
  """
  @spec assign_seat(User.t(), String.t(), keyword()) :: {:ok, Seat.t()} | {:error, term()}
  def assign_seat(actor, member_email, opts \\ [])

  def assign_seat(%User{id: owner_id}, member_email, opts) when is_binary(member_email) do
    email = String.trim(member_email)

    if email == "" or not String.contains?(email, "@") do
      {:error, :invalid_member_email}
    else
      case Repo.transaction(fn ->
             # Canonical row lock on the owner (users) matches Billing.update_quantity/4,
             # AshBilling.WebhookSync, and AshBilling.reconcile_subscription/2
             Repo.query!("SELECT id FROM users WHERE id = $1 FOR UPDATE", [
               Ecto.UUID.dump!(owner_id)
             ])

             if on_locked = Keyword.get(opts, :on_locked) do
               on_locked.()
             end

             with {:ok, fresh_actor} <- Accounts.load_fresh_actor(owner_id),
                  :ok <- verify_seat_capacity(fresh_actor),
                  {:ok, seat} <-
                    Seat
                    |> Ash.Changeset.for_create(:assign, %{member_email: email},
                      actor: fresh_actor
                    )
                    |> Ash.create(domain: __MODULE__, actor: fresh_actor, authorize?: true) do
               seat
             else
               {:error, reason} -> Repo.rollback(reason)
             end
           end) do
        {:ok, seat} -> {:ok, seat}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def assign_seat(_, _, _), do: {:error, :invalid_member_email}

  @doc """
  Revokes an owned active seat, immediately freeing capacity.
  """
  @spec revoke_seat(User.t(), String.t()) :: {:ok, Seat.t()} | {:error, term()}
  def revoke_seat(%User{} = actor, seat_id) when is_binary(seat_id) do
    case Seat
         |> Ash.Query.filter(id == ^seat_id and owner_id == ^actor.id)
         |> Ash.read_one(domain: __MODULE__, authorize?: false) do
      {:ok, %Seat{} = seat} ->
        seat
        |> Ash.Changeset.for_update(:revoke, %{})
        |> Ash.update(domain: __MODULE__, actor: actor, authorize?: true)

      {:ok, nil} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def revoke_seat(_, _), do: {:error, :not_found}

  @doc """
  Lists workspace reports owned by the actor (requires active subscription via `Subscribed`).
  """
  @spec list_reports(User.t()) :: {:ok, [Report.t()]} | {:error, term()}
  def list_reports(%User{} = actor) do
    Report
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read(domain: __MODULE__, actor: actor, authorize?: true)
  end

  @doc """
  Creates a workspace report (requires active subscription via `Subscribed`).
  """
  @spec create_report(User.t(), map()) :: {:ok, Report.t()} | {:error, term()}
  def create_report(%User{} = actor, attrs) when is_map(attrs) do
    title = (Map.get(attrs, :title) || Map.get(attrs, "title") || "") |> String.trim()
    summary = Map.get(attrs, :summary) || Map.get(attrs, "summary")

    if title == "" do
      {:error, :invalid_title}
    else
      Report
      |> Ash.Changeset.for_create(:create_for_owner, %{title: title, summary: summary},
        actor: actor
      )
      |> Ash.create(domain: __MODULE__, actor: actor, authorize?: true)
    end
  end

  @doc """
  Runs Pro/Enterprise analytics export (`AshBilling.Checks.HasPrice` + owner policy).
  """
  @spec export_report(User.t(), String.t()) :: {:ok, Report.t()} | {:error, term()}
  def export_report(%User{} = actor, report_id) when is_binary(report_id) do
    with {:ok, report} <- fetch_report_for_action(report_id) do
      report
      |> Ash.Changeset.for_update(:export_analytics, %{})
      |> Ash.update(domain: __MODULE__, actor: actor, authorize?: true)
    end
  end

  @doc """
  Runs Enterprise compliance audit (`AshBilling.Checks.HasPrice` + owner policy).
  """
  @spec audit_report(User.t(), String.t()) :: {:ok, Report.t()} | {:error, term()}
  def audit_report(%User{} = actor, report_id) when is_binary(report_id) do
    with {:ok, report} <- fetch_report_for_action(report_id) do
      report
      |> Ash.Changeset.for_update(:enterprise_audit, %{})
      |> Ash.update(domain: __MODULE__, actor: actor, authorize?: true)
    end
  end

  defp fetch_report_for_action(report_id) do
    case Ash.get(Report, report_id, domain: __MODULE__, authorize?: false) do
      {:ok, %Report{} = report} -> {:ok, report}
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_seat_capacity(%User{} = actor) do
    case AshBilling.subscription(actor) do
      nil ->
        {:error, :subscription_required}

      %{quantity: qty} when is_nil(qty) or qty <= 0 ->
        {:error, :no_contracted_seats}

      %{quantity: qty} when is_integer(qty) ->
        used = active_seat_count(actor)

        if used >= qty do
          {:error, {:seat_limit_reached, used, qty}}
        else
          :ok
        end
    end
  end
end
