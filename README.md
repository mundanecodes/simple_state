# SimpleState

A lightweight, powerful state machine for ActiveRecord models. SimpleState provides a clean DSL for defining state transitions with guards, timestamps, and comprehensive event instrumentation.

## Why SimpleState?

- **Minimal & Fast**: No complex dependencies or overhead
- **ActiveRecord Native**: Works seamlessly with Rails enums
- **Type-Safe**: Validates state definitions at load time
- **Observable**: Built-in ActiveSupport::Notifications for monitoring
- **Transaction-Safe**: Automatic rollback on failures
- **Production-Ready**: Comprehensive error handling and logging

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'simple_state'
```

And then execute:

```bash
bundle install
```

Or install it yourself as:

```bash
gem install simple_state
```

## Quick Start

```ruby
class Order < ApplicationRecord
  include SimpleState

  state_column :status

  enum :status, { pending: 0, processing: 1, completed: 2, cancelled: 3 }

  # Simple transition
  transition :process, from: :pending, to: :processing

  # With timestamp
  transition :complete, from: :processing, to: :completed, timestamp: true

  # From multiple states
  transition :cancel, from: [:pending, :processing], to: :cancelled
end

order = Order.create!(status: :pending)
order.process   # => true, status is now :processing
order.complete  # => true, status is now :completed, completed_at is set
```

## Features

### 1. State Transitions

Define clean, declarative transitions:

```ruby
class Employee < ApplicationRecord
  include SimpleState

  state_column :state

  enum :state, { created: 0, invited: 1, enrolled: 2, suspended: 3, terminated: 4 }

  transition :invite, from: :created, to: :invited
  transition :enroll, from: :invited, to: :enrolled
  transition :suspend, from: :enrolled, to: :suspended
  transition :terminate, from: [:enrolled, :suspended], to: :terminated
end

employee = Employee.create!(state: :created)
employee.invite     # => true
employee.enroll     # => true
employee.state      # => "enrolled"
```

### 2. Automatic Timestamps

Track when state changes occur:

```ruby
# Auto-generate timestamp column: :completed_at
transition :complete, from: :processing, to: :completed, timestamp: true

# Custom timestamp column
transition :complete, from: :processing, to: :completed, timestamp: :finished_at

order.complete
order.completed_at  # => 2025-01-15 10:30:00 UTC
```

### 3. Guard Conditions

Prevent invalid transitions with business logic:

```ruby
class Employee < ApplicationRecord
  include SimpleState

  state_column :state
  enum :state, { suspended: 0, terminated: 1, enrolled: 2 }

  transition :reactivate,
             from: [:suspended, :terminated],
             to: :enrolled,
             guard: :eligible_for_reactivation?

  def eligible_for_reactivation?
    return true if suspended?
    return true unless terminated_on
    terminated_on >= 90.days.ago.to_date
  end
end

employee = Employee.create!(state: :terminated, terminated_on: 100.days.ago)
employee.reactivate  # => raises SimpleState::TransitionError (guard failed)

employee.update!(terminated_on: 30.days.ago)
employee.reactivate  # => true
```

Guards can also be lambdas:

```ruby
transition :approve,
           from: :pending,
           to: :approved,
           guard: -> { approval_count >= 2 }
```

### 4. Transition Callbacks

Execute logic after successful state changes:

```ruby
transition :enroll, from: :invited, to: :enrolled, timestamp: :enrolled_on do
  send_welcome_email
  provision_account
  notify_team
end

# Callback failures automatically rollback the transaction
transition :activate, from: :pending, to: :active do
  result = external_api_call
  raise "API failed" unless result.success?
end
```

### 5. Query Transitions

Check if a transition is currently allowed:

```ruby
order = Order.create!(status: :pending)

order.can_transition?(:process)  # => true
order.can_transition?(:complete) # => false (not in :processing state)

order.process
order.can_transition?(:complete) # => true
```

This respects both state requirements and guards:

```ruby
employee = Employee.create!(state: :terminated, terminated_on: 100.days.ago)
employee.can_transition?(:reactivate)  # => false (guard fails)

employee.update!(terminated_on: 30.days.ago)
employee.can_transition?(:reactivate)  # => true
```

### 6. Event Instrumentation

SimpleState publishes ActiveSupport::Notifications events for every transition:

```ruby
# Subscribe to successful transitions
ActiveSupport::Notifications.subscribe(/order\.process\.success/) do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)

  puts "Order #{event.payload[:record_id]} processed"
  puts "From: #{event.payload[:from_state]}"
  puts "To: #{event.payload[:to_state]}"
end

# Subscribe to failures
ActiveSupport::Notifications.subscribe(/order\..*\.invalid/) do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  Sentry.capture_message("Invalid transition attempted", extra: event.payload)
end

# Subscribe to all events for a model
ActiveSupport::Notifications.subscribe(/order\./) do |name, start, finish, id, payload|
  Rails.logger.info("Event: #{name}, Payload: #{payload}")
