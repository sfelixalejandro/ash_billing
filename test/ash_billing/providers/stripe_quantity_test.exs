defmodule AshBilling.Providers.StripeQuantityTest do
  use ExUnit.Case, async: true
  alias AshBilling.Providers.Stripe

  defp item(id, quantity),
    do: %{"id" => id, "quantity" => quantity, "price" => %{"id" => "price_old"}}

  defp stub(body, expected_quantity) do
    name = "quantity_#{System.unique_integer([:positive])}"

    Req.Test.stub(name, fn conn ->
      send(self(), {:request, conn.method})

      case conn.method do
        "GET" ->
          Req.Test.json(conn, body)

        "POST" ->
          {:ok, encoded, conn} = Plug.Conn.read_body(conn)
          params = URI.decode_query(encoded)
          assert params["items[0][quantity]"] == to_string(expected_quantity)
          assert params["items[0][price]"] == "price_new"
          send(self(), {:updated_item, params["items[0][id]"]})
          Req.Test.json(conn, %{"id" => "sub_test"})
      end
    end)

    [req_opts: [plug: {Req.Test, name}, retry: false]]
  end

  for quantity <- [1, 20], explicit_id? <- [false, true] do
    test "preserves #{quantity} seats with explicit item #{explicit_id?}" do
      opts =
        stub(%{"items" => %{"data" => [item("si_target", unquote(quantity))]}}, unquote(quantity))

      opts =
        if unquote(explicit_id?),
          do: Keyword.put(opts, :subscription_item_id, "si_target"),
          else: opts

      assert {:ok, _} = Stripe.swap_plan("sub_test", "price_new", opts)
      assert_received {:request, "GET"}
      refute_received {:request, "GET"}
      assert_received {:updated_item, "si_target"}
    end
  end

  test "explicit quantity and item avoid GET while preserving the requested mutation" do
    assert {:ok, _} =
             Stripe.swap_plan(
               "sub_test",
               "price_new",
               stub(nil, 7) ++ [quantity: 7, subscription_item_id: "si_target"]
             )

    refute_received {:request, "GET"}
    assert_received {:updated_item, "si_target"}
  end

  test "explicit quantity without item resolves it once" do
    assert {:ok, _} =
             Stripe.swap_plan(
               "sub_test",
               "price_new",
               stub(%{"items" => %{"data" => [item("si_target", 20)]}}, 7) ++ [quantity: 7]
             )

    assert_received {:request, "GET"}
    refute_received {:request, "GET"}
    assert_received {:updated_item, "si_target"}
  end

  for quantity <- [nil, 0, -1, "20", 1.5, false] do
    test "invalid explicit quantity #{inspect(quantity)} never calls Stripe" do
      assert {:error, :invalid_quantity} =
               Stripe.swap_plan(
                 "sub_test",
                 "price_new",
                 stub(nil, nil) ++ [quantity: unquote(quantity)]
               )

      refute_received {:request, _}

      assert {:error, :invalid_quantity} =
               AshBilling.update_quantity("sub_test", unquote(quantity))
    end
  end

  test "multiple items require explicit selection, including quantity updates" do
    body = %{"items" => %{"data" => [item("si_other", 1), item("si_target", 20)]}}
    opts = stub(body, 20)

    assert {:error, :ambiguous_subscription_items} =
             Stripe.swap_plan("sub_test", "price_new", opts)

    refute_received {:request, "POST"}

    assert {:error, :ambiguous_subscription_items} =
             AshBilling.update_quantity("sub_test", 5, opts)

    refute_received {:request, "POST"}

    assert {:ok, _} =
             Stripe.swap_plan(
               "sub_test",
               "price_new",
               opts ++ [subscription_item_id: "si_target"]
             )

    assert_received {:updated_item, "si_target"}
  end

  for body <- [
        %{},
        %{"items" => %{"data" => []}},
        %{"items" => %{"data" => "bad"}},
        %{"items" => %{"data" => [nil]}}
      ] do
    test "unexpected item shape #{inspect(body)} returns a controlled error" do
      assert {:error, {:missing_subscription_item, _}} =
               Stripe.swap_plan("sub_test", "price_new", stub(unquote(Macro.escape(body)), nil))

      refute_received {:request, "POST"}
    end
  end

  test "missing selected item does not modify another item" do
    body = %{"items" => %{"data" => [item("si_other", 20)]}}

    assert {:error, {:missing_subscription_item, _}} =
             Stripe.swap_plan(
               "sub_test",
               "price_new",
               stub(body, nil) ++ [subscription_item_id: "si_missing"]
             )

    refute_received {:request, "POST"}
  end

  test "missing quantity never defaults to one" do
    assert {:error, :missing_subscription_quantity} =
             Stripe.swap_plan(
               "sub_test",
               "price_new",
               stub(%{"items" => %{"data" => [item("si_target", nil)]}}, nil)
             )

    refute_received {:request, "POST"}
  end

  test "truncated item collection fails safely" do
    assert {:error, :incomplete_subscription_items} =
             Stripe.swap_plan(
               "sub_test",
               "price_new",
               stub(%{"items" => %{"data" => [item("si_target", 20)], "has_more" => true}}, nil)
             )

    refute_received {:request, "POST"}
  end

  test "explicit missing item is rejected by Stripe without guessing another item" do
    name = "quantity_missing_#{System.unique_integer([:positive])}"

    Req.Test.stub(name, fn conn ->
      assert conn.method == "POST"

      Req.Test.json(%{conn | status: 400}, %{
        "error" => %{"message" => "No such subscription item"}
      })
    end)

    assert {:error, %{status: 400, error: "No such subscription item"}} =
             Stripe.swap_plan("sub_test", "price_new",
               subscription_item_id: "si_missing",
               quantity: 20,
               req_opts: [plug: {Req.Test, name}, retry: false]
             )
  end
end
