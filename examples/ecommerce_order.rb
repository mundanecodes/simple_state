# Example 2: E-Commerce Order (Multiple State Columns)
#
# This example demonstrates a sophisticated e-commerce order system using
# multiple independent state machines to manage different aspects of an order:
# - Order lifecycle (pending -> processing -> completed -> cancelled)
# - Payment lifecycle (unpaid -> authorized -> paid -> refunded/failed)
# - Fulfillment lifecycle (unfulfilled -> preparing -> shipped -> delivered -> returned)
#
# Key features demonstrated:
# - Multiple state columns working independently
# - Guards that check conditions across different state machines
# - Callbacks that trigger transitions in other state machines
# - Complex business rules (refund windows, return policies)
# - Comprehensive notification system

class Order < ApplicationRecord
  include LiteState

  enum :status, {
    pending: "pending",
    processing: "processing",
    completed: "completed",
    cancelled: "cancelled"
  }

  enum :payment_status, {
    unpaid: "unpaid",
    authorized: "authorized",
    paid: "paid",
    refunded: "refunded",
    failed: "failed"
  }

  enum :fulfillment_status, {
    unfulfilled: "unfulfilled",
    preparing: "preparing",
    shipped: "shipped",
    delivered: "delivered",
    returned: "returned"
  }

  # Set default for main order lifecycle
  state_column :status

  # Order lifecycle transitions
  transition :process,
    from: :pending,
    to: :processing,
    timestamp: :processing_at do
    notify_customer(:order_processing)
    allocate_inventory
  end

  transition :complete,
    from: :processing,
    to: :completed,
    timestamp: :completed_at,
    guard: -> { payment_status == "paid" && fulfillment_status == "delivered" }

  transition :cancel,
    from: [:pending, :processing],
    to: :cancelled,
    timestamp: :cancelled_at do
    release_inventory
    notify_customer(:order_cancelled)
  end

  # Payment lifecycle transitions
  transition :authorize_payment,
    from: :unpaid,
    to: :authorized,
    column: :payment_status,
    timestamp: :payment_authorized_at do
    PaymentProcessor.authorize(self)
    notify_customer(:payment_authorized)
  end

  transition :capture_payment,
    from: :authorized,
    to: :paid,
    column: :payment_status,
    timestamp: :paid_at do
    PaymentProcessor.capture(self)
    notify_customer(:payment_captured)
    trigger_fulfillment
  end

  transition :refund_payment,
    from: :paid,
    to: :refunded,
    column: :payment_status,
    timestamp: :refunded_at,
    guard: :can_refund? do
    PaymentProcessor.refund(self)
    notify_customer(:payment_refunded)
  end

  transition :fail_payment,
    from: [:unpaid, :authorized],
    to: :failed,
    column: :payment_status do
    notify_customer(:payment_failed)
    cancel if pending? || processing?
  end

  # Fulfillment lifecycle transitions
  transition :prepare_shipment,
    from: :unfulfilled,
    to: :preparing,
    column: :fulfillment_status,
    guard: -> { paid? },
    timestamp: :preparing_at do
    notify_warehouse(:prepare_order, order_id: id)
  end

  transition :ship_order,
    from: :preparing,
    to: :shipped,
    column: :fulfillment_status,
    timestamp: :shipped_at do
    generate_tracking_number
    notify_customer(:order_shipped, tracking_number:)
  end

  transition :deliver_order,
    from: :shipped,
    to: :delivered,
    column: :fulfillment_status,
    timestamp: :delivered_at do
    notify_customer(:order_delivered)
    complete if processing?
  end

  transition :return_order,
    from: [:shipped, :delivered],
    to: :returned,
    column: :fulfillment_status,
    timestamp: :returned_at,
    guard: :can_return? do
    initiate_return_process
    refund_payment if paid?
  end

  private

  def can_refund?
    return false if refunded?
    return true if returned?
    paid_at && paid_at >= 90.days.ago
  end

  def can_return?
    delivered_at && delivered_at >= 30.days.ago
  end

  def notify_customer(event, **options)
    OrderMailer.public_send(event, self, **options).deliver_later
  end

  def notify_warehouse(event, **options)
    WarehouseNotification.create!(event:, order: self, metadata: options)
  end