end
```

Event patterns:
- `{model}.{transition}.success` - Transition completed successfully
- `{model}.{transition}.invalid` - Transition not allowed (wrong state or guard failed)
- `{model}.{transition}.failed` - Transition failed (validation error, callback exception)

Payload includes:
```ruby
{
  record: <ActiveRecord object>,
  record_id: <UUID/ID>,
  from_state: :pending,
  to_state: :processing,
  event: :process,
  timestamp: <Time>
}
```

### 7. Error Handling

SimpleState provides rich error objects:

```ruby
begin
  order.process
rescue SimpleState::TransitionError => e
  e.record      # => <Order id: 123>
  e.from        # => :completed
  e.to          # => :processing
  e.event       # => :process
  e.message     # => "Invalid transition: Order #123 from :completed -> :processing on process"
end
```

All transitions are wrapped in database transactions and automatically rollback on failure.

## Real-World Example

Here's a complete example from a production application:

```ruby
class Employee < ApplicationRecord
  include SimpleState

  state_column :state

  enum :state, {
    created: "created",
    invited: "invited",
    enrolled: "enrolled",
    suspended: "suspended",
    terminated: "terminated",
    reset_pin: "reset_pin"
  }

  # Invitation flow
  transition :invite, from: :created, to: :invited, timestamp: :invited_on do
    notify_employee(:employee_invitation)
  end

  # Suspension
  transition :suspend, from: :enrolled, to: :suspended, timestamp: :suspended_on do
    notify_employee(:employee_suspension)
    disable_access
  end

  # Termination
  transition :terminate,
             from: [:enrolled, :suspended],
             to: :terminated,
             timestamp: :terminated_on do
    notify_employee(:employee_termination)
    disable_access
    archive_data
  end

  # Reactivation with business rule
  transition :reactivate,
             from: [:suspended, :terminated],
             to: :enrolled,
             timestamp: :enrolled_on,
             guard: :eligible_for_reactivation? do
    notify_employee(:employee_reactivation)
    restore_access
  end

  # PIN reset
  transition :reset_pin, from: [:enrolled, :reset_pin], to: :reset_pin do
    pin_code = generate_otp!
    notify_employee(:employee_reset_password, additional_keywords: { temporary_reset_pin: pin_code })
  end

  private

  def eligible_for_reactivation?
    return true if suspended?
    return true unless terminated_on
    terminated_on >= 90.days.ago.to_date
  end

  def notify_employee(message_type, additional_keywords: {})
    Message.create_message(
      to: person,
      message_type:,
      keywords: {
        first_name: person.first_name,
        employer_name: company.name
      }.merge(additional_keywords)
    )
  end
end
```

## Event Monitoring Example

Set up comprehensive monitoring:

```ruby
# config/initializers/event_subscribers.rb

# Success tracking
ActiveSupport::Notifications.subscribe(/employee\.\w+\.success/) do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  payload = event.payload

  Rails.logger.info(
    "[EmployeeLifecycle] Employee ##{payload[:record_id]} transitioned: " \
    "#{payload[:from_state]} -> #{payload[:to_state]} (#{payload[:event]})"
  )

  # Send to Slack, DataDog, etc.
  SlackNotifier.notify(
    channel: "#employee-lifecycle",
    message: "Employee #{payload[:record].name} was #{payload[:event]}ed"
  )
end

# Failure tracking
ActiveSupport::Notifications.subscribe(/employee\.\w+\.(invalid|failed)/) do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  payload = event.payload

  Sentry.capture_message(
    "Employee lifecycle transition failed",
    level: :warning,
    extra: {
      employee_id: payload[:record_id],
      from_state: payload[:from_state],
      to_state: payload[:to_state],
      event: payload[:event]
    },
    tags: {
      event_type: "lifecycle_transition_failed",
      transition: payload[:event].to_s
    }
  )
end
```

## Testing

SimpleState makes testing easy:

```ruby
RSpec.describe Order, type: :model do
  describe "#process" do
    it "transitions from pending to processing" do
      order = create(:order, status: :pending)

      expect { order.process }.to change { order.status }
        .from("pending").to("processing")
    end

    it "sets processing_at timestamp" do
      order = create(:order, status: :pending)
      order.process

      expect(order.processing_at).to be_present
    end

    it "fails when not in pending state" do
      order = create(:order, status: :completed)

      expect { order.process }.to raise_error(SimpleState::TransitionError)
      expect(order.reload.status).to eq("completed")
    end

    it "publishes success event" do
      order = create(:order, status: :pending)

      expect {
        order.process
      }.to have_published_event("order.process.success")
    end
  end

  describe "#can_transition?" do
    it "returns true for valid transitions" do
      order = create(:order, status: :pending)

      expect(order.can_transition?(:process)).to be true
      expect(order.can_transition?(:complete)).to be false
    end
  end
end
```

## Best Practices

1. **Keep Guards Simple**: Guards should be fast, synchronous checks. Move complex logic to callbacks.

2. **Use Events for Monitoring**: Subscribe to transition events for logging, metrics, and alerts.

3. **Validate States at Boot**: SimpleState validates states when the class loads, catching configuration errors early.

4. **Handle Failures Gracefully**: All transitions are wrapped in transactions and rollback automatically.

5. **Test State Transitions**: Use `can_transition?` to test guard logic independently.

## Requirements

- Ruby >= 3.4
- Rails >= 7.1 (ActiveRecord + ActiveSupport)

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/mundanecodes/simple_state.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
