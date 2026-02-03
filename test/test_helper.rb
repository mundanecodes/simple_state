# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "lite_state"

require "minitest/autorun"
require "active_record"
require "active_support/notifications"

# Set up in-memory SQLite database for testing
ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: ":memory:"
)

# Create test tables
ActiveRecord::Schema.define do
  create_table :orders, force: true do |t|
    t.string :status, default: "pending", null: false
    t.datetime :processing_at
    t.datetime :completed_at
    t.datetime :cancelled_at
    t.timestamps
  end

  create_table :employees, force: true do |t|
    t.string :state, default: "created", null: false
    t.datetime :invited_on
    t.datetime :enrolled_on
    t.datetime :suspended_on
    t.datetime :terminated_on
    t.date :terminated_date
    t.timestamps
  end

  create_table :documents, force: true do |t|
    t.string :status, default: "draft", null: false
    t.timestamps
  end
end

# Test models
class Order < ActiveRecord::Base
  include LiteState

  state_column :status

  enum :status, {
    pending: "pending",
    processing: "processing",
    completed: "completed",
    cancelled: "cancelled"
  }

  transition :process, from: :pending, to: :processing, timestamp: true
  transition :complete, from: :processing, to: :completed, timestamp: :completed_at
  transition :cancel, from: [:pending, :processing], to: :cancelled, timestamp: true
end

class Employee < ActiveRecord::Base
  include LiteState

  state_column :state

  enum :state, {
    created: "created",
    invited: "invited",
    enrolled: "enrolled",
    suspended: "suspended",
    terminated: "terminated"
  }

  transition :invite, from: :created, to: :invited, timestamp: :invited_on
  transition :enroll, from: :invited, to: :enrolled, timestamp: :enrolled_on do
    self.enrolled_on ||= Time.current
  end

  transition :suspend, from: :enrolled, to: :suspended, timestamp: :suspended_on

  transition :terminate, from: [:enrolled, :suspended], to: :terminated, timestamp: :terminated_on do
    self.terminated_date = Date.current
  end

  transition :reactivate,
    from: [:suspended, :terminated],
    to: :enrolled,
    timestamp: :enrolled_on,
    guard: :eligible_for_reactivation? do
    self.suspended_on = nil
    self.terminated_on = nil
  end

  def eligible_for_reactivation?
    return true if suspended?
    return true unless terminated_date
    terminated_date >= 90.days.ago.to_date
  end
end

class Document < ActiveRecord::Base
  include LiteState

  state_column :status

  enum :status, {draft: "draft", pending: "pending", approved: "approved", rejected: "rejected"}

  transition :submit, from: :draft, to: :pending
  transition :approve, from: :pending, to: :approved, guard: :can_approve?
  transition :reject, from: :pending, to: :rejected

  def can_approve?
    true # Override in tests as needed
  end
end
