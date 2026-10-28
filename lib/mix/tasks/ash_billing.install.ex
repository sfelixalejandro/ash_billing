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
      |> register_resources(customer_resource, subscription_resource, domain)
      |> configure_runtime()
      |> configure_router(customer_resource, subscription_resource)
      |> Igniter.add_notice("""
      AshBilling resource and webhook configuration prepared.

      Next steps:
      1. Ensure STRIPE_SECRET_KEY and STRIPE_WEBHOOK_SECRET are configured in your environment.
      2. Verify resource actions, persistence and authorization policies for your application.
         New subscriptions inherit the customer's PostgreSQL repo when explicitly configured.
      3. If using a database data layer (e.g., AshPostgres), run:
         mix ash.codegen create_billing_tables
         mix ash.migrate
      4. For production, configure an AshBilling.WebhookEvent resource for persistent deduplication.
         If you use a custom Plug.Parsers body_reader, ensure it assigns the raw body.
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

    defp subscription_foreign_key(igniter, subscription) do
      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, subscription)

      if exists?,
        do: existing_subscription_foreign_key(igniter, subscription),
        else: {igniter, :user_id}
    end

    defp existing_subscription_foreign_key(igniter, subscription) do
      {igniter, configured} =
        Spark.Igniter.get_option(igniter, subscription, [
          :billing_subscription,
          :customer_relationship
        ])

      relationship =
        case configured do
          {:ok, name} when is_atom(name) and not is_nil(name) -> name
          _ -> :user
        end

      fallback = String.to_atom("#{relationship}_id")

      case Igniter.Project.Module.find_module(igniter, subscription) do
        {:ok, {igniter, _, zipper}} ->
          attribute =
            with {:ok, call} <-
                   Igniter.Code.Function.move_to_function_call(
                     zipper,
                     :belongs_to,
                     [2, 3],
                     &Igniter.Code.Function.argument_equals?(&1, 0, relationship)
                   ),
                 {:ok, options} <- Igniter.Code.Function.move_to_nth_argument(call, 2),
                 {:ok, value} <- Igniter.Code.Keyword.get_key(options, :source_attribute),
                 {:ok, name} when is_atom(name) <- Igniter.Code.Common.expand_literal(value) do
              name
            else
              _ -> fallback
            end

          {igniter, attribute}

        {:error, igniter} ->
          {igniter, fallback}
      end
    end

    defp setup_customer_resource(igniter, customer, subscription, domain) do
      {igniter, foreign_key} = subscription_foreign_key(igniter, subscription)
      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, customer)

      if exists? do
        igniter
        |> Spark.Igniter.add_extension(customer, Ash.Resource, :extensions, AshBilling.Resource)
        |> ensure_use_option(customer, :domain, domain)
        |> Ash.Resource.Igniter.add_new_relationship(
          customer,
          :subscriptions,
          "has_many :subscriptions, #{inspect(subscription)}, destination_attribute: #{inspect(foreign_key)}"
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
            has_many :subscriptions, #{inspect(subscription)}, destination_attribute: #{inspect(foreign_key)}
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
        igniter =
          igniter
          |> Spark.Igniter.add_extension(
            subscription,
            Ash.Resource,
            :extensions,
            AshBilling.Subscription
          )
          |> ensure_use_option(subscription, :domain, domain)

        {igniter, relationship} =
          Spark.Igniter.get_option(igniter, subscription, [
            :billing_subscription,
            :customer_relationship
          ])

        case relationship do
          {:ok, name} when is_atom(name) and not is_nil(name) ->
            igniter

          _ ->
            igniter
            |> Ash.Resource.Igniter.add_new_attribute(
              subscription,
              :user_id,
              "attribute :user_id, :uuid, public?: true"
            )
            |> Ash.Resource.Igniter.add_new_relationship(
              subscription,
              :user,
              "belongs_to :user, #{inspect(customer)}"
            )
            |> Spark.Igniter.set_option(
              subscription,
              [:billing_subscription, :customer_relationship],
              :user
            )
        end
      else
        path = Igniter.Project.Module.proper_location(igniter, subscription)
        {igniter, repo_option} = Spark.Igniter.get_option(igniter, customer, [:postgres, :repo])

        {data_layer, postgres} =
          case repo_option do
            {:ok, repo} when is_atom(repo) and not is_nil(repo) ->
              {", data_layer: AshPostgres.DataLayer",
               """
               postgres do
                 table "subscriptions"
                 repo #{inspect(repo)}
               end
               """}

            _ ->
              {"", ""}
          end

        content = """
        defmodule #{inspect(subscription)} do
          use Ash.Resource,
            domain: #{inspect(domain)},
            extensions: [AshBilling.Subscription]#{data_layer}

          #{postgres}

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

    defp ensure_use_option(igniter, resource, key, value) do
      Igniter.Project.Module.find_and_update_module!(igniter, resource, fn zipper ->
        with {:ok, zipper} <- Igniter.Code.Module.move_to_use(zipper, Ash.Resource) do
          Igniter.Code.Function.update_nth_argument(zipper, 1, fn options ->
            Igniter.Code.Keyword.set_keyword_key(options, key, value)
          end)
        end
      end)
    end

    defp register_resources(igniter, customer, subscription, default_domain) do
      Enum.reduce([customer, subscription], igniter, fn resource, igniter ->
        {igniter, domain} =
          case Ash.Resource.Igniter.domain(igniter, resource) do
            {:ok, igniter, domain} -> {igniter, domain}
            _ -> {igniter, default_domain}
          end

        {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, domain)
        app = Igniter.Project.Application.app_name(igniter)

        igniter =
          if exists?,
            do: igniter,
            else:
              Igniter.Project.Module.create_module(
                igniter,
                domain,
                "use Ash.Domain, otp_app: #{inspect(app)}"
              )

        igniter
        |> Ash.Domain.Igniter.add_resource_reference(domain, resource)
        |> Igniter.Project.Config.configure("config.exs", app, [:ash_domains], [domain],
          updater: &Igniter.Code.List.prepend_new_to_list(&1, domain)
        )
      end)
    end

    defp configure_runtime(igniter) do
      igniter =
        if Igniter.exists?(igniter, "config/runtime.exs"),
          do: igniter,
          else: Igniter.create_new_file(igniter, "config/runtime.exs", "import Config\n")

      target_file = "runtime.exs"

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
          customer_resource: #{inspect(customer)},
          subscription_resource: #{inspect(subscription)},
          webhook_secret: {Application, :get_env, [:ash_billing, :stripe_webhook_secret]}
        """

        igniter =
          Igniter.Libs.Phoenix.add_scope(
            igniter,
            "/webhooks",
            scope_code,
            router: router
          )

        configure_body_reader(igniter, router)
      else
        Igniter.add_notice(igniter, """
        No Phoenix router was detected. If using Phoenix, mount AshBilling.Plug in your router:

            scope "/webhooks" do
              forward "/stripe", AshBilling.Plug,
                customer_resource: #{inspect(customer)},
                subscription_resource: #{inspect(subscription)},
                webhook_secret: {Application, :get_env, [:ash_billing, :stripe_webhook_secret]}
            end
        """)
      end
    end

    defp configure_body_reader(igniter, router) do
      {igniter, endpoint} = Igniter.Libs.Phoenix.select_endpoint(igniter, router)

      if endpoint do
        Igniter.Project.Module.find_and_update_module!(igniter, endpoint, fn zipper ->
          with {:ok, zipper} <-
                 Igniter.Code.Function.move_to_function_call_in_current_scope(
                   zipper,
                   :plug,
                   2,
                   &Igniter.Code.Function.argument_equals?(&1, 0, Plug.Parsers)
                 ) do
            Igniter.Code.Function.update_nth_argument(zipper, 1, fn options ->
              Igniter.Code.Keyword.set_keyword_key(
                options,
                :body_reader,
                Sourceror.parse_string!("{AshBilling.Plug, :read_body, []}")
              )
            end)
          else
            _ ->
              {:warning,
               "Configure Plug.Parsers body_reader: {AshBilling.Plug, :read_body, []} before using router webhooks."}
          end
        end)
      else
        Igniter.add_notice(
          igniter,
          "Configure your endpoint's Plug.Parsers with body_reader: {AshBilling.Plug, :read_body, []}."
        )
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
