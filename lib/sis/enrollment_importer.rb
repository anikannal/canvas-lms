#
# Copyright (C) 2011 - 2015 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

require "set"

module SIS
  class EnrollmentImporter < BaseImporter

    def process(messages, updates_every)
      start = Time.now
      i = Work.new(@batch, @root_account, @logger, updates_every, messages)
      # the suspend callbacks is weird with string and symbol because of rails
      # see pp Enrollment.first._save_callbacks.map(&:filter);''
      Enrollment.suspend_callbacks("(belongs_to_touch_after_save_or_destroy_for_course)", :update_cached_due_dates) do
        User.skip_updating_account_associations do
          Enrollment.process_as_sis(@sis_options) do
            yield i
            while i.any_left_to_process?
              i.process_batch
            end
          end
        end
      end
      @logger.debug("Raw enrollments took #{Time.now - start} seconds")
      i.enrollments_to_update_sis_batch_ids.in_groups_of(1000, false) do |batch|
        Enrollment.where(:id => batch).update_all(:sis_batch_id => @batch)
      end if @batch
      # We batch these up at the end because we don't want to keep touching the same course over and over,
      # and to avoid hitting other callbacks for the course (especially broadcast_policy)
      i.courses_to_touch_ids.to_a.in_groups_of(1000, false) do |batch|
        Course.where(id: batch).touch_all
      end
      i.courses_to_recache_due_dates.to_a.in_groups_of(1000, false) do |batch|
        batch.each do |course_id|
          DueDateCacher.recompute_course(course_id)
        end
      end
      # We batch these up at the end because normally a user would get several enrollments, and there's no reason
      # to update their account associations on each one.
      i.incrementally_update_account_associations
      User.update_account_associations(i.update_account_association_user_ids.to_a, :account_chain_cache => i.account_chain_cache)
      i.users_to_touch_ids.to_a.in_groups_of(1000, false) do |batch|
        User.where(id: batch).touch_all
      end
      @logger.debug("Enrollments with batch operations took #{Time.now - start} seconds")
      return i.success_count
    end

  private
    class Work
      attr_accessor :enrollments_to_update_sis_batch_ids, :courses_to_touch_ids,
          :incrementally_update_account_associations_user_ids, :update_account_association_user_ids,
          :account_chain_cache, :users_to_touch_ids, :success_count, :courses_to_recache_due_dates

      def initialize(batch, root_account, logger, updates_every, messages)
        @batch = batch
        @root_account = root_account
        @logger = logger
        @updates_every = updates_every
        @messages = messages

        @update_account_association_user_ids = Set.new
        @incrementally_update_account_associations_user_ids = Set.new
        @users_to_touch_ids = Set.new
        @courses_to_touch_ids = Set.new
        @courses_to_recache_due_dates = Set.new
        @enrollments_to_update_sis_batch_ids = []
        @account_chain_cache = {}
        @course = @section = nil
        @course_roles_by_account_id = {}

        @enrollment_batch = []
        @success_count = 0
      end

      # This method signature is deprecated:
      # add_enrollment(course_id, section_id, user_id, role, status, start_date, end_date, associated_user_id=nil, root_account_id=nil, role_id=nil)
      # Pass a single instance of SIS::Models::Enrollment instead
      def add_enrollment(*enrollment_data)
        if enrollment_data.length == 1
          enrollment = enrollment_data.first
        else
          enrollment = SIS::Models::Enrollment.new(
              {
                  course_id: enrollment_data[0],
                  section_id: enrollment_data[1],
                  user_id: enrollment_data[2],
                  role: enrollment_data[3],
                  status: enrollment_data[4],
                  start_date: enrollment_data[5],
                  end_date: enrollment_data[6],
                  associated_user_id: enrollment_data[7],
                  root_account_id: enrollment_data[8],
                  role_id: enrollment_data[9]
              }
          )
        end

        raise ImportError, "No course_id or section_id given for an enrollment" unless enrollment.valid_context?
        raise ImportError, "No user_id given for an enrollment" unless enrollment.valid_user?
        raise ImportError, "Improper status \"#{enrollment.status}\" for an enrollment" unless enrollment.valid_status?

        @enrollment_batch << enrollment
        process_batch if @enrollment_batch.size >= @updates_every
      end

      def any_left_to_process?
        return @enrollment_batch.size > 0
      end

      def process_batch
        return unless any_left_to_process?

        transaction_timeout = Setting.get('sis_transaction_seconds', '1').to_i.seconds
        Enrollment.transaction do
          tx_end_time = Time.now + transaction_timeout
          enrollment = nil
          while !@enrollment_batch.empty? && tx_end_time > Time.now
            enrollment = @enrollment_batch.shift
            enrollment_array = enrollment.to_a
            @logger.debug("Processing Enrollment #{enrollment_array.inspect}")
            course_id, section_id, user_id, role_name, role_id, status, start_date, end_date, associated_sis_user_id, root_account_sis_id = enrollment_array

            last_section = @section
            # reset the cached course/section if they don't match this row
            if @course && course_id.present? && @course.sis_source_id != course_id
              @course = nil
              @section = nil
            end
            if @section && section_id.present? && @section.sis_source_id != section_id
              @section = nil
            end

            if root_account_sis_id.present?
              root_account = root_account_from_id(root_account_sis_id)
              next unless root_account
            else
              root_account = @root_account
            end

            if !enrollment.user_integration_id.blank?
              pseudo = root_account.pseudonyms.where(integration_id: enrollment.user_integration_id).first
            else
              pseudo = root_account.pseudonyms.where(sis_user_id: user_id).first
            end

            unless pseudo
              @messages << "User #{user_id} didn't exist for user enrollment"
              next
            end

            user = pseudo.user
            if root_account != @root_account
              if !user.find_pseudonym_for_account(@root_account, true)
                @messages << "User #{root_account_sis_id}:#{user_id} does not have a usable login for this account"
                next
              end
            end

            @course ||= @root_account.all_courses.where(sis_source_id: course_id).first unless course_id.blank?
            @section ||= @root_account.course_sections.where(sis_source_id: section_id).first unless section_id.blank?
            unless (@course || @section)
              @messages << "Neither course #{course_id} nor section #{section_id} existed for user enrollment"
              next
            end

            if section_id.present? && !@section
              @messages << "An enrollment referenced a non-existent section #{section_id}"
              next
            end
            if course_id.present? && !@course
              @messages << "An enrollment referenced a non-existent course #{course_id}"
              next
            end

            # reset cached/inferred course and section if they don't match with the opposite piece that was
            # explicitly provided
            @section = @course.default_section(:include_xlists => true) if @section.nil? || section_id.blank? && !@section.default_section
            @course = @section.course if @course.nil? || (course_id.blank? && @course.id != @section.course_id) || (@course.id != @section.course_id && @section.nonxlist_course_id == @course.id)

            if @course.id != @section.course_id
              @messages << "An enrollment listed a section and a course that are unrelated"
              next
            end

            # preload the course object to avoid later queries for it
            @section.course = @course


            # cache available course roles for this account
            @course_roles_by_account_id[@course.account_id] ||= @course.account.available_course_roles

            # commit pending incremental account associations
            incrementally_update_account_associations if @section != last_section and !@incrementally_update_account_associations_user_ids.empty?

            associated_user_id = nil

            role = nil
            role = @course_roles_by_account_id[@course.account_id].detect{|r| r.global_id == Shard.global_id_for(role_id, @course.shard)} if role_id
            role ||= @course_roles_by_account_id[@course.account_id].detect{|r| r.name == role_name}

            type = if role
              role.base_role_type
            else
              if role_name =~ /\Ateacher\z/i
                'TeacherEnrollment'
              elsif role_name =~ /\Astudent/i
                'StudentEnrollment'
              elsif role_name =~ /\Ata\z/i
                'TaEnrollment'
              elsif role_name =~ /\Aobserver\z/i
                'ObserverEnrollment'
              elsif role_name =~ /\Adesigner\z/i
                'DesignerEnrollment'
              end
            end
            unless type
              @messages << "Improper role \"#{role_name}\" for an enrollment"
              next
            end

            role ||= Role.get_built_in_role(type)

            if associated_sis_user_id && type == 'ObserverEnrollment'
              a_pseudo = root_account.pseudonyms.where(sis_user_id: associated_sis_user_id).first
              if a_pseudo
                associated_user_id = a_pseudo.user_id
              else
                @messages << "An enrollment referenced a non-existent associated user #{associated_sis_user_id}"
                next
              end
            end

            enrollment = @section.all_enrollments.where(user_id: user,
                                                        type: type,
                                                        associated_user_id: associated_user_id,
                                                        role_id: role.id).first

            unless enrollment
              enrollment = Enrollment.typed_enrollment(type).new
              enrollment.root_account = @root_account
            end
            enrollment.user = user
            enrollment.sis_source_id = [course_id, user_id, role.id, @section.name].compact.join(":")[0..254]
            enrollment.type = type
            enrollment.associated_user_id = associated_user_id
            enrollment.role = role
            enrollment.course = @course
            enrollment.course_section = @section

            if status =~ /\Aactive/i
              if user.workflow_state != 'deleted' && pseudo.workflow_state != 'deleted'
                enrollment.workflow_state = 'active'
              else
                enrollment.workflow_state = 'deleted'
                @messages << "Attempted enrolling of deleted user #{user_id} in course #{course_id}"
              end
            elsif status =~ /\Adeleted/i
              enrollment.workflow_state = 'deleted'
            elsif status =~ /\Acompleted/i
              enrollment.workflow_state = 'completed'
            elsif status =~ /\Ainactive/i
              enrollment.workflow_state = 'inactive'
            end

            if (enrollment.stuck_sis_fields & [:start_at, :end_at]).empty?
              enrollment.start_at = start_date
              enrollment.end_at = end_date
            end

            @courses_to_touch_ids.add(enrollment.course_id)
            if enrollment.should_update_user_account_association? && !%w{creation_pending deleted}.include?(user.workflow_state)
              if enrollment.new_record? && !@update_account_association_user_ids.include?(user.id)
                @incrementally_update_account_associations_user_ids.add(user.id)
              else
                @update_account_association_user_ids.add(user.id)
              end
            end
            if enrollment.changed?
              @users_to_touch_ids.add(user.id)
              courses_to_recache_due_dates << enrollment.course_id if enrollment.workflow_state_changed?
              enrollment.sis_batch_id = @batch.id if @batch
              begin
                enrollment.save_without_broadcasting!
              rescue ActiveRecord::RecordInvalid
                msg = "An enrollment did not pass validation "
                msg += "(" + "course: #{course_id}, section: #{section_id}, "
                msg += "user: #{user_id}, role: #{role_name}, error: " +
                msg += enrollment.errors.full_messages.join(",") + ")"
                @messages << msg
                next
              end
            elsif @batch
              @enrollments_to_update_sis_batch_ids << enrollment.id
            end

            @success_count += 1
          end
        end
      end

      def root_account_from_id(root_account_sis_id)
        nil
      end

      def incrementally_update_account_associations
        if @incrementally_update_account_associations_user_ids.length < 10
          @update_account_association_user_ids.merge(@incrementally_update_account_associations_user_ids)
        else
          User.update_account_associations(@incrementally_update_account_associations_user_ids.to_a,
              :incremental => true,
              :precalculated_associations => User.calculate_account_associations_from_accounts(
                  [@course.account_id, @section.nonxlist_course.try(:account_id)].compact.uniq,
                          @account_chain_cache
                      ))
        end
        @incrementally_update_account_associations_user_ids = Set.new
      end

    end

  end
end