end

# Usage Examples
# ==============

# Example 1: Successful Order Flow
# ---------------------------------

# Create order
order = Order.create!(
  status: :pending,
  payment_status: :unpaid,
  fulfillment_status: :unfulfilled
)

# Process order
order.process
# => status: :processing, processing_at: 2025-01-15 10:00:00 UTC
# => Allocates inventory, notifies customer

# Authorize payment
order.authorize_payment
# => payment_status: :authorized, payment_authorized_at: 2025-01-15 10:01:00 UTC
# => Processes authorization with payment gateway

# Capture payment (triggers fulfillment)
order.capture_payment
# => payment_status: :paid, paid_at: 2025-01-15 10:05:00 UTC
# => Captures payment, notifies customer, triggers fulfillment

# Prepare for shipping (guard checks payment is captured)
order.prepare_shipment
# => fulfillment_status: :preparing, preparing_at: 2025-01-15 11:00:00 UTC
# => Notifies warehouse to prepare order

# Ship order
order.ship_order
# => fulfillment_status: :shipped, shipped_at: 2025-01-16 09:00:00 UTC
# => Generates tracking number, notifies customer

# Deliver order
order.deliver_order
# => fulfillment_status: :delivered, delivered_at: 2025-01-18 14:30:00 UTC
# => Also completes the order (status: :completed)

# Final state
order.reload
order.status              # => "completed"
order.payment_status      # => "paid"
order.fulfillment_status  # => "delivered"

# Example 2: Payment Failure Flow
# --------------------------------

order = Order.create!(
  status: :pending,
  payment_status: :unpaid,
  fulfillment_status: :unfulfilled
)

order.process
order.authorize_payment

# Payment capture fails
order.fail_payment
# => payment_status: :failed
# => Also cancels the order (status: :cancelled)
# => Notifies customer of payment failure

# Example 3: Customer Return Flow
# --------------------------------

# Order has been delivered
order.status              # => "completed"
order.payment_status      # => "paid"
order.fulfillment_status  # => "delivered"
order.delivered_at        # => 5 days ago

# Customer initiates return (within 30 day window)
order.can_transition?(:return_order)  # => true
order.return_order
# => fulfillment_status: :returned
# => Automatically triggers refund_payment
# => payment_status: :refunded
# => Initiates return process, notifies customer

# Example 4: Order Cancellation
# ------------------------------

order = Order.create!(
  status: :processing,
  payment_status: :authorized,
  fulfillment_status: :unfulfilled
)

order.cancel
# => status: :cancelled, cancelled_at: 2025-01-15 15:00:00 UTC
# => Releases inventory, notifies customer

# Example 5: Guard Conditions
# ----------------------------

# Cannot prepare shipment without payment
order = Order.create!(
  status: :processing,
  payment_status: :unpaid,
  fulfillment_status: :unfulfilled
)

order.can_transition?(:prepare_shipment)  # => false (payment not captured)
order.prepare_shipment  # => raises LiteState::TransitionError

# Cannot complete order without delivery
order.update!(payment_status: :paid, fulfillment_status: :shipped)
order.can_transition?(:complete)  # => false (not delivered yet)

# Cannot refund after 90 days
order.update!(paid_at: 100.days.ago)
order.can_transition?(:refund_payment)  # => false
order.refund_payment  # => raises LiteState::TransitionError

# Example 6: Cross-State Machine Interactions
# --------------------------------------------

# Payment failure triggers order cancellation
order.fail_payment
# => payment_status: :failed
# => Automatically calls cancel if order is pending/processing

# Delivery triggers order completion
order.deliver_order
# => fulfillment_status: :delivered
# => Automatically calls complete if order is processing and paid

# Return triggers refund
order.return_order
# => fulfillment_status: :returned
# => Automatically calls refund_payment if paid
