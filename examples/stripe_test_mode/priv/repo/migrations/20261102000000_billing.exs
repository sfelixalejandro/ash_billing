defmodule AshBillingConsumer.Repo.Migrations.Billing do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:email, :text)
      add(:stripe_customer_id, :text)
      add(:billing_deleted_at, :utc_datetime_usec)
    end

    create table(:subscriptions, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:user_id, references(:users, type: :uuid))
      add(:provider_subscription_id, :text, null: false)
      add(:status, :text, null: false)
      add(:price_id, :text)
      add(:current_period_end, :utc_datetime_usec)
      add(:trial_ends_at, :utc_datetime_usec)
      add(:cancel_at_period_end, :boolean, default: false)
      add(:cancel_at, :utc_datetime_usec)
      add(:last_event_created_at, :utc_datetime_usec)
    end

    create unique_index(:subscriptions, [:provider_subscription_id],
             name: :subscriptions_unique_provider_subscription_index
           )

    create table(:webhook_events, primary_key: false) do
      add(:event_id, :text, primary_key: true)
      add(:status, :text, null: false, default: "processing")
      add(:lease_token, :text)
      add(:attempts, :integer, default: 1, null: false)
      add(:error, :text)
      add(:last_attempt_at, :utc_datetime_usec)
      add(:processed_at, :utc_datetime_usec)
    end

    create table(:handler_effects, primary_key: false) do
      add(:event_id, :text, primary_key: true)
      add(:event_type, :text, null: false)
      add(:payment_status, :text)
      add(:payload, :map)
    end
  end
end
