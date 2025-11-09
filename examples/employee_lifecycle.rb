# Example 1: Employee Lifecycle (Single State Column)
#
# This example demonstrates a complete employee lifecycle management system
# using a single state column to track the employee's status through various
# stages: from creation, through invitation, enrollment, suspension, and
# potential termination or reactivation.
#
# Key features demonstrated:
# - Single state column (state) managing the entire lifecycle
# - Timestamp tracking for each transition
# - Guard conditions for business rules (reactivation eligibility)
# - Callbacks for notifications and system actions
# - Complex reactivation logic based on termination date

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

# Usage Examples
# ==============

# Create and invite an employee
employee = Employee.create!(state: :created, person: person, company: company)
employee.invite
# => state: :invited, invited_on: 2025-01-15 10:00:00 UTC
# => Sends invitation notification

# Enroll the employee (assumes separate enrollment transition defined)
employee.enroll
# => state: :enrolled, enrolled_on: 2025-01-16 09:00:00 UTC

# Suspend the employee
employee.suspend
# => state: :suspended, suspended_on: 2025-02-01 14:30:00 UTC
# => Sends suspension notification
# => Disables system access

# Reactivate from suspension (guard passes)
employee.reactivate
# => state: :enrolled, enrolled_on: 2025-02-10 08:00:00 UTC
# => Sends reactivation notification
# => Restores system access

# Terminate the employee
employee.terminate
# => state: :terminated, terminated_on: 2025-03-01 17:00:00 UTC
# => Sends termination notification
# => Disables system access
# => Archives employee data

# Attempt reactivation after 100 days (guard fails)
employee.update!(terminated_on: 100.days.ago)
employee.can_transition?(:reactivate)  # => false
employee.reactivate  # => raises SimpleState::TransitionError

# Reactivation within 90 days (guard passes)
employee.update!(terminated_on: 30.days.ago)
employee.can_transition?(:reactivate)  # => true
employee.reactivate  # => state: :enrolled

# PIN reset flow
employee.reset_pin
# => state: :reset_pin
# => Generates OTP and sends notification with temporary PIN
