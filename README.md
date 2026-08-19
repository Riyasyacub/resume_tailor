# Resume Tailor

Paste a job description, attach your resume, and get a rewritten resume that uses the
posting's vocabulary — **without inventing anything you didn't do.**

The tool proposes; you confirm. Nothing enters the output unless you tick a box saying
you actually have that skill.

## How it works

1. **Input** — pick a provider (Claude / ChatGPT / Gemini), paste your API key, attach
   your resume (PDF, DOCX, TXT), paste the job description.
2. **Confirm** — the tool lists every term the JD asks for that your resume doesn't use.
   You tick the ones you genuinely have, and say *where* you used each. That placement
   note is what stops the rewrite from guessing which job to attach a skill to.
3. **Download** — DOCX, PDF, or Markdown. Plus a full list of every change made, and a
   gap list of what you said you don't have.

## Running it

```bash
bundle install
bin/rails db:migrate
bin/rails server
```

Open http://localhost:3000

You supply your own API key in the UI. It lives in the encrypted Rails session cookie
for convenience across steps and is **never written to the database**. "Forget it"
on the home page clears it.

## Honesty guarantees

These are the point of the tool, so they're enforced in more than one place:

- **The rewrite prompt** forbids inventing employers, titles, dates, degrees, or metrics,
  and forbids inflating seniority or scope.
- **Unticked terms go on a FORBIDDEN list** passed to the model explicitly.
- **`ResumeRewriter.verify_forbidden_absent!`** re-scans the generated output for every
  forbidden term. If one leaked through, generation fails and nothing is saved. The prompt
  is not trusted on its own.
- **Every change is recorded** and shown to you before/after, so you can check nothing
  overstates what you did.
- **Terms you rejected** appear as a gap list, so you can judge whether the role is worth
  applying to at all.

## A note on "ATS scores"

The UI says *JD keyword coverage*, not "ATS score", because there is no real score to hit.
Applicant tracking systems are databases with search — Greenhouse, Lever, Workday and the
rest don't compute a match percentage and auto-reject below it. That's an industry myth,
largely manufactured by resume-tool marketing.

What's actually true: recruiters keyword-search the database and skim for about seven
seconds. A resume that doesn't visibly use the posting's language gets skipped by a
*human*. Coverage matters — just not for the reason the myth claims.

## Output formats

DOCX is the safest choice for real ATS parsing. All three renderers deliberately produce
flat, single-column documents with no tables, columns, text boxes, or headers/footers —
those are what break parsers.

## Structure

```
app/services/
  llm_client.rb              multi-provider adapter (Claude / OpenAI / Gemini)
  resume_parser.rb           PDF / DOCX / TXT -> plain text, in memory only
  keyword_analyzer.rb        pass 1: what does the JD ask for, what's already covered
  resume_rewriter.rb         pass 2: rewrite using only confirmed skills
  renderers/
    docx_renderer.rb         minimal OOXML, written with rubyzip
    pdf_renderer.rb          prawn
    markdown_renderer.rb
```

Uploaded files are read into memory, parsed, and discarded. Only the extracted text is
stored, in local SQLite.

## Changing models

The model field is editable and pre-filled with a sensible default per provider. If a
provider ships a newer model, type its ID — no code change needed.
