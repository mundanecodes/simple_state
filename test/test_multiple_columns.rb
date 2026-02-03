# frozen_string_literal: true

require "test_helper"

# Create a multi-column test table
ActiveRecord::Schema.define do
  create_table :multi_state_orders, force: true do |t|
    t.string :status, default: "pending", null: false
    t.string :payment_status, default: "unpaid", null: false
    t.string :fulfillment_status, default: "unfulfilled", null: false
    t.datetime :processing_at
    t.datetime :completed_at
    t.datetime :paid_at
    t.datetime :refunded_at
    t.datetime :shipped_at
    t.datetime :delivered_at
    t.timestamps
  end
end

# Test model with multiple state columns and default state_column
class MultiStateOrder < ActiveRecord::Base
  include LiteState

  # Define enums for all state columns
  enum :status, {
    pending: "pending",
    processing: "processing",
    completed: "completed",
    cancelled: "cancelled"
  }

  enum :payment_status, {
    unpaid: "unpaid",
    paid: "paid",
    refunded: "refunded"
  }

  enum :fulfillment_status, {
    unfulfilled: "unfulfilled",
    shipped: "shipped",
    delivered: "delivered"
  }

  # Set default state column
  state_column :status

  # Status transitions (uses default column)
  transition :process, from: :pending, to: :processing, timestamp: true
  transition :complete, from: :processing, to: :completed, timestamp: true
  transition :cancel, from: [:pending, :processing], to: :cancelled

  # Payment transitions (explicit column)
  transition :pay, from: :unpaid, to: :paid, column: :payment_status, timestamp: :paid_at
  transition :refund, from: :paid, to: :refunded, column: :payment_status, timestamp: :refunded_at

  # Fulfillment transitions (explicit column)
  transition :ship,
    from: :unfulfilled,
    to: :shipped,
    column: :fulfillment_status,
    timestamp: :shipped_at,
    guard: :can_ship?

  transition :deliver,
    from: :shipped,
    to: :delivered,
    column: :fulfillment_status,
    timestamp: true

  def can_ship?
    paid?
  end
end

# Test model without default state_column
class NoDefaultStateOrder < ActiveRecord::Base
  self.table_name = "multi_state_orders"

  include LiteState

  enum :status, {pending: "pending", processing: "processing", completed: "completed"}
  enum :payment_status, {unpaid: "unpaid", paid: "paid", refunded: "refunded"}

  # All transitions must specify column
  transition :process, from: :pending, to: :processing, column: :status
  transition :pay, from: :unpaid, to: :paid, column: :payment_status
end

class TestMultipleColumns < Minitest::Test
  def setup
    MultiStateOrder.delete_all
  end

  # ========================================
  # Tests with default state_column
  # ========================================

  def test_default_column_transition
    order = MultiStateOrder.create!(
      status: :pending,
      payment_status: :unpaid,
      fulfillment_status: :unfulfilled
    )

    assert order.process
    assert_equal "processing", order.status
    assert_equal "unpaid", order.payment_status # unchanged
    assert_equal "unfulfilled", order.fulfillment_status # unchanged
    refute_nil order.processing_at
  end

  def test_explicit_column_transition_payment
    order = MultiStateOrder.create!(
      status: :pending,
      payment_status: :unpaid,
      fulfillment_status: :unfulfilled
    )

    assert order.pay
    assert_equal "pending", order.status # unchanged
    assert_equal "paid", order.payment_status
    assert_equal "unfulfilled", order.fulfillment_status # unchanged
    refute_nil order.paid_at
  end

  def test_explicit_column_transition_fulfillment
    order = MultiStateOrder.create!(
      status: :pending,
      payment_status: :paid,
      fulfillment_status: :unfulfilled
    )

    assert order.ship
    assert_equal "pending", order.status # unchanged
    assert_equal "paid", order.payment_status # unchanged
    assert_equal "shipped", order.fulfillment_status
    refute_nil order.shipped_at
  end

  def test_multiple_transitions_on_different_columns
    order = MultiStateOrder.create!(
      status: :pending,
      payment_status: :unpaid,
      fulfillment_status: :unfulfilled
    )

    # Process the order
    order.process
    assert_equal "processing", order.status
    refute_nil order.processing_at

    # Pay for the order
    order.pay
    assert_equal "paid", order.payment_status
    refute_nil order.paid_at

    # Ship the order
    order.ship
    assert_equal "shipped", order.fulfillment_status
    refute_nil order.shipped_at

    # Complete the order
    order.complete
    assert_equal "completed", order.status
    refute_nil order.completed_at

    # Deliver the order
    order.deliver
    assert_equal "delivered", order.fulfillment_status
    refute_nil order.delivered_at
  end

  def test_guard_on_explicit_column
    order = MultiStateOrder.create!(
      status: :pending,
      payment_status: :unpaid,
      fulfillment_status: :unfulfilled
    )

    # Cannot ship because not paid
    error = assert_raises(LiteState::TransitionError) do
      order.ship
    end

    assert_match(/Invalid transition/, error.message)
    assert_equal "unfulfilled", order.reload.fulfillment_status

    # Pay and then ship should work
    order.pay
    assert order.ship
    assert_equal "shipped", order.fulfillment_status
  end

  def test_can_transition_with_default_column
    order = MultiStateOrder.create!(
      status: :pending,
      payment_status: :unpaid,
      fulfillment_status: :unfulfilled
    )

    assert order.can_transition?(:process)
    assert order.can_transition?(:cancel)
    refute order.can_transition?(:complete)
  end

  def test_can_transition_with_explicit_column
    order = MultiStateOrder.create!(
      status: :pending,
      payment_status: :unpaid,
      fulfillment_status: :unfulfilled
    )

    assert order.can_transition?(:pay)
    refute order.can_transition?(:refund)
  end

  def test_can_transition_respects_guard_on_explicit_column
    order = MultiStateOrder.create!(
      status: :pending,
      payment_status: :unpaid,
      fulfillment_status: :unfulfilled
    )

    # Cannot ship because guard fails (not paid)
    refute order.can_transition?(:ship)

    # Pay and check again
    order.pay
    assert order.can_transition?(:ship)
  end

  def test_invalid_transition_on_explicit_column
    order = MultiStateOrder.create!(
      status: :pending,
      payment_status: :unpaid,
      fulfillment_status: :unfulfilled
    )

    error = assert_raises(LiteState::TransitionError) do
      order.refund # Cannot refund when unpaid
    end

    assert_equal order, error.record
    assert_equal :refunded, error.to
    assert_equal :unpaid, error.from
    assert_equal :refund, error.event
  end

  def test_timestamps_on_different_columns
    order = MultiStateOrder.create!(
      status: :pending,
      payment_status: :unpaid,
      fulfillment_status: :unfulfilled
    )

    # Status transition with auto timestamp (processing_at)
    order.process
    refute_nil order.processing_at
    assert_nil order.paid_at
    assert_nil order.shipped_at

    # Payment transition with custom timestamp (paid_at)
    order.pay
    refute_nil order.paid_at
    assert_nil order.shipped_at

    # Fulfillment transition with custom timestamp (shipped_at)
    order.ship
    refute_nil order.shipped_at
    assert_nil order.delivered_at

    # Fulfillment transition with auto timestamp (delivered_at)
    order.deliver
    refute_nil order.delivered_at
  end

  def test_events_published_for_different_columns
    success_events = []
    subscription = ActiveSupport::Notifications.subscribe(/multi_state_order/) do |*args|
      success_events << ActiveSupport::Notifications::Event.new(*args)
    end

    order = MultiStateOrder.create!(
      status: :pending,
      payment_status: :unpaid,
      fulfillment_status: :unfulfilled
    )

    order.process
    order.pay
    order.ship

    # Should have 3 success events
    success_event_names = success_events.map(&:name)
    assert_includes success_event_names, "multi_state_order.process.success"
    assert_includes success_event_names, "multi_state_order.pay.success"
    assert_includes success_event_names, "multi_state_order.ship.success"

    # Check event payloads
    process_event = success_events.find { |e| e.name == "multi_state_order.process.success" }
    assert_equal :pending, process_event.payload[:from_state]
    assert_equal :processing, process_event.payload[:to_state]

    pay_event = success_events.find { |e| e.name == "multi_state_order.pay.success" }
    assert_equal :unpaid, pay_event.payload[:from_state]
    assert_equal :paid, pay_event.payload[:to_state]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  def test_transition_metadata_includes_column
    # Check default column transition
    process_transition = MultiStateOrder.lite_state_transitions[:process]
    assert_nil process_transition[:column] # Uses default

    # Check explicit column transitions
    pay_transition = MultiStateOrder.lite_state_transitions[:pay]
    assert_equal :payment_status, pay_transition[:column]

    ship_transition = MultiStateOrder.lite_state_transitions[:ship]
    assert_equal :fulfillment_status, ship_transition[:column]
  end

  # ========================================
  # Tests without default state_column
  # ========================================

  def test_no_default_column_requires_explicit_column
    order = NoDefaultStateOrder.create!(
      status: :pending,
      payment_status: :unpaid
    )

    # Should work because column is specified
    assert order.process
    assert_equal "processing", order.status

    assert order.pay
    assert_equal "paid", order.payment_status
  end

  def test_transition_without_column_and_no_default_raises_error
    # This should raise at class definition time
    error = assert_raises(ArgumentError) do
      Class.new(ActiveRecord::Base) do
        def self.name
          "InvalidOrder"
        end

        self.table_name = "multi_state_orders"
        include LiteState

        enum :status, {pending: "pending", processing: "processing"}

        # No state_column and no column: parameter
        transition :process, from: :pending, to: :processing
      end
    end

    assert_match(/No state column specified/, error.message)
  end

  # ========================================
  # Edge cases and error handling
  # ========================================

  def test_validates_state_exists_for_correct_column
    # This should raise because :invalid_state doesn't exist in payment_status enum
    error = assert_raises(ArgumentError) do
      Class.new(ActiveRecord::Base) do
        def self.name
          "TestInvalidState"
        end

        self.table_name = "multi_state_orders"
        include LiteState

        enum :payment_status, {unpaid: "unpaid", paid: "paid"}

        transition :invalid_transition,
          from: :unpaid,
          to: :invalid_state,
          column: :payment_status
      end
    end

    assert_match(/Invalid state :invalid_state for payment_status/, error.message)
  end

  def test_validates_from_state_exists_for_correct_column
    error = assert_raises(ArgumentError) do
      Class.new(ActiveRecord::Base) do
        def self.name
          "TestInvalidFromState"
        end

        self.table_name = "multi_state_orders"
        include LiteState

        enum :payment_status, {unpaid: "unpaid", paid: "paid"}

        transition :invalid_transition,
          from: :invalid_state,
          to: :paid,
          column: :payment_status
      end
    end

    assert_match(/Invalid state :invalid_state for payment_status/, error.message)
  end

  def test_rollback_on_explicit_column_transition_failure
    order = MultiStateOrder.create!(
      status: :pending,
      payment_status: :unpaid,
      fulfillment_status: :unfulfilled
    )

    # Override pay to raise an error in callback
    order.define_singleton_method(:pay) do
      transition_state(
        to: :paid,
        allowed_from: :unpaid,
        event: :pay,
        column: :payment_status,
        timestamp_field: :paid_at
      ) do
        raise StandardError, "Payment processing failed"
      end
    end

    assert_raises(StandardError) do
      order.pay
    end

    # Should rollback
    assert_equal "unpaid", order.reload.payment_status
    assert_nil order.paid_at
  end

  def test_complex_workflow_with_multiple_columns
    order = MultiStateOrder.create!(
      status: :pending,
      payment_status: :unpaid,
      fulfillment_status: :unfulfilled
    )

    # Realistic e-commerce workflow
    assert order.process # Order is being processed
    assert_equal "processing", order.status

    assert order.pay # Customer pays
    assert_equal "paid", order.payment_status

    assert order.ship # Warehouse ships
    assert_equal "shipped", order.fulfillment_status

    assert order.complete # Mark as complete
    assert_equal "completed", order.status

    assert order.deliver # Package delivered
    assert_equal "delivered", order.fulfillment_status

    # Verify all columns have correct final states
    order.reload
    assert_equal "completed", order.status
    assert_equal "paid", order.payment_status
    assert_equal "delivered", order.fulfillment_status

    # Verify all timestamps are set
    refute_nil order.processing_at
    refute_nil order.completed_at
    refute_nil order.paid_at
    refute_nil order.shipped_at
    refute_nil order.delivered_at
  end

  def test_refund_workflow
    order = MultiStateOrder.create!(
      status: :processing,
      payment_status: :paid,
      fulfillment_status: :unfulfilled
    )

    # Customer requests refund
    assert order.refund
    assert_equal "refunded", order.payment_status
    refute_nil order.refunded_at

    # Other columns unchanged
    assert_equal "processing", order.status
    assert_equal "unfulfilled", order.fulfillment_status
  end

  def test_independent_state_transitions
    order = MultiStateOrder.create!(
      status: :pending,
      payment_status: :unpaid,
      fulfillment_status: :unfulfilled
    )

    # Payment should not affect order status
    order.pay
    assert_equal "pending", order.status
    assert_equal "paid", order.payment_status

    # Order status should not affect payment
    order.process
    assert_equal "processing", order.status
    assert_equal "paid", order.payment_status

    # Cancelling order should not affect payment or fulfillment
    order.cancel
    assert_equal "cancelled", order.status
    assert_equal "paid", order.payment_status
    assert_equal "unfulfilled", order.fulfillment_status
  end
end
