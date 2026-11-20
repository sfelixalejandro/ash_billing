defmodule SaasExample.Repo.Migrations.CreateSaasBillingSchema do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"")
    execute("CREATE EXTENSION IF NOT EXISTS \"citext\"")

    create table(:users, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v4()"), primary_key: true
      add :email, :citext, null: false
      add :name, :text, null: false
      add :hashed_password, :text, null: false
      add :role, :text, null: false, default: "member"
      add :stripe_customer_id, :text
      add :billing_deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email], name: :users_unique_email_index)
    create unique_index(:users, [:stripe_customer_id], name: :users_unique_stripe_customer_index)

    create table(:subscriptions, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v4()"), primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :provider_subscription_id, :text, null: false
      add :status, :text, null: false
      add :price_id, :text
      add :quantity, :integer
      add :provider_subscription_item_id, :text
      add :current_period_end, :utc_datetime_usec
      add :trial_ends_at, :utc_datetime_usec
      add :cancel_at_period_end, :boolean, null: false, default: false
      add :cancel_at, :utc_datetime_usec
      add :last_event_created_at, :utc_datetime_usec
      add :last_reconciled_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:subscriptions, :subscriptions_quantity_check,
             check: "quantity IS NULL OR quantity >= 0"
           )

    create unique_index(:subscriptions, [:provider_subscription_id],
             name: :subscriptions_unique_provider_subscription_index
           )

    create index(:subscriptions, [:user_id])
    create index(:subscriptions, [:last_reconciled_at])

    create table(:webhook_events, primary_key: false) do
      add :event_id, :text, null: false, primary_key: true
      add :status, :text, null: false, default: "processing"
      add :lease_token, :text
      add :attempts, :integer, null: false, default: 1
      add :error, :text
      add :last_attempt_at, :utc_datetime_usec
      add :processed_at, :utc_datetime_usec
    end

    create table(:workspace_seats, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v4()"), primary_key: true
      add :owner_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :member_email, :citext, null: false
      add :status, :text, null: false, default: "active"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:workspace_seats, [:owner_id])

    create unique_index(:workspace_seats, [:owner_id, :member_email],
             where: "status = 'active'",
             name: :workspace_seats_unique_active_member_index
           )

    create table(:workspace_reports, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v4()"), primary_key: true
      add :owner_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :title, :text, null: false
      add :summary, :text
      add :exported_at, :utc_datetime_usec
      add :audited_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:workspace_reports, [:owner_id])
  end

  def down do
    drop table(:workspace_reports)
    drop table(:workspace_seats)
    drop table(:webhook_events)
    drop table(:subscriptions)
    drop table(:users)
  end
end
