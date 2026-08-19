class AllowPartialTailorSessionDrafts < ActiveRecord::Migration[8.0]
  # A record is now saved as a draft before the provider call, so a transient API
  # error does not cost the user their pasted JD and uploaded file. That draft may
  # legitimately be missing the resume, the JD, or both.
  def change
    change_column_null :tailor_sessions, :resume_text, true
    change_column_null :tailor_sessions, :jd_text, true
  end
end
