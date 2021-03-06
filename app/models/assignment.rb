require 'csv_invalid_line_error'

class Assignment < ActiveRecord::Base

  MARKING_SCHEME_TYPE = {
    flexible: 'flexible',
    rubric: 'rubric'
  }

  has_many :rubric_criteria,
           -> { order(:position) },
           class_name: 'RubricCriterion', 
		   dependent: :destroy

  has_many :flexible_criteria,
           -> { order(:position) },
           class_name: 'FlexibleCriterion',
		   dependent: :destroy

  has_many :criterion_ta_associations,
		   dependent: :destroy

  has_many :assignment_files,
		   dependent: :destroy
  accepts_nested_attributes_for :assignment_files, allow_destroy: true
  validates_associated :assignment_files

  has_many :test_files, dependent: :destroy
  accepts_nested_attributes_for :test_files, allow_destroy: true

  has_one :assignment_stat, dependent: :destroy
  accepts_nested_attributes_for :assignment_stat, allow_destroy: true
  validates_associated :assignment_stat
  # Because of app/views/main/_grade_distribution_graph.html.erb:25
  validates_presence_of :assignment_stat

  has_many :annotation_categories,
           -> { order(:position) },
           class_name: 'AnnotationCategory',
		   dependent: :destroy

  has_many :groupings

  has_many :ta_memberships, through: :groupings
  has_many :student_memberships, through: :groupings
  has_many :tokens, through: :groupings

  has_many :submissions, through: :groupings
  has_many :groups, through: :groupings

  has_many :notes, as: :noteable, dependent: :destroy

  has_many :section_due_dates
  accepts_nested_attributes_for :section_due_dates


  validates_uniqueness_of :short_identifier, case_sensitive: true
  validates_numericality_of :group_min, only_integer: true, greater_than: 0
  validates_numericality_of :group_max, only_integer: true, greater_than: 0
  validates_numericality_of :tokens_per_day, only_integer: true, greater_than_or_equal_to: 0

  has_one :submission_rule, dependent: :destroy, inverse_of: :assignment
  accepts_nested_attributes_for :submission_rule, allow_destroy: true
  validates_associated :submission_rule
  validates_presence_of :submission_rule

  validates_presence_of :short_identifier
  validates_presence_of :description
  validates_presence_of :repository_folder
  validates_presence_of :due_date
  validates_presence_of :marking_scheme_type
  validates_presence_of :group_min
  validates_presence_of :group_max
  validates_presence_of :notes_count
  # "validates_presence_of" for boolean values.
  validates_inclusion_of :allow_web_submits, in: [true, false]
  validates_inclusion_of :display_grader_names_to_students, in: [true, false]
  validates_inclusion_of :is_hidden, in: [true, false]
  validates_inclusion_of :enable_test, in: [true, false]
  validates_inclusion_of :assign_graders_to_criteria, in: [true, false]

  validate :minimum_number_of_groups

  before_save :reset_collection_time

  # Call custom validator in order to validate the :due_date attribute
  # date: true maps to DateValidator (custom_name: true maps to CustomNameValidator)
  # Look in lib/validators/* for more info
  validates :due_date, date: true
  after_save :update_assigned_tokens

  # Set the default order of assignments: in ascending order of due_date
  default_scope { order('due_date ASC') }

  # Export a YAML formatted string created from the assignment rubric criteria.
  def export_rubric_criteria_yml
    criteria = self.rubric_criteria
    final = ActiveSupport::OrderedHash.new
    criteria.each do |criterion|
      inner = ActiveSupport::OrderedHash.new
      inner['weight'] =  criterion['weight']
      inner['level_0'] = {
        'name' =>  criterion['level_0_name'] ,
        'description' =>  criterion['level_0_description']
      }
      inner['level_1'] = {
        'name' =>  criterion['level_1_name'] ,
        'description' =>  criterion['level_1_description']
      }
      inner['level_2'] = {
        'name' =>  criterion['level_2_name'] ,
        'description' =>  criterion['level_2_description']
      }
      inner['level_3'] = {
        'name' =>  criterion['level_3_name'] ,
        'description' =>  criterion['level_3_description']
      }
      inner['level_4'] = {
        'name' =>  criterion['level_4_name'] ,
        'description' => criterion['level_4_description']
      }
      criteria_yml = { "#{criterion['rubric_criterion_name']}" => inner }
      final = final.merge(criteria_yml)
    end
    final.to_yaml
  end

  def minimum_number_of_groups
    if (group_max && group_min) && group_max < group_min
      errors.add(:group_max, 'must be greater than the minimum number of groups')
      false
    end
  end

  # Are we past all the due dates for this assignment?
  def past_all_due_dates?
    # If no section due dates /!\ do not check empty? it could be wrong
    unless self.section_due_dates_type
      return !due_date.nil? && Time.zone.now > due_date
    end

    # If section due dates
    self.section_due_dates.each do |d|
      if !d.due_date.nil? && Time.zone.now > d.due_date
        return true
      end
    end
    false
  end

  # Return an array with names of sections past
  def section_names_past_due_date
    sections_past = []

    unless self.section_due_dates_type
      if !due_date.nil? && Time.zone.now > due_date
        return sections_past << 'Due Date'
      end
    end

    self.section_due_dates.each do |d|
      if !d.due_date.nil? && Time.zone.now > d.due_date
        sections_past << d.section.name
      end
    end

    sections_past
  end

  # Whether or not this grouping is past its due date for this assignment.
  def grouping_past_due_date?(grouping)
    if section_due_dates_type && grouping &&
      grouping.inviter.section.present?

      section_due_date =
        SectionDueDate.due_date_for(grouping.inviter.section, self)
      !section_due_date.nil? && Time.zone.now > section_due_date
    else
      past_all_due_dates?
    end
  end

  def section_due_date(section)
    unless section_due_dates_type && section
      return due_date
    end

    SectionDueDate.due_date_for(section, self)
  end

  # Calculate the latest due date among all sections for the assignment.
  def latest_due_date
    return due_date unless section_due_dates_type

    due_dates = section_due_dates.map(&:due_date) << due_date
    due_dates.compact.max
  end

  def past_collection_date?
    Time.zone.now > submission_rule.calculate_collection_time
  end

  def past_remark_due_date?
    !remark_due_date.nil? && Time.zone.now > remark_due_date
  end

  # Return true if this is a group assignment; false otherwise
  def group_assignment?
    invalid_override || group_max > 1
  end

  # Returns the group by the user for this assignment. If pending=true,
  # it will return the group that the user has a pending invitation to.
  # Returns nil if user does not have a group for this assignment, or if it is
  # not a group assignment
  def group_by(uid, pending=false)
    return unless group_assignment?

    # condition = "memberships.user_id = ?"
    # condition += " and memberships.status != 'rejected'"
    # add non-pending status clause to condition
    # condition += " and memberships.status != 'pending'" unless pending
    # groupings.first(include: :memberships, conditions: [condition, uid]) #FIXME: needs schema update

    #FIXME: needs to be rewritten using a proper query...
    User.find(uid.id).accepted_grouping_for(id)
  end

  def display_for_note
    short_identifier
  end

  def total_mark
    total = 0
    if self.marking_scheme_type == 'rubric'
      rubric_criteria.each do |criterion|
        total = total + criterion.weight * 4
      end
    else
      total = flexible_criteria.sum('max')
    end
    total.round(2)
  end

  # calculates summary statistics of released results for this assignment
  def update_results_stats
    marks = Result.student_marks_by_assignment(id)
    # No marks released for this assignment.
    return false if marks.empty?

    self.results_fails = marks.count { |mark| mark < total_mark / 2.0 }
    self.results_zeros = marks.count(&:zero?)

    # Avoid division by 0.
    self.results_average, self.results_median =
      if total_mark.zero?
        [0, 0]
      else
        # Calculates average and median in percentage.
        [average(marks), median(marks)].map do |stat|
          (stat * 100 / total_mark).round(2)
        end
      end
    self.save
  end

  def average(marks)
    marks.empty? ? 0 : marks.reduce(:+) / marks.size.to_f
  end

  def median(marks)
    count = marks.size
    return 0 if count.zero?

    if count.even?
      average([marks[count/2 - 1], marks[count/2]])
    else
      marks[count/2]
    end
  end

  def self.get_current_assignment
    # start showing (or "featuring") the assignment 3 days before it's due
    # query uses Date.today + 4 because results from db seems to be off by 1
    current_assignment = Assignment.where('due_date <= ?', Date.today + 4)
                                   .reorder('due_date DESC').first

    if current_assignment.nil?
      current_assignment = Assignment.reorder('due_date ASC').first
    end

    current_assignment
  end

  def update_remark_request_count
    outstanding_count = 0
    groupings.each do |grouping|
      submission = grouping.current_submission_used
      if !submission.nil? && submission.has_remark?
        if submission.remark_result.marking_state ==
            Result::MARKING_STATES[:partial]
          outstanding_count += 1
        end
      end
    end
    self.outstanding_remark_request_count = outstanding_count
    self.save
  end

  def total_criteria_weight
    factor = 10.0 ** 2
    (rubric_criteria.sum('weight') * factor).floor / factor
  end

  def add_group(new_group_name=nil)
    if group_name_autogenerated
      group = Group.new
      group.save(validate: false)
      group.group_name = group.get_autogenerated_group_name
      group.save
    else
      return if new_group_name.nil?
      if group = Group.where(group_name: new_group_name).first
        unless groupings.where(group_id: group.id).first.nil?
          raise "Group #{new_group_name} already exists"
        end
      else
        group = Group.create(group_name: new_group_name)
      end
    end
    group.set_repo_permissions
    Grouping.create(group: group, assignment: self)
  end


  # Create all the groupings for an assignment where students don't work
  # in groups.
  def create_groupings_when_students_work_alone
     @students = Student.all
     for student in @students do
       unless student.has_accepted_grouping_for?(self.id)
        student.create_group_for_working_alone_student(self.id)
       end
     end
  end

  # Clones the Groupings from the assignment with id assignment_id
  # into self.  Destroys any previously existing Groupings associated
  # with this Assignment
  def clone_groupings_from(assignment_id)
    original_assignment = Assignment.find(assignment_id)
    self.transaction do
      self.group_min = original_assignment.group_min
      self.group_max = original_assignment.group_max
      self.student_form_groups = original_assignment.student_form_groups
      self.group_name_autogenerated = original_assignment.group_name_autogenerated
      self.group_name_displayed = original_assignment.group_name_displayed
      self.groupings.destroy_all
      self.save
      self.reload
      original_assignment.groupings.each do |g|
        unhidden_student_memberships = g.accepted_student_memberships.select do |m|
          !m.user.hidden
        end
        unhidden_ta_memberships = g.ta_memberships.select do |m|
          !m.user.hidden
        end
        #create the memberships for any user that is not hidden
        unless unhidden_student_memberships.empty?
          #create the groupings
          grouping = Grouping.new
          grouping.group_id = g.group_id
          grouping.assignment_id = self.id
          grouping.admin_approved = g.admin_approved
          raise 'Could not save grouping' if !grouping.save
          all_memberships = unhidden_student_memberships + unhidden_ta_memberships
          all_memberships.each do |m|
            membership = Membership.new
            membership.user_id = m.user_id
            membership.type = m.type
            membership.membership_status = m.membership_status
            raise 'Could not save membership' if !(grouping.memberships << membership)
          end
          # Ensure all student members have permissions on their group repositories
          grouping.update_repository_permissions
        end
      end
    end
  end

  # Add a group and corresponding grouping as provided in
  # the passed in Array.
  # Format: [ groupname, repo_name, member, member, etc ]
  # Any member names that do not exist in the database will simply be ignored
  # (This makes it possible to have empty groups created from a bad csv row)
  def add_csv_group(row)
    return if row.length.zero?

    row.map! { |item| item.strip }

    # Note: We cannot use find_or_create_by here, because it has its own
    # save semantics. We need to set and save attributes in a very particular
    # order, so that everything works the way we want it to.
    group = Group.where(group_name: row.first).first
    if group.nil?
      group = Group.new
      group.group_name = row[0]
    end

    # Since repo_name of "group" will be set before the first save call, the
    # set repo_name will be used instead of the autogenerated name. See
    # set_repo_name and build_repository in the groups model. Also, see
    # create_group_for_working_alone_student in the students model for
    # similar semantics.
    if is_candidate_for_setting_custom_repo_name?(row)
      # Do this only if user_name exists and is a student.
      if Student.where(user_name: row[2]).first
        group.repo_name = row[0]
      else
        # Student name does not exist, use provided repo_name
        group.repo_name = row[1]
      end
    end

    # If we are not repository admin, set the repository name as provided
    # in the csv upload file
    unless group.repository_admin?
      group.repo_name = row[1]
    end
    # Note: after_create hook build_repository might raise
    # Repository::RepositoryCollision. If it does, it adds the colliding
    # repo_name to errors.on_base. This is how we can detect repo
    # collisions here. Unfortunately, we can't raise an exception
    # here, because we still want the grouping to be created. This really
    # shouldn't happen anyway, because the lookup earlier should prevent
    # repo collisions e.g. when uploading the same CSV file twice.
    group.save
    unless group.errors[:base].blank?
      collision_error = I18n.t('csv.repo_collision_warning',
                          { repo_name: group.errors.on_base,
                            group_name: row[0] })
    end

    # Create a new Grouping for this assignment and the newly
    # crafted group
    grouping = Grouping.new(assignment: self, group: group)
    grouping.save

    # Form groups
    start_index_group_members = 2 # first field is the group-name, second the repo name, so start at field 3
    (start_index_group_members..(row.length - 1)).each do |i|
      student = Student.where(user_name: row[i])
                       .first
      if student
        if grouping.student_membership_number == 0
          # Add first valid member as inviter to group.
          grouping.group_id = group.id
          grouping.save # grouping has to be saved, before we can add members
          grouping.add_member(student, StudentMembership::STATUSES[:inviter])
        else
          grouping.add_member(student)
        end
      end

    end
    collision_error
  end

  # Updates repository permissions for all groupings of
  # an assignment. This is a handy method, if for example grouping
  # creation/deletion gets rolled back. The rollback does not
  # reestablish proper repository permissions.
  def update_repository_permissions_forall_groupings
    # IMPORTANT: need to reload from DB
    self.reload
    groupings.each do |grouping|
      grouping.update_repository_permissions
    end
  end

  def grouped_students
    student_memberships.map(&:user)
  end

  def ungrouped_students
    Student.where(hidden: false) - grouped_students
  end

  def valid_groupings
    groupings.includes(student_memberships: :user).select do |grouping|
      grouping.admin_approved ||
      grouping.student_memberships.count >= group_min
    end
  end

  def invalid_groupings
    groupings - valid_groupings
  end

  def assigned_groupings
    groupings.joins(:ta_memberships).includes(ta_memberships: :user).uniq
  end

  def unassigned_groupings
    groupings - assigned_groupings
  end

  # Get a list of subversion client commands to be used for scripting
  def get_svn_checkout_commands
    svn_commands = [] # the commands to be exported

    self.groupings.each do |grouping|
      submission = grouping.current_submission_used
      if submission
        svn_commands.push(
          "svn checkout -r #{submission.revision_number} " +
          "#{grouping.group.repository_external_access_url}/" +
          "#{repository_folder} \"#{grouping.group.group_name}\"")
      end
    end
    svn_commands
  end

  # Get a list of group_name, repo-url pairs
  def get_svn_repo_list
    CSV.generate do |csv|
      self.groupings.each do |grouping|
        group = grouping.group
        csv << [group.group_name,group.repository_external_access_url]
      end
    end
  end

  # Get a simple CSV report of marks for this assignment
  def get_simple_csv_report
    students = Student.all
    out_of = self.total_mark
    CSV.generate do |csv|
       students.each do |student|
         final_result = []
         final_result.push(student.user_name)
         grouping = student.accepted_grouping_for(self.id)
         if grouping.nil? || !grouping.has_submission?
           final_result.push('')
         else
           submission = grouping.current_submission_used
           final_result.push(submission.get_latest_result.total_mark / out_of * 100)
         end
         csv << final_result
       end
    end
  end

  # Get a detailed CSV report of marks (includes each criterion)
  # for this assignment. Produces slightly different reports, depending
  # on which criteria type has been used the this assignment.
  def get_detailed_csv_report
    # which marking scheme do we have?
    if self.marking_scheme_type == MARKING_SCHEME_TYPE[:flexible]
      get_detailed_csv_report_flexible
    else
      # default to rubric
      get_detailed_csv_report_rubric
    end
  end

  # Get a detailed CSV report of rubric based marks
  # (includes each criterion) for this assignment.
  # Produces CSV rows such as the following:
  #   student_name,95.22222,3,4,2,5,5,4,0/2
  # Criterion values should be read in pairs. I.e. 2,3 means
  # a student scored 2 for a criterion with weight 3.
  # Last column are grace-credits.
  def get_detailed_csv_report_rubric
    out_of = self.total_mark
    students = Student.all
    rubric_criteria = self.rubric_criteria
    CSV.generate do |csv|
      students.each do |student|
        final_result = []
        final_result.push(student.user_name)
        grouping = student.accepted_grouping_for(self.id)
        if grouping.nil? || !grouping.has_submission?
          # No grouping/no submission
          final_result.push('')                         # total percentage
          rubric_criteria.each do |rubric_criterion|
            final_result.push('')                       # mark
            final_result.push(rubric_criterion.weight)  # weight
          end
          final_result.push('')                         # extra-mark
          final_result.push('')                         # extra-percentage
        else
          submission = grouping.current_submission_used
          final_result.push(submission.get_latest_result.total_mark / out_of * 100)
          rubric_criteria.each do |rubric_criterion|
            mark = submission.get_latest_result
                             .marks
                             .where(markable_id: rubric_criterion.id,
                                    markable_type: 'RubricCriterion')
                             .first
            if mark.nil?
              final_result.push('')
            else
              final_result.push(mark.mark || '')
            end
            final_result.push(rubric_criterion.weight)
          end
          final_result.push(submission.get_latest_result.get_total_extra_points)
          final_result.push(submission.get_latest_result.get_total_extra_percentage)
        end
        # push grace credits info
        grace_credits_data = student.remaining_grace_credits.to_s + '/' + student.grace_credits.to_s
        final_result.push(grace_credits_data)

        csv << final_result
      end
    end
  end

  # Get a detailed CSV report of flexible criteria based marks
  # (includes each criterion, with it's out-of value) for this assignment.
  # Produces CSV rows such as the following:
  #   student_name,95.22222,3,4,2,5,5,4,0/2
  # Criterion values should be read in pairs. I.e. 2,3 means 2 out-of 3.
  # Last column are grace-credits.
  def get_detailed_csv_report_flexible
    out_of = self.total_mark
    students = Student.all
    flexible_criteria = self.flexible_criteria
    CSV.generate do |csv|
      students.each do |student|
        final_result = []
        final_result.push(student.user_name)
        grouping = student.accepted_grouping_for(self.id)
        if grouping.nil? || !grouping.has_submission?
          # No grouping/no submission
          final_result.push('')                 # total percentage
          flexible_criteria.each do |criterion| ##  empty criteria
            final_result.push('')               # mark
            final_result.push(criterion.max)    # out-of
          end
          final_result.push('')                 # extra-marks
          final_result.push('')                 # extra-percentage
        else
          # Fill in actual values, since we have a grouping
          # and a submission.
          submission = grouping.current_submission_used
          final_result.push(submission.get_latest_result.total_mark / out_of * 100)
          flexible_criteria.each do |criterion|
            mark = submission.get_latest_result
                             .marks
                             .where(markable_id: criterion.id,
                                    markable_type: 'FlexibleCriterion')
                             .first
            if mark.nil?
              final_result.push('')
            else
              final_result.push(mark.mark || '')
            end
            final_result.push(criterion.max)
          end
          final_result.push(submission.get_latest_result.get_total_extra_points)
          final_result.push(submission.get_latest_result.get_total_extra_percentage)
        end
        # push grace credits info
        grace_credits_data = student.remaining_grace_credits.to_s + '/' + student.grace_credits.to_s
        final_result.push(grace_credits_data)

        csv << final_result
      end
    end
  end

  def replace_submission_rule(new_submission_rule)
    if self.submission_rule.nil?
      self.submission_rule = new_submission_rule
      self.save
    else
      self.submission_rule.destroy
      self.submission_rule = new_submission_rule
      self.save
    end
  end

  def next_criterion_position
    # We're using count here because this fires off a DB query, thus
    # grabbing the most up-to-date count of the rubric criteria.
    self.rubric_criteria.count + 1
  end

  # Returns the class of the criteria that belong to this assignment.
  def criterion_class
    if marking_scheme_type == MARKING_SCHEME_TYPE[:flexible]
      FlexibleCriterion
    elsif marking_scheme_type == MARKING_SCHEME_TYPE[:rubric]
      RubricCriterion
    else
      nil
    end
  end

  def get_criteria
    if self.marking_scheme_type == 'rubric'
      self.rubric_criteria
    else
      self.flexible_criteria
    end
  end

  def criteria_count
    if self.marking_scheme_type == 'rubric'
      self.rubric_criteria.size
    else
      self.flexible_criteria.size
    end
  end

  # Returns an array with the number of groupings who scored between
  # certain percentage ranges [0-5%, 6-10%, ...]
  # intervals defaults to 20
  def grade_distribution_as_percentage(intervals=20)
    distribution = Array.new(intervals, 0)
    out_of = self.total_mark

    if out_of == 0
      return distribution
    end

    steps = 100 / intervals # number of percentage steps in each interval
    groupings = self.groupings.includes([{current_submission_used: :results}])

    groupings.each do |grouping|
      submission = grouping.current_submission_used
      if submission && submission.has_result?
        result = submission.get_latest_completed_result
        unless result.nil?
          percentage = (result.total_mark / out_of * 100).ceil
          if percentage == 0
            distribution[0] += 1
          elsif percentage >= 100
            distribution[intervals - 1] += 1
          elsif (percentage % steps) == 0
            distribution[percentage / steps - 1] += 1
          else
            distribution[percentage / steps] += 1
          end
        end
      end
    end # end of groupings loop

    distribution
  end

  # Returns all the TAs associated with the assignment
  def tas
    Ta.find(ta_memberships.map(&:user_id))
  end

  # Returns all the submissions that have been graded (completed)
  def graded_submission_results
    results = []
    groupings.each do |grouping|
      if grouping.marking_completed?
        submission = grouping.current_submission_used
        results.push(submission.get_latest_result) unless submission.nil?
      end
    end
    results
  end

  def groups_submitted
    groupings.select(&:has_submission?)
  end

  private

  # Returns true if we are safe to set the repository name
  # to a non-autogenerated value. Called by add_csv_group.
  def is_candidate_for_setting_custom_repo_name?(row)
    # Repository name can be customized if
    #  - this assignment is set up to allow external submits only
    #  - group_max = 1
    #  - there's only one student member in this row of the csv and
    #  - the group name is equal to the only group member
    if MarkusConfigurator.markus_config_repository_admin? &&
       self.allow_web_submits == false &&
       row.length == 3 && self.group_max == 1 &&
       !row[2].blank? && row[0] == row[2]
      true
    else
      false
    end
  end

  def reset_collection_time
    submission_rule.reset_collection_time
  end

  def update_assigned_tokens
    self.tokens.each do |t|
      t.update_tokens(tokens_per_day_was, tokens_per_day)
    end
  end
end
