if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshBilling.Install do
    @shortdoc "Installs AshBilling into a project. Should be called with `mix igniter.install ash_billing`"

    @moduledoc """
    #{@shortdoc}

    ## Options

    * `--customer-resource`, `-c` - The Ash resource representing billing customers (defaults to finding `User`, `Account`, or `Customer`).
    * `--subscription-resource`, `-s` - The Ash resource for subscriptions (defaults to `<App>.Billing.Subscription`).
    * `--yes`, `-y` - Automatically accept proposed changes.
    """

    use Igniter.Mix.Task

    @impl true
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        schema: [
          customer_resource: :string,
          subscription_resource: :string,
          yes: :boolean
        ],
        aliases: [
          c: :customer_resource,
          s: :subscription_resource,
          y: :yes
        ]
      }
    end

    @impl true
    def igniter(igniter) do
      options = igniter.args.options

      {igniter, customer_resource} = resolve_customer_resource(igniter, options)
      {igniter, subscription_resource} = resolve_subscription_resource(igniter, options)
      {igniter, domain} = resolve_domain(igniter, customer_resource)

      igniter
      |> setup_customer_resource(customer_resource, subscription_resource, domain)
      |> setup_subscription_resource(customer_resource, subscription_resource, domain)
      |> configure_runtime()
      |> configure_router(customer_resource, subscription_resource)
      |> Igniter.add_notice("""
      AshBilling installed successfully!

      Next steps:
      1. Ensure STRIPE_SECRET_KEY and STRIPE_WEBHOOK_SECRET are configured in your environment.
      2. If using a database data layer (e.g., AshPostgres), run:
         mix ash.codegen create_billing_tables
         mix ash.migrate
      """)
    end

    defp resolve_customer_resource(igniter, options) do
      if options[:customer_resource] do
        {igniter, Igniter.Project.Module.parse(options[:customer_resource])}
      else
        {igniter, resources} = Ash.Resource.Igniter.list_resources(igniter)

        matching =
          Enum.find(resources, fn res ->
            name = Module.split(res) |> List.last()
            name in ["User", "Account", "Customer"]
          end)

        customer =
          cond do
            matching ->
              matching

            length(resources) == 1 ->
              hd(resources)

            true ->
              Igniter.Project.Module.module_name(igniter, "Accounts.User")
          end

        {igniter, customer}
      end
    end

    defp resolve_subscription_resource(igniter, options) do
      if options[:subscription_resource] do
        {igniter, Igniter.Project.Module.parse(options[:subscription_resource])}
      else
        sub = Igniter.Project.Module.module_name(igniter, "Billing.Subscription")
        {igniter, sub}
      end
    end

    defp resolve_domain(igniter, customer_resource) do
      case Ash.Resource.Igniter.domain(igniter, customer_resource) do
        {:ok, igniter, domain} ->
          {igniter, domain}

        _ ->
          {igniter, Igniter.Project.Module.module_name(igniter, "Billing")}
      end
    end

    defp setup_customer_resource(igniter, customer, subscription, domain) do
      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, customer)

      if exists? do
        igniter
        |> Spark.Igniter.add_extension(customer, Ash.Resource, :extensions, AshBilling.Resource)
        |> Ash.Resource.Igniter.add_new_relationship(
          customer,
          :subscriptions,
          "has_many :subscriptions, #{inspect(subscription)}"
        )
      else
        path = Igniter.Project.Module.proper_location(igniter, customer)

        content = """
        defmodule #{inspect(customer)} do
          use Ash.Resource,
            domain: #{inspect(domain)},
            extensions: [AshBilling.Resource]

          attributes do
            uuid_primary_key :id
            attribute :email, :string, public?: true
          end

          relationships do
            has_many :subscriptions, #{inspect(subscription)}
          end

          actions do
            default_accept :*
            defaults [:read, :create, :update, :destroy]
          end
        end
        """

        Igniter.create_new_file(igniter, path, content)
      end
    end

    defp setup_subscription_resource(igniter, customer, subscription, domain) do
      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, subscription)

      if exists? do
        igniter
        |> Spark.Igniter.add_extension(
          subscription,
          Ash.Resource,
          :extensions,
          AshBilling.Subscription
        )
      else
        path = Igniter.Project.Module.proper_location(igniter, subscription)

        content = """
        defmodule #{inspect(subscription)} do
          use Ash.Resource,
            domain: #{inspect(domain)},
            extensions: [AshBilling.Subscription]

          attributes do
            uuid_primary_key :id
            attribute :user_id, :uuid, public?: true
          end

          relationships do
            belongs_to :user, #{inspect(customer)}
          end

          actions do
            default_accept :*
            defaults [:read, :create, :update, :destroy]
          end

          billing_subscription do
            customer_relationship :user
          end
        end
        """

        Igniter.create_new_file(igniter, path, content)
      end
    end

    defp configure_runtime(igniter) do
      target_file =
        if Igniter.exists?(igniter, "config/runtime.exs") do
          "runtime.exs"
        else
          "config.exs"
        end

      igniter
      |> Igniter.Project.Config.configure(
        target_file,
        :ash_billing,
        [:stripe_api_key],
        {:code, Sourceror.parse_string!(~s|System.get_env("STRIPE_SECRET_KEY")|)}
      )
      |> Igniter.Project.Config.configure(
        target_file,
        :ash_billing,
        [:stripe_webhook_secret],
        {:code, Sourceror.parse_string!(~s|System.get_env("STRIPE_WEBHOOK_SECRET")|)}
      )
    end

    defp configure_router(igniter, customer, subscription) do
      {igniter, router} = Igniter.Libs.Phoenix.select_router(igniter)

      if router do
        scope_code = """
        forward "/stripe", AshBilling.Plug,
          resource: #{inspect(customer)},
          subscription_resource: #{inspect(subscription)}
        """

        Igniter.Libs.Phoenix.add_scope(
          igniter,
          "/webhooks",
          scope_code,
          router: router
        )
      else
        Igniter.add_notice(igniter, """
        No Phoenix router was detected. If using Phoenix, mount AshBilling.Plug in your router:

            scope "/webhooks" do
              forward "/stripe", AshBilling.Plug,
                resource: #{inspect(customer)},
                subscription_resource: #{inspect(subscription)}
            end
        """)
      end
    end
  end
else
  defmodule Mix.Tasks.AshBilling.Install do
    @shortdoc "Installs AshBilling into a project. Requires igniter to be installed."
    @moduledoc @shortdoc

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_billing.install' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
