defmodule AshBilling.DeduplicationTest do
  use ExUnit.Case, async: false

  alias AshBilling.Deduplication

  setup do
    Deduplication.clear()
    :ok
  end

  describe "AshBilling.Deduplication" do
    test "returns false for unprocessed events" do
      refute Deduplication.processed?("evt_unseen_1")
      refute Deduplication.processed?(nil)
    end

    test "marks event as processed and detects duplicate" do
      event_id = "evt_stripe_duplicate_check_1"
      refute Deduplication.processed?(event_id)

      assert :ok = Deduplication.mark_processed(event_id)
      assert Deduplication.processed?(event_id)
    end

    test "clear/0 empties the table" do
      event_id = "evt_to_clear"
      Deduplication.mark_processed(event_id)
      assert Deduplication.processed?(event_id)

      Deduplication.clear()
      refute Deduplication.processed?(event_id)
    end
  end
end
