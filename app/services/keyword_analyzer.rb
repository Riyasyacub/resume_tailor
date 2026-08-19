# Pass 1 — read the JD, pull out what it actually asks for, and check each
# term against the resume. Decides nothing about the rewrite; it only reports.
class KeywordAnalyzer
  SYSTEM = <<~PROMPT.freeze
    You analyse job descriptions for a resume-tailoring tool.

    Extract the concrete, searchable requirements from the job description, then
    check each one against the candidate's current resume.

    What to extract:
      - Hard skills, languages, frameworks, tools, platforms, databases
      - Certifications and qualifications named explicitly
      - Domain or industry experience the JD calls for
      - Methodologies (Agile, TDD, CI/CD, and the like)
      - Only include a soft skill when the JD names it as an explicit requirement

    What to ignore:
      - Company boilerplate, benefits, EEO statements, culture prose
      - Vague filler such as "team player" or "fast-paced environment" unless the JD lists it as a requirement
      - Anything not actually asked for

    Matching rules — be generous but accurate:
      - Treat well-known equivalents as present: "K8s" matches "Kubernetes",
        "JS" matches "JavaScript", "Postgres" matches "PostgreSQL", "GCP" matches "Google Cloud".
      - A skill counts as present if it appears anywhere in the resume, including a skills list.
      - Do NOT count a near-miss as present. React is not React Native. Java is not JavaScript.
        AWS is not Azure. If it is a different technology, it is absent.
      - When the resume shows a term, quote the exact snippet you found it in.

    Return JSON in exactly this shape:

    {
      "jd_title": "the role title from the JD, or null",
      "keywords": [
        {
          "term": "Kubernetes",
          "category": "hard_skill | tool | certification | domain | methodology | soft_skill",
          "importance": "critical | important | nice_to_have",
          "in_resume": false,
          "resume_evidence": null,
          "jd_context": "the phrase from the JD that asks for this"
        }
      ]
    }

    Set importance to "critical" when the JD marks it required or must-have,
    "important" for listed responsibilities, "nice_to_have" for preferred or bonus items.

    Order keywords by importance: critical first, then important, then nice_to_have.
    Extract between 10 and 30 keywords. Do not pad the list.
  PROMPT

  def self.call(client:, resume_text:, jd_text:)
    user = <<~USER
      === JOB DESCRIPTION ===
      #{jd_text}

      === CANDIDATE'S CURRENT RESUME ===
      #{resume_text}
    USER

    result = client.complete_json(system: SYSTEM, user: user)

    raise LlmClient::Error, "The model did not return any keywords." if result["keywords"].blank?

    result["keywords"] = Array(result["keywords"]).map do |k|
      k.merge("in_resume" => !!k["in_resume"])
    end

    result
  end
end
