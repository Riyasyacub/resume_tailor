class TailorSession < ApplicationRecord
  # No presence validation: a record is saved as a draft before the API call so a
  # failed request does not cost the user their pasted JD and uploaded file. The
  # controller enforces what must be present before analysis actually runs.

  # A draft is an input we kept but never got an answer for.
  def draft? = analysis.blank?

  def resume_attached? = resume_text.present?

  # Keywords the JD asks for that the resume does not already contain.
  def missing_keywords
    keywords.reject { |k| k["in_resume"] }
  end

  def present_keywords
    keywords.select { |k| k["in_resume"] }
  end

  def keywords
    (analysis || {})["keywords"] || []
  end

  def jd_title
    (analysis || {})["jd_title"].presence || "this role"
  end

  # Coverage before the user confirms anything.
  def baseline_coverage
    return 0 if keywords.empty?
    (present_keywords.size * 100.0 / keywords.size).round
  end

  # Coverage after adding whatever the user affirmed.
  def projected_coverage
    return baseline_coverage if confirmations.blank?
    covered = present_keywords.size + confirmed_terms.size
    return 0 if keywords.empty?
    [ (covered * 100.0 / keywords.size).round, 100 ].min
  end

  def confirmed_terms
    confirmed_entries.map { |c| c["term"] }
  end

  def confirmed_entries
    (confirmations || {}).fetch("confirmed", [])
  end

  # Lets the review page reopen with the user's previous answers still ticked.
  def confirmation_for(term)
    confirmed_entries.find { |c| c["term"] == term }
  end

  def rejected_terms
    (confirmations || {}).fetch("rejected", [])
  end

  # Keywords the JD wants that the user said they do not have.
  def gaps
    rejected = rejected_terms
    keywords.select { |k| rejected.include?(k["term"]) }
  end

  def generated?
    result.present?
  end
end
