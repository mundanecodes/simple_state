# frozen_string_literal: true

require_relative "lite_state/version"
require "active_support/concern"
require "active_support/notifications"

# LiteState is a lightweight state machine module for ActiveRecord models.
# It supports state transitions, optional guards, timestamps, and emits
# ActiveSupport::Notifications events for each transition outcome.
#
# @example Basic usage
#   class Order < ApplicationRecord
#     include LiteState
#
#     state_column :status
#
#     enum status: { pending: 0, processing: 1, completed: 2, cancelled: 3 }
#
#     transition :process, from: :pending, to: :processing, timestamp: true
#     transition :complete, from: :processing, to: :completed, timestamp: :completed_at
#     transition :cancel, from: [:pending, :processing], to: :cancelled
#   end
#
#   order = Order.create!(status: :pending)
#   order.process  # => true, updates status to :processing and processing_at timestamp
#   order.complete # => true, updates status to :completed and completed_at timestamp
#
# @example With guards and callbacks
#   class Employee < ApplicationRecord
#     include LiteState
#
#     state_column :state
#
#     enum state: { created: 0, invited: 1, enrolled: 2, suspended: 3, terminated: 4 }
#
#     transition :reactivate,
#                from: [:suspended, :terminated],
#                to: :enrolled,
#                timestamp: :enrolled_on,
#                guard: :eligible_for_reactivation? do
#       notify_employee(:reactivated)
#       clear_suspension_reason
#     end
#
#     def eligible_for_reactivation?
#       return true if suspended?
#       return true unless terminated_on
#       terminated_on >= 90.days.ago.to_date
#     end
#   end
#
module LiteState
  class Error < StandardError; end

  # Raised when an invalid transition is attempted
  class TransitionError < Error
    attr_reader :record, :to, :from, :event

    # @param record [ActiveRecord::Base] the record being transitioned
    # @param to [Symbol] the target state
    # @param from [Symbol] the current state
    # @param event [Symbol] the transition event
    def initialize(record:, to:, from:, event:)
      @record = record
      @to = to
      @from = from
      @event = event
      super("Invalid transition: #{record.class} ##{record.id} from #{from.inspect} -> #{to.inspect} on #{event}")
    end
  end

  extend ActiveSupport::Concern

  included do
    class_attribute :lite_state_column, instance_writer: false
    class_attribute :lite_state_transitions, instance_writer: false, default: {}

    # Performs a state transition
    #
    # @param to [Symbol] target state
    # @param allowed_from [Symbol, Array<Symbol>] states allowed to transition from
    # @param event [Symbol] transition event name
    # @param column [Symbol, nil] column to use for this transition (defaults to lite_state_column)
    # @param timestamp_field [Symbol, true, nil] column to update with current time; true will auto-generate "#{to}_at"
    # @param guard [Symbol, Proc, nil] optional guard method or block that must return true
    # @yield optional block to execute after state update
    # @return [Boolean] true if transition succeeds
    # @raise [TransitionError] if transition is invalid or guard fails
    # @raise [ActiveRecord::RecordInvalid] if update! fails
    def transition_state(to:, allowed_from:, event:, column: nil, timestamp_field: nil, guard: nil, &block)
      allowed_from = Array(allowed_from).map(&:to_sym).freeze

      # Determine which column to use for this transition
      state_column = column || self.class.lite_state_column

      raise ArgumentError, "No state column specified. Use 'state_column :column_name' or provide 'column:' parameter" unless state_column

      current_state_value = public_send(state_column)

      fail_transition!(to:, from: nil, event:, outcome: :invalid) if current_state_value.nil?

      current_state = current_state_value.to_sym

      fail_transition!(to:, from: current_state, event:, outcome: :invalid) unless allowed_from.include?(current_state)

      if guard
        result = guard.is_a?(Symbol) ? send(guard) : instance_exec(&guard)
        fail_transition!(to:, from: current_state, event:, outcome: :invalid) unless result
      end

      transaction do
        attrs = {state_column => to}

        # Simple timestamp support: true => "#{to}_at", or custom column
        if timestamp_field
          timestamp_column = (timestamp_field == true) ? "#{to}_at" : timestamp_field
          attrs[timestamp_column] = Time.current
        end

        update!(attrs)

        # Ensure block exceptions are tracked as failures
        begin
          instance_exec(&block) if block
        rescue => e
          publish_state_event(outcome: :failed, to:, from: current_state, event:)
          raise e
        end

        publish_state_event(outcome: :success, to:, from: current_state, event:)
      end

      true
    rescue ActiveRecord::RecordInvalid => e
      publish_state_event(outcome: :failed, to:, from: current_state, event:)
      raise e
    end

    # Checks if the record can perform a given transition
    #
    # @param name [Symbol] transition name
    # @return [Boolean] true if allowed and guard passes
    def can_transition?(name)
      transition = self.class.lite_state_transitions[name.to_sym]
      return false unless transition

      allowed_from = Array(transition[:from]).map(&:to_sym)

      # Use the column specified in the transition, or fall back to default
      state_column = transition[:column] || self.class.lite_state_column
      return false unless state_column

      current_state_value = public_send(state_column)
      return false if current_state_value.nil?

      current_state = current_state_value.to_sym
      guard = transition[:guard]

      allowed_from.include?(current_state) &&
        (guard.nil? || (guard.is_a?(Symbol) ? send(guard) : instance_exec(&guard)))
    end

    private

    # Publishes a failed transition and raises TransitionError
    #
    # @param to [Symbol] target state
    # @param from [Symbol] current state
    # @param event [Symbol] transition event
    # @param outcome [Symbol] event outcome (:invalid, :failed)
    # @raise [TransitionError]
    def fail_transition!(to:, from:, event:, outcome:)
      publish_state_event(outcome:, to:, from:, event:)
      raise TransitionError.new(record: self, to:, from:, event:)
    end

    # Publishes an ActiveSupport::Notifications event
    #
    # @param outcome [Symbol] :success, :failed, :invalid
    # @param to [Symbol] target state
    # @param from [Symbol] current state
    # @param event [Symbol] transition event
    def publish_state_event(outcome:, to:, from:, event:)
      event_name = [
        self.class.name.underscore,
        event.to_s.underscore,
        outcome.to_s.underscore
      ].join(".")

      ActiveSupport::Notifications.instrument(event_name, {
        record: self,
        record_id: id,
        from_state: from,
        to_state: to,
        event:,
        timestamp: Time.current
      })
    end
  end

  class_methods do
    # Sets the column used for state
    #
    # @param column_name [Symbol] the database column name for state storage
    # @example
    #   state_column :status
    #   state_column :state
    def state_column(column_name)
      self.lite_state_column = column_name
    end

    # Validates that a state exists in the enum definition
    #
    # @param state [Symbol] the state to validate
    # @param column [Symbol] the column to validate against
    # @raise [ArgumentError] if state is not defined in the enum
    # @api private
    def validate_state_exists!(state, column:)
      return unless column

      enum_accessor = column.to_s.pluralize
      return unless respond_to?(enum_accessor)

      valid_states = public_send(enum_accessor).keys.map(&:to_sym)
      unless valid_states.include?(state.to_sym)
        raise ArgumentError, "Invalid state :#{state} for #{column}. Valid states: #{valid_states.join(", ")}"
      end
    end

    # Defines a transition method
    #
    # @param name [Symbol] method name for the transition
    # @param to [Symbol] target state
    # @param from [Symbol, Array<Symbol>] allowed source states
    # @param column [Symbol, nil] column to use for this transition (defaults to lite_state_column)
    # @param timestamp [Symbol, true, nil] column to update with current time
    # @param guard [Symbol, Proc, nil] optional guard method/block
    # @yield block executed after state update but within the transaction
    # @example Simple transition
    #   transition :activate, from: :pending, to: :active
    # @example With timestamp
    #   transition :complete, from: :active, to: :completed, timestamp: true
    # @example With multiple columns
    #   transition :pay, from: :unpaid, to: :paid, column: :payment_status
    # @example With guard and callback
    #   transition :reactivate, from: :suspended, to: :active, guard: :can_reactivate? do
    #     send_notification
    #   end
    def transition(name, to:, from:, column: nil, timestamp: nil, guard: nil, &block)
      # Determine which column to validate against
      state_column = column || lite_state_column

      raise ArgumentError, "No state column specified. Use 'state_column :column_name' or provide 'column:' parameter" unless state_column

      # Validate that target and source states exist in the enum
      validate_state_exists!(to, column: state_column)
      Array(from).each { |state| validate_state_exists!(state, column: state_column) }

      self.lite_state_transitions = lite_state_transitions.merge(
        name.to_sym => {to:, from:, column:, timestamp:, guard:, block:}.freeze
      ).freeze

      define_method(name) do
        transition_state(
          to:,
          allowed_from: from,
          event: name,
          column:,
          timestamp_field: timestamp,
          guard:,
          &block
        )
      end
    end
  end
end
