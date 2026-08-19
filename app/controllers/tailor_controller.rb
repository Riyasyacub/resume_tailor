class TailorController < ApplicationController
  before_action :load_session, only: %i[review generate result download]

  # Step 1 — provider, key, resume, JD.
  def new
    @provider = session[:provider] || "claude"
    @model    = session[:model]
    @has_key  = session[:api_key].present?
    @draft    = TailorSession.find_by(id: params[:draft], analysis: nil) if params[:draft].present?
  end

  # Step 2 — parse the resume and ask the model what the JD wants.
  #
  # The draft is saved BEFORE the API call. Providers return transient 503s, and a
  # retry should not cost the user a long JD paste and a re-upload.
  def analyze
    remember_credentials
    draft = load_or_build_draft

    draft.jd_text = params[:jd_text].to_s.strip

    if params[:resume].present?
      draft.resume_text     = ResumeParser.call(params[:resume])
      draft.source_filename = params[:resume].original_filename
    end

    draft.save! # keep whatever we have, whatever happens next

    raise ResumeParser::Error, "Please attach your resume." unless draft.resume_attached?

    if draft.jd_text.length < 100
      return redirect_to root_path(draft: draft.id),
                         alert: "That job description looks too short. Paste the full posting."
    end

    draft.update!(
      analysis: KeywordAnalyzer.call(
        client: build_client, resume_text: draft.resume_text, jd_text: draft.jd_text
      )
    )

    redirect_to review_path(draft)
  rescue ResumeParser::Error, LlmClient::Error => e
    redirect_to root_path(draft: draft&.id), alert: e.message
  rescue StandardError => e
    # Anything unexpected still reaches the user as words rather than a blank 500.
    Rails.logger.error("[analyze] #{e.class}: #{e.message}\n#{e.backtrace&.first(8)&.join("\n")}")
    redirect_to root_path(draft: draft&.id),
                alert: "Something broke while analysing: #{e.class} — #{e.message}"
  end

  # Step 3 — the confirmation checklist.
  #
  # Reachable again after generating, so a wrong tick can be corrected without
  # re-uploading and re-analysing. Regenerating costs one API call, not two.
  def review
  end

  # Step 4 — rewrite, using only what the user affirmed.
  def generate
    confirmed = confirmed_from_params
    rejected  = @tailor_session.missing_keywords.map { |k| k["term"] } - confirmed.map { |c| c["term"] }

    result = ResumeRewriter.call(
      client: build_client,
      session: @tailor_session,
      confirmed:,
      rejected:
    )

    @tailor_session.update!(
      confirmations: { "confirmed" => confirmed, "rejected" => rejected },
      result: result
    )

    redirect_to result_path(@tailor_session)
  rescue LlmClient::Error => e
    redirect_to review_path(@tailor_session), alert: e.message
  rescue StandardError => e
    Rails.logger.error("[generate] #{e.class}: #{e.message}\n#{e.backtrace&.first(8)&.join("\n")}")
    redirect_to review_path(@tailor_session), alert: "Something broke while generating: #{e.class} — #{e.message}"
  end

  def result
    return redirect_to review_path(@tailor_session), alert: "Nothing generated yet." unless @tailor_session.generated?

    @resume   = @tailor_session.result
    @markdown = Renderers::MarkdownRenderer.call(@resume)
  end

  # Step 5 — the user picks the format here, not up front.
  def download
    return redirect_to review_path(@tailor_session) unless @tailor_session.generated?

    resume = @tailor_session.result
    base   = filename_for(resume)

    case params[:format].to_s
    when "docx"
      send_data Renderers::DocxRenderer.call(resume),
                filename: "#{base}.docx",
                type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    when "pdf"
      send_data Renderers::PdfRenderer.call(resume),
                filename: "#{base}.pdf",
                type: "application/pdf"
    when "md"
      send_data Renderers::MarkdownRenderer.call(resume),
                filename: "#{base}.md",
                type: "text/markdown"
    else
      redirect_to result_path(@tailor_session), alert: "Unknown format."
    end
  end

  # Clears the stored API key from the browser session.
  def forget_key
    session.delete(:api_key)
    redirect_to root_path, notice: "API key cleared from this browser session."
  end

  private

  # The form keys checkboxes by their position in missing_keywords, so the term
  # itself never has to survive URL encoding. We resolve index back to term here.
  #
  # Note Array(params[:confirm]) does NOT work: ActionController::Parameters has
  # no to_ary, so Array() wraps it in a one-element array and the block
  # destructures the whole object into the first variable, leaving the rest nil.
  def confirmed_from_params
    raw = params[:confirm]
    return [] if raw.blank?

    missing = @tailor_session.missing_keywords

    to_hash(raw).filter_map do |index, attrs|
      attrs = to_hash(attrs)
      next unless attrs.is_a?(Hash) && attrs["has"].to_s == "1"

      keyword = missing[index.to_i]
      next if keyword.nil?

      { "term" => keyword["term"], "note" => attrs["note"].to_s.strip }
    end
  end

  def to_hash(value)
    value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value
  end

  # Reuse the draft we handed back on the last failure, so a retry keeps the resume
  # already parsed. Only ever reuses one that has not been analysed yet.
  def load_or_build_draft
    TailorSession.find_by(id: params[:draft_id], analysis: nil) || TailorSession.new
  end

  def load_session
    @tailor_session = TailorSession.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to root_path, alert: "That session no longer exists. Start again."
  end

  # The key lives in Rails' encrypted session cookie and is never written to the
  # database. `forget_key` removes it.
  def remember_credentials
    session[:provider] = params[:provider].presence || "claude"
    session[:model]    = params[:model].to_s.strip.presence
    session[:api_key]  = params[:api_key].presence || session[:api_key]
  end

  def build_client
    LlmClient.new(
      provider: session[:provider],
      api_key:  session[:api_key],
      model:    session[:model]
    )
  end

  def filename_for(resume)
    name = resume["name"].to_s.parameterize.presence || "resume"
    "#{name}-tailored"
  end
end
