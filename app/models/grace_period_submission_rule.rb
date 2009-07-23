class GracePeriodSubmissionRule < SubmissionRule
  
  #validates_numericality_of :grace_day_limit, :only_integer => true, 
  #  :greater_than_or_equal_to => 0
     
  def calculate_collection_time
    return assignment.due_date + self.hours_sum.hours
  end
  
  def hours_sum
    return periods.sum('hours')
  end
  
  # When Students commit code after the collection time, MarkUs should warn
  # the Students with a message saying that the due date has passed, and the
  # work they're submitting will probably not be graded
  def commit_after_collection_message(grouping)
    I18n.t 'submission_rules.grace_day_submission_rule.commit_after_collection_message'
  end
  
  # This message will be dislayed to Students on viewing their file manager
  # after the due date has passed, but before the calculated collection date.
  def overtime_message(grouping)
    # We need to know how many grace days this grouping has left...
#    grace_days_remaining = ?
    grace_days_to_use = (self.calculate_collection_time.to_date - Time.now.to_date).to_i
    if grace_days_to_use > self.grace_day_limit
      grace_days_to_use = self.grace_day_limit
    end
    # TODO:  This is where you stopped working.    
    if grace_days_remaining < grace_days_to_use
      # This grouping doesn't have any more grace days to spend
      return I18n.t 'submission_rules.grace_day_submission_rule.overtime_message_without_days_left'
    else
      # This grouping has some grace days to spend.
      return I18n.t 'submission_rules.grace_day_submission_rule.overtime_message_with_days_left'
    end
  end
  
  # NullSubmissionRule works with all Assignments
  def assignment_valid?
    return !assignment.nil?
  end

  def apply_submission_rule(submission)
    # If we aren't overtime, we don't need to apply a rule
    return submission if submission.revision_timestamp <= assignment.due_date
    
    # So we're overtime.  How far are we overtime?
    collection_time = submission.revision_timestamp
    due_date = assignment.due_date
    
    overtime_hours = ((collection_time - due_date) / 1.hour).ceil
    
    # Now we need to figure out how many Grace Credits to deduct
    deduction_amount = calculate_deduction_amount(overtime_hours)
    
    # Deduct Grace Credits from every member of the Grouping
    student_memberships = submission.grouping.accepted_student_memberships

    student_memberships.each do |student_membership|
      deduction = GracePeriodDeduction.new   
      deduction.membership = student_membership
      deduction.deduction = deduction_amount
      deduction.save
    end
    
    return submission
  end
  
  def description_of_rule
    I18n.t 'submission_rules.null_submission_rule.description'
  end

  private 
  
  def calculate_deduction_amount(overtime_hours)
    total_deduction = 0
    periods.each do |period|
      total_deduction = total_deduction + period.deduction
      overtime_hours = overtime_hours - period.hours
      break if overtime_hours <= 0
    end
    return total_deduction
  end
 
end