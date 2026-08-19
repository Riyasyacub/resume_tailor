require "test_helper"

class TailorControllerTest < ActionDispatch::IntegrationTest
  RESUME_TEXT = ("Riyas Yacub\nSUMMARY\nBackend engineer.\n\nSKILLS\nRuby, Go, PostgreSQL\n\n" \
                 "EXPERIENCE\nBackend Engineer, Effortless, June 2022 - Present.\n").freeze
  JD = ("Senior Platform Engineer. Requires Kubernetes, Terraform, Go, PostgreSQL, " \
        "CI/CD pipelines, AWS, Prometheus, Docker and Linux. Five years experience needed.").freeze

  ANALYSIS = {
    "jd_title" => "Senior Platform Engineer",
    "keywords" => [
      { "term" => "Go", "category" => "hard_skill", "importance" => "critical",
        "in_resume" => true, "resume_evidence" => "Ruby, Go" },
      { "term" => "Kubernetes", "category" => "tool", "importance" => "critical",
        "in_resume" => false, "jd_context" => "Requires Kubernetes" },
      { "term" => "C++", "category" => "hard_skill", "importance" => "nice_to_have",
        "in_resume" => false, "jd_context" => "C++ a plus" },
      { "term" => "Terraform", "category" => "tool", "importance" => "important",
        "in_resume" => false, "jd_context" => "Terraform" }
    ]
  }.freeze

  REWRITE = {
    "name" => "Riyas Yacub", "contact" => [ "riyas@example.com" ], "summary" => "Backend engineer.",
    "sections" => [ { "heading" => "EXPERIENCE", "type" => "entries",
                      "entries" => [ { "title" => "Backend Engineer", "org" => "Effortless",
                                       "bullets" => [ "Ran Kubernetes workloads" ] } ] } ],
    "changes" => [ { "term" => "Kubernetes", "placement" => "Effortless",
                     "before" => "Ran containers", "after" => "Ran Kubernetes workloads" } ]
  }.freeze

  def upload(name = "resume.txt", body = RESUME_TEXT)
    Rack::Test::UploadedFile.new(StringIO.new(body), "text/plain", original_filename: name)
  end

  def analysed_session(attrs = {})
    TailorSession.create!({ resume_text: RESUME_TEXT, jd_text: JD, analysis: ANALYSIS }.merge(attrs))
  end

  # Counts controls per <form>, so a nested form that truncates the outer one
  # is visible. Regression: button_to inside the main form emitted a nested
  # <form>, which browsers resolve by closing the outer one early — dropping the
  # file input, the JD textarea and the submit button out of it entirely.
  def controls_by_form(html)
    forms = Hash.new { |h, k| h[k] = [] }
    stack = []
    nested = []

    html.scan(%r{<(/?)(form|input|textarea|select|button)\b([^>]*)>}m) do |closing, tag, attrs|
      if tag == "form"
        if closing == "/"
          stack.pop
        else
          nested << attrs if stack.any?
          key = attrs[/id="([^"]+)"/, 1] || attrs[/action="([^"]+)"/, 1]
          stack.push(key)
          forms[key] ||= []
        end
      elsif closing != "/"
        name = attrs[/name="([^"]+)"/, 1] || attrs[/type="([^"]+)"/, 1]
        target = attrs[/\bform="([^"]+)"/, 1] || stack.last
        (target ? forms[target] : forms[:orphan]) << name
      end
    end

    [ forms, nested ]
  end

  # --- form structure -----------------------------------------------------

  test "every control on the home page sits inside the analyse form" do
    get root_path
    forms, nested = controls_by_form(response.body)

    assert_empty nested, "nested <form> found; browsers will truncate the outer form"
    assert_empty forms[:orphan], "controls rendered outside any form"
    assert_includes forms["/analyze"], "resume"
    assert_includes forms["/analyze"], "jd_text"
    assert_includes forms["/analyze"], "submit"
  end

  test "the forget-key button does not nest a form inside the analyse form" do
    stub_llm_error("nope") do
      post analyze_path, params: { provider: "claude", api_key: "sk-test", jd_text: JD, resume: upload }
    end

    get root_path
    assert_includes response.body, "Forget it", "precondition: the key is remembered"

    forms, nested = controls_by_form(response.body)
    assert_empty nested
    assert_includes forms["/analyze"], "resume"
    assert_includes forms["/analyze"], "jd_text"
  end

  # --- analyze ------------------------------------------------------------

  test "analyse stores the analysis and moves to review" do
    stub_llm(ANALYSIS.deep_dup) do
      post analyze_path, params: { provider: "claude", api_key: "sk-test", jd_text: JD, resume: upload }
    end

    session_record = TailorSession.last
    assert_redirected_to review_path(session_record)
    assert_equal "Senior Platform Engineer", session_record.analysis["jd_title"]
  end

  # Regression: a failed call redirected to a bare root_path, so a transient 503
  # cost the user their pasted JD and their upload.
  test "a provider failure keeps the jd and the parsed resume" do
    stub_llm_error("Gemini returned 503") do
      post analyze_path, params: { provider: "gemini", api_key: "k", jd_text: JD, resume: upload }
    end

    draft = TailorSession.last
    assert_redirected_to root_path(draft: draft.id)
    assert_equal JD, draft.jd_text
    assert_equal RESUME_TEXT.strip, draft.resume_text

    follow_redirect!
    assert_includes response.body, "Still using"
    assert_includes response.body, "resume.txt"
    assert_includes response.body, ERB::Util.html_escape(JD)
  end

  test "retrying reuses the draft instead of creating another row" do
    stub_llm_error("503") do
      post analyze_path, params: { provider: "claude", api_key: "k", jd_text: JD, resume: upload }
    end
    draft = TailorSession.last

    assert_no_difference "TailorSession.count" do
      stub_llm_error("503 again") do
        post analyze_path, params: { provider: "claude", api_key: "k", jd_text: JD, draft_id: draft.id }
      end
    end

    assert_equal RESUME_TEXT.strip, draft.reload.resume_text, "resume survived a retry with no re-upload"
  end

  # Regression: the columns were NOT NULL, so saving a resume-less draft raised
  # and the JD was lost anyway.
  test "a missing resume still preserves the pasted jd" do
    post analyze_path, params: { provider: "claude", api_key: "k", jd_text: JD }

    draft = TailorSession.last
    assert_redirected_to root_path(draft: draft.id)
    assert_equal JD, draft.jd_text
    assert_nil draft.resume_text
    follow_redirect!
    assert_includes response.body, "Please attach your resume."
  end

  test "a too-short jd is rejected without calling the provider" do
    post analyze_path, params: { provider: "claude", api_key: "k", jd_text: "too short", resume: upload }

    follow_redirect!
    assert_includes response.body, "too short"
  end

  test "an analysed session is never reused as a draft" do
    done = analysed_session
    get root_path(draft: done.id)

    refute_includes response.body, "Still using"
  end

  test "a stale or malformed draft id does not raise" do
    [ "99999", "abc", "" ].each do |value|
      get root_path(draft: value)
      assert_response :success
    end
  end

  # --- generate -----------------------------------------------------------

  # Regression: Array(params[:confirm]) wrapped ActionController::Parameters in a
  # one-element array, so the block destructured the whole object and attrs was nil.
  test "generate resolves ticked indexes back to their terms" do
    record = analysed_session

    stub_llm(REWRITE.deep_dup) do
      post generate_path(record), params: {
        confirm: { "0" => { "has" => "1", "note" => "Daily at Effortless" },
                   "1" => { "has" => "1", "note" => "" },
                   "2" => { "note" => "" } }
      }
    end

    record.reload
    assert_redirected_to result_path(record)
    assert_equal [ "Kubernetes", "C++" ], record.confirmed_terms, "index -> term lookup, C++ intact"
    assert_equal [ "Terraform" ], record.confirmations["rejected"]
    assert_equal "Daily at Effortless", record.confirmation_for("Kubernetes")["note"]
  end

  test "generate treats nothing ticked as everything rejected" do
    record = analysed_session

    # No confirmed skills, so the output must mention none of them — including in
    # the changes list, which the guard also scans.
    clean = REWRITE.merge(
      "sections" => [ { "heading" => "EXPERIENCE", "type" => "entries",
                        "entries" => [ { "title" => "Eng", "org" => "E", "bullets" => [ "worked" ] } ] } ],
      "changes" => []
    )

    stub_llm(clean) { post generate_path(record), params: {} }

    assert_equal [], record.reload.confirmed_terms
    assert_equal [ "Kubernetes", "C++", "Terraform" ], record.confirmations["rejected"]
  end

  test "generate refuses output containing a rejected skill" do
    record = analysed_session
    leaky = REWRITE.deep_dup
    leaky["sections"][0]["entries"][0]["bullets"] = [ "Ran Kubernetes and Terraform" ]

    stub_llm(leaky) { post generate_path(record), params: { confirm: { "0" => { "has" => "1" } } } }

    assert_redirected_to review_path(record)
    assert_nil record.reload.result, "nothing was saved after a leak"
    follow_redirect!
    assert_includes response.body, "Terraform"
  end

  test "an out of range index is ignored" do
    record = analysed_session

    stub_llm(REWRITE.deep_dup) { post generate_path(record), params: { confirm: { "99" => { "has" => "1" } } } }

    assert_equal [], record.reload.confirmed_terms
  end

  # --- review and regenerate ----------------------------------------------

  test "review stays reachable after generating and keeps prior answers ticked" do
    record = analysed_session(
      confirmations: { "confirmed" => [ { "term" => "Kubernetes", "note" => "Daily at Effortless" } ],
                       "rejected" => [ "C++", "Terraform" ] },
      result: REWRITE.deep_dup
    )

    get review_path(record)

    assert_response :success, "review must not bounce to the result page"
    assert_includes response.body, "Regenerate with these answers"
    assert_includes response.body, "Daily at Effortless"
    assert_match(/name="confirm\[0\]\[has\]"[^>]*checked/, response.body)
    refute_match(/name="confirm\[2\]\[has\]"[^>]*checked/, response.body)
  end

  test "the result page links back to review" do
    record = analysed_session(confirmations: { "confirmed" => [], "rejected" => [] }, result: REWRITE.deep_dup)

    get result_path(record)

    assert_response :success
    assert_includes response.body, review_path(record)
  end

  # --- downloads ----------------------------------------------------------

  test "downloads each format with the right content type" do
    record = analysed_session(confirmations: { "confirmed" => [], "rejected" => [] }, result: REWRITE.deep_dup)

    { "docx" => "wordprocessingml", "pdf" => "application/pdf", "md" => "text/markdown" }.each do |fmt, type|
      get download_path(record, format: fmt)

      assert_response :success
      assert_includes response.media_type, type.split("/").last.split(";").first
      assert_operator response.body.bytesize, :>, 100, "#{fmt} looks empty"
    end
  end

  test "an unknown download format is not routable" do
    %w[docx pdf md].each do |fmt|
      assert Rails.application.routes.recognize_path("/sessions/1/download/#{fmt}", method: :get)
    end

    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/sessions/1/download/exe", method: :get)
    end
  end

  test "downloading before generating sends you back to review" do
    record = analysed_session

    get download_path(record, format: "docx")

    assert_redirected_to review_path(record)
  end

  test "a missing session redirects home instead of raising" do
    get review_path(id: 999_999)

    assert_redirected_to root_path
  end
end
