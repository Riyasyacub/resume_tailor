class CreateTailorSessions < ActiveRecord::Migration[8.0]
  def change
    create_table :tailor_sessions do |t|
      t.text :resume_text,   null: false
      t.text :jd_text,       null: false
      t.string :source_filename
      t.json :analysis                 # LLM pass 1: keywords found in the JD
      t.json :confirmations            # what the user affirmed they actually have
      t.json :result                   # LLM pass 2: the rewritten resume
      t.timestamps
    end
  end
end
