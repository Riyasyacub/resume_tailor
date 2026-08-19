require "test_helper"

class ResumeRewriterTest < ActiveSupport::TestCase
  # --- the forbidden-term guard -------------------------------------------
  #
  # This is the promise the whole tool rests on: a skill the user said they do
  # not have must never reach the output. The prompt asks; this enforces.

  def leaked?(text, forbidden)
    ResumeRewriter.verify_forbidden_absent!({ "body" => text }, [ forbidden ])
    false
  rescue LlmClient::Error
    true
  end

  test "blocks a rejected skill that the model slipped in" do
    assert leaked?("Ran Kubernetes in production", "Kubernetes")
  end

  test "matches regardless of case" do
    assert leaked?("worked with kubernetes daily", "Kubernetes")
  end

  # Regression: \b on both ends never matches a term ending in punctuation, so
  # C++, C# and .NET were waved straight through.
  test "catches terms that start or end with punctuation" do
    assert leaked?("Wrote C++ modules", "C++")
    assert leaked?("Built with .NET Core", ".NET")
    assert leaked?("Used C# heavily", "C#")
    assert leaked?("Node.js services", "Node.js")
  end

  test "does not flag a term that is merely a substring of another word" do
    refute leaked?("Google Cloud Platform", "Go")
    refute leaked?("Javascript and Typescript", "Java")
    refute leaked?("Managed Reactor patterns", "React")
  end

  test "ignores an empty forbidden term" do
    refute leaked?("anything at all", "")
  end

  test "reports which terms leaked" do
    error = assert_raises(LlmClient::Error) do
      ResumeRewriter.verify_forbidden_absent!({ "b" => "Kubernetes and Terraform" }, %w[Kubernetes Terraform Helm])
    end

    assert_match(/Kubernetes/, error.message)
    assert_match(/Terraform/, error.message)
    refute_match(/Helm/, error.message)
  end

  # --- section order ------------------------------------------------------

  ORIGINAL = <<~TXT.freeze
    RIYAS YACUB
    Backend Engineer | FinTech & Payments

    PROFESSIONAL SUMMARY
    Backend Engineer with 5+ years of experience building FinTech systems.

    TECHNICAL SKILLS
    Languages: Ruby, SQL, JavaScript (ES6+)
    Familiar: React, Redux, RSpec

    PROFESSIONAL EXPERIENCE
    Effortless - Backend Engineer

    PROJECTS
    Containerized Rails 8 Deployment

    EDUCATION
    Bachelor of Engineering, 2021

    LANGUAGES
    English - Professional Working Proficiency
  TXT

  def reorder(headings, original = ORIGINAL)
    result = { "sections" => headings.map { |h| { "heading" => h } } }
    ResumeRewriter.restore_original_section_order!(result, original)
    result["sections"].map { |s| s["heading"] }
  end

  # Regression: models drift to the conventional Experience-first layout.
  test "restores the original section order" do
    got = reorder([ "Summary", "Professional Experience", "Technical Skills",
                    "Languages", "Projects", "Education" ])

    assert_equal [ "PROFESSIONAL SUMMARY", "TECHNICAL SKILLS", "PROFESSIONAL EXPERIENCE",
                   "PROJECTS", "EDUCATION", "LANGUAGES" ], got
  end

  # Regression: a "longest word" fallback matched "Professional Experience"
  # against the line "PROFESSIONAL SUMMARY".
  test "does not match a heading against a different heading sharing a word" do
    assert_equal [ "PROFESSIONAL SUMMARY", "PROFESSIONAL EXPERIENCE" ],
                 reorder([ "Summary", "Professional Experience" ])
  end

  # Regression: "Languages" matched the skills label "Languages: Ruby, SQL...",
  # dragging the LANGUAGES section to the top of the resume.
  test "ignores colon-delimited label lines when locating headings" do
    got = reorder([ "Technical Skills", "Languages" ])

    assert_equal [ "TECHNICAL SKILLS", "LANGUAGES" ], got
  end

  test "restores the candidate's own heading wording" do
    assert_equal [ "PROFESSIONAL SUMMARY" ], reorder([ "Summary" ])
    assert_equal [ "TECHNICAL SKILLS" ], reorder([ "Skills" ])
  end

  test "matches when the model emits a longer heading than the original" do
    assert_equal %w[SUMMARY EXPERIENCE],
                 reorder([ "Professional Experience", "Summary" ], "SUMMARY\nx\n\nEXPERIENCE\ny\n")
  end

  test "keeps unmatched sections last in their original relative order" do
    assert_equal [ "EDUCATION", "Volunteering", "Awards" ],
                 reorder([ "Volunteering", "Education", "Awards" ])
  end

  test "leaves a single section untouched" do
    assert_equal [ "PROJECTS" ], reorder([ "Projects" ])
  end

  test "does not assign two sections to the same original heading" do
    got = reorder([ "Summary", "Professional Summary" ])

    assert_equal 2, got.size
    assert_equal 2, got.uniq.size, "two sections collapsed onto the same heading"
  end
end
