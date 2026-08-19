# Pass 2 — rewrite the resume so the terms the user *confirmed they have*
# appear in it naturally. The honesty rules below are the point of this tool.
class ResumeRewriter
  SYSTEM = <<~PROMPT.freeze
    You rewrite a resume so that skills the candidate genuinely has are stated in the
    language a specific job description uses. You are a rephraser, not an author.

    ## Absolute rules — breaking any of these makes the output useless

    1. NEVER invent an employer, job title, date, degree, certification, client, or metric.
    2. NEVER add a keyword from the FORBIDDEN list. The candidate told us they do not have it.
       It must not appear anywhere in the output, in any form or abbreviation.
    3. ONLY add a keyword from the CONFIRMED list, and only where the candidate said they used it.
       The candidate's note tells you which role or project it belongs to. Put it there and nowhere else.
    4. If a candidate's note is vague or you cannot place a term truthfully in a specific role,
       put it in the Skills section instead. Never guess at a bullet.
    5. Do not inflate. "Familiar with X" does not become "expert in X". Seniority, scope,
       team sizes, and numbers stay exactly as the original states them.
    6. Preserve every factual detail from the original: all roles, all dates, all employers,
       all education. You may reorder and rephrase. You may not drop history or invent it.
    7. NEVER change the headline to the job title from the posting. The headline describes
       what the candidate is, not the role they are applying for. Keep theirs as written.
    8. Respect hedging words. If the original says "Familiar:", "Exposure to", "Basic", or
       "Learning", that skill keeps its hedge and never moves into a section that implies
       working proficiency.

    ## Do not lose content — this is where rewrites usually fail

    - **Keep every number.** Volumes, percentages, timings, team sizes, durations, counts.
      "6,000+ voucher entries", "250-300 payments monthly", "zero security incidents",
      "~11s to under 1s", "499-file test suite". These are the strongest lines on any
      resume. Rephrasing is fine; deleting the figure is not.
    - **Keep every outcome clause.** If a bullet says what the work achieved
      ("eliminated 2-3 hours/day of manual work per accountant"), that clause survives.
    - **Keep per-role technology lines.** Many resumes end each role with a "Stack:" or
      "Technologies:" line. Reproduce it as the final bullet of that role. Do not fold it
      into the Skills section and do not drop it.
    - **Keep the summary's specifics.** A summary may be tightened but must retain its
      concrete claims. A generic "experienced engineer with strong skills" rewrite of a
      specific summary is a failure, even though it reads smoothly.

    Length is not the goal. A rewrite shorter than the original has almost certainly
    deleted something the candidate earned.

    ## What you should do

    - Rephrase existing bullets to use the JD's vocabulary where it describes the same work.
      If the resume says "containerised services" and the JD says "Docker", and the candidate
      confirmed Docker, then "Built and deployed Docker containers for..." is a fair rewrite.
    - Fold confirmed terms into the relevant bullets naturally. No keyword lists jammed into prose.
    - Keep bullets achievement-led and concise: one line each where possible, two at most.
    - Keep the summary to 2–3 sentences, aimed at this specific role.

    ## Structure must mirror the original

    - Output sections in EXACTLY the order they appear in the original resume. If the
      original runs Skills, then Education, then Experience, your output does the same.
      Do not reorder to some conventional layout.
    - Keep the candidate's own section headings. If they wrote "Technical Skills",
      do not rename it to "Skills". If they wrote "Professional Experience", keep that.
    - Keep the order of entries within each section as the original has them.
    - The example below shows the JSON shape only. Its section order is NOT a template
      to copy — take the order from the original resume every time.

    ## Output

    Return JSON in exactly this shape:

    {
      "name": "Candidate Name",
      "headline": "Senior Backend Engineer",
      "contact": ["email@example.com", "+91 ...", "City, Country", "linkedin.com/in/...", "github.com/..."],
      "summary": "2-3 sentences.",
      "sections": [
        {
          "heading": "Experience",
          "type": "entries",
          "entries": [
            { "title": "Senior Engineer", "org": "Acme Corp", "location": "Remote",
              "dates": "Mar 2021 - Aug 2024", "bullets": ["...", "..."] }
          ]
        },
        {
          "heading": "Skills",
          "type": "grouped",
          "groups": [ { "label": "Languages", "items": ["Ruby", "Go"] } ]
        },
        {
          "heading": "Education",
          "type": "entries",
          "entries": [ { "title": "B.E. Computer Science", "org": "University",
                         "location": "", "dates": "2016 - 2020", "bullets": [] } ]
        }
      ],
      "changes": [
        { "term": "Kubernetes",
          "placement": "Senior Engineer, Acme Corp",
          "before": "the original bullet text, or null if this is a new Skills entry",
          "after": "the rewritten bullet text" }
      ]
    }

    The "changes" array must record every single edit you made that introduced a confirmed
    term. The candidate reviews this to check you did not overstate anything. Be complete
    and honest here — an unrecorded change is a failure.

    Omit any section that does not exist in the original. Never create an empty section.
  PROMPT

  def self.call(client:, session:, confirmed:, rejected:)
    confirmed_block =
      if confirmed.any?
        confirmed.map { |c|
          note = c["note"].presence || "(no detail given — place in Skills only)"
          "- #{c['term']} — candidate says: #{note}"
        }.join("\n")
      else
        "(none — the candidate confirmed no additional skills. Rewrite for clarity and JD vocabulary only.)"
      end

    forbidden_block = rejected.any? ? rejected.map { |t| "- #{t}" }.join("\n") : "(none)"

    user = <<~USER
      === TARGET JOB DESCRIPTION ===
      #{session.jd_text}

      === ORIGINAL RESUME (the source of truth for all facts) ===
      #{session.resume_text}

      === CONFIRMED — the candidate affirms they have these, add them where indicated ===
      #{confirmed_block}

      === FORBIDDEN — the candidate does NOT have these. They must not appear anywhere ===
      #{forbidden_block}
    USER

    result = client.complete_json(system: SYSTEM, user: user)

    raise LlmClient::Error, "The model returned an empty resume." if result["sections"].blank?

    verify_forbidden_absent!(result, rejected)
    restore_original_section_order!(result, session.resume_text)
    result
  end

  # The prompt tells the model to keep the original section order, but models drift
  # toward the conventional Experience -> Skills -> Education layout regardless.
  # Reorder deterministically by where each heading actually appears in the source.
  def self.restore_original_section_order!(result, resume_text)
    sections = Array(result["sections"])
    return result if sections.empty?
    # Not `size < 2`: a lone section still needs its original heading wording back.

    candidates = heading_candidates(resume_text)
    claimed    = []

    ranked = sections.each_with_index.map do |section, i|
      match = match_heading(candidates, section["heading"], claimed)

      if match
        claimed << match[:index]
        section["heading"] = match[:text] # keep the candidate's own wording
        [ match[:index], i, section ]
      else
        # Headings we cannot locate keep their relative order, after the ones we can.
        [ Float::INFINITY, i, section ]
      end
    end

    result["sections"] = ranked.sort_by { |pos, i, _| [ pos, i ] }.map(&:last)
    result
  end

  # Lines that could plausibly be a section heading. Short, and with no colon —
  # "Languages: Ruby, SQL, JavaScript" is a label inside Skills, not a LANGUAGES
  # heading, and treating it as one drags the wrong section to the top.
  def self.heading_candidates(resume_text)
    resume_text.to_s.each_line.each_with_index.filter_map do |line, index|
      text = line.strip
      next if text.empty? || text.length > 45 || text.include?(":")

      { index: index, text: text, norm: normalise_heading(text) }
    end
  end

  def self.normalise_heading(text)
    text.to_s.downcase.gsub(/[^a-z0-9 ]/, " ").squeeze(" ").strip
  end

  # Three passes, most confident first. Deliberately no "longest word" fallback:
  # that made "Professional Experience" match the line "PROFESSIONAL SUMMARY".
  def self.match_heading(candidates, heading, claimed)
    want = normalise_heading(heading)
    return nil if want.empty?

    free = candidates.reject { |c| claimed.include?(c[:index]) || c[:norm].empty? }
    want_words = want.split.size

    # 1. exact, e.g. "Technical Skills" == "TECHNICAL SKILLS"
    exact = free.find { |c| c[:norm] == want }
    return exact if exact

    # 2. the original carries one extra qualifier: "Summary" -> "Professional Summary"
    wider = free.find do |c|
      c[:norm].split.size <= want_words + 1 && c[:norm].match?(/\b#{Regexp.escape(want)}\b/)
    end
    return wider if wider

    # 3. the reverse: "Professional Experience" -> "EXPERIENCE"
    free.find do |c|
      want_words <= c[:norm].split.size + 1 && want.match?(/\b#{Regexp.escape(c[:norm])}\b/)
    end
  end

  private_class_method :heading_candidates, :normalise_heading, :match_heading

  # Belt and braces: the prompt forbids these, but we check the output too.
  # A leaked forbidden term is the one failure mode that makes the tool lie.
  def self.verify_forbidden_absent!(result, rejected)
    return if rejected.blank?

    haystack = JSON.generate(result).downcase
    leaked = rejected.select { |term| leaked?(haystack, term) }

    return if leaked.empty?

    raise LlmClient::Error,
          "The model added skills you said you don't have (#{leaked.join(', ')}). " \
          "Nothing was saved. Please generate again."
  end

  # A plain \b on both ends silently fails for terms that start or end with a
  # non-word character — \bc\+\+\b never matches "c++", so the guard would wave
  # it through. Only anchor the side that actually has a word character.
  def self.leaked?(haystack, term)
    t = term.to_s.downcase.strip
    return false if t.empty?

    lead  = t.match?(/\A\w/) ? '\b' : ""
    trail = t.match?(/\w\z/) ? '\b' : ""

    haystack.match?(/#{lead}#{Regexp.escape(t)}#{trail}/)
  end
  private_class_method :leaked?
end
