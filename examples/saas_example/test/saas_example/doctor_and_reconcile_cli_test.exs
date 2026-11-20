defmodule SaasExample.DoctorAndReconcileCliTest do
  use SaasExampleWeb.ConnCase, async: false

  alias SaasExample.{Accounts, Billing}
  alias SaasExample.Billing.{Catalog, Subscription}

  test "mix ash_billing.doctor passes all structural and PostgreSQL checks with production_ready: true and zero leaked secrets" do
    report =
      AshBilling.Diagnostics.run(
        customer_resource: SaasExample.Accounts.User,
        subscription_resource: SaasExample.Billing.Subscription,
        deduplication_resource: SaasExample.Billing.WebhookEvent,
        deduplication_strategy: :resource,
        expected_livemode: false,
        check_database?: true,
        check_provider?: false
      )

    assert report.status == :pass
    assert report.configuration_valid == true
    assert report.production_ready == true
    assert report.summary.fail == 0
    assert report.summary.warn == 0

    # Verify CLI task executes cleanly in --json mode without leaking secrets
    prev_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(prev_shell) end)

    Mix.Tasks.AshBilling.Doctor.run([
      "--customer-resource",
      "SaasExample.Accounts.User",
      "--subscription-resource",
      "SaasExample.Billing.Subscription",
      "--deduplication-resource",
      "SaasExample.Billing.WebhookEvent",
      "--expected-livemode",
      "false",
      "--json",
      "--no-start"
    ])

    assert_receive {:mix_shell, :info, [json_output]}
    refute json_output =~ "sk_test_saas_example_test_key"
    refute json_output =~ "whsec_saas_example_test_secret"

    decoded = Jason.decode!(json_output)
    assert decoded["status"] == "pass"
    assert decoded["configuration_valid"] == true
    assert decoded["production_ready"] == true
  end

  test "mix ash_billing.reconcile inspects drift in --dry-run (0 writes) and converges state on confirmed --execute" do
    user = create_user!(%{email: "cli_rec@example.com", stripe_customer_id: "cus_cli_rec_1"})

    sub =
      create_subscription!(user, %{
        provider_subscription_id: "sub_cli_rec_1",
        price_id: Catalog.price_id!(:starter),
        quantity: nil,
        provider_subscription_item_id: "si_cli_rec_1",
        last_reconciled_at: nil
      })

    configure_stripe_stub(:stripe_cli_reconcile, fn conn ->
      Req.Test.json(
        conn,
        stripe_subscription_payload(
          "sub_cli_rec_1",
          "cus_cli_rec_1",
          Catalog.price_id!(:pro),
          6,
          item_id: "si_cli_rec_1"
        )
      )
    end)

    # 1. --dry-run (default) detects drift without writing to PostgreSQL
    assert {:ok, dry_report} =
             Mix.Tasks.AshBilling.Reconcile.execute(
               [
                 domain: "SaasExample.Billing",
                 subscription_resource: "SaasExample.Billing.Subscription",
                 customer_resource: "SaasExample.Accounts.User",
                 missing_quantity: true,
                 system: true
               ],
               req_opts: Application.fetch_env!(:ash_billing, :req_opts),
               interactive?: false
             )

    assert dry_report.mode == :dry_run
    assert dry_report.total == 1
    assert dry_report.drifted == 1
    assert is_nil(Ash.get!(Subscription, sub.id, domain: Billing, authorize?: false).quantity)

    # 2. Invalid filter (--older-than-hours 0) fails closed
    assert {:error, :invalid_older_than_hours} =
             Mix.Tasks.AshBilling.Reconcile.execute(
               [
                 domain: "SaasExample.Billing",
                 subscription_resource: "SaasExample.Billing.Subscription",
                 older_than_hours: 0.0,
                 system: true
               ],
               interactive?: false
             )

    # 3. Confirmed --execute converges PostgreSQL state authoritatively
    assert {:ok, exec_report} =
             Mix.Tasks.AshBilling.Reconcile.execute(
               [
                 domain: "SaasExample.Billing",
                 subscription_resource: "SaasExample.Billing.Subscription",
                 customer_resource: "SaasExample.Accounts.User",
                 missing_quantity: true,
                 system: true,
                 execute: true,
                 confirm: true
               ],
               req_opts: Application.fetch_env!(:ash_billing, :req_opts),
               interactive?: false
             )

    assert exec_report.mode == :execute
    assert exec_report.reconciled == 1
    assert exec_report.failed == 0

    reloaded = Ash.get!(Subscription, sub.id, domain: Billing, authorize?: false)
    assert reloaded.price_id == Catalog.price_id!(:pro)
    assert reloaded.quantity == 6
    assert %DateTime{} = reloaded.last_reconciled_at

    # Verify user now has Pro access and 6 seats
    {:ok, fresh_user} = Accounts.load_fresh_actor(user.id)
    assert AshBilling.subscribed?(fresh_user, Catalog.price_id!(:pro))
  end
end
