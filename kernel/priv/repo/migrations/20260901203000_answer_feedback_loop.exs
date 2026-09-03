defmodule Swarm.Repo.Migrations.AnswerFeedbackLoop do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS answer_record (
      ask_ref text PRIMARY KEY,
      viewer text NOT NULL,
      scopes text[] NOT NULL DEFAULT '{}',
      query text NOT NULL,
      answer text NOT NULL,
      tier text NOT NULL,
      status text NOT NULL,
      confidence double precision NOT NULL DEFAULT 0.0,
      agreement double precision,
      citations jsonb NOT NULL DEFAULT '[]'::jsonb,
      created_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    execute("ALTER TABLE answer_record ADD COLUMN IF NOT EXISTS agreement double precision")

    execute(
      "ALTER TABLE answer_record ADD COLUMN IF NOT EXISTS citations jsonb NOT NULL DEFAULT '[]'::jsonb"
    )

    execute("""
    UPDATE answer_record
       SET citations = (citations #>> '{}')::jsonb
     WHERE jsonb_typeof(citations) = 'string'
    """)

    execute(
      "CREATE INDEX IF NOT EXISTS answer_record_viewer_created_idx ON answer_record (viewer, created_at DESC)"
    )

    execute("""
    CREATE TABLE IF NOT EXISTS answer_rating (
      ask_ref text NOT NULL REFERENCES answer_record(ask_ref) ON DELETE CASCADE,
      viewer text NOT NULL,
      rating text NOT NULL CHECK (rating IN ('helpful', 'wrong', 'unsure')),
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (ask_ref, viewer)
    )
    """)

    execute(
      "CREATE INDEX IF NOT EXISTS answer_rating_rating_idx ON answer_rating (rating, updated_at DESC)"
    )

    execute("""
    CREATE TABLE IF NOT EXISTS calibration_contradiction (
      ask_ref text PRIMARY KEY,
      subject_key text,
      relation text,
      verdict text NOT NULL CHECK (verdict IN ('corroborated', 'contradicted', 'not_comparable')),
      explanation text NOT NULL,
      created_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    execute(
      "CREATE INDEX IF NOT EXISTS calibration_contradiction_subject_idx ON calibration_contradiction (subject_key, relation, verdict)"
    )

    execute("""
    INSERT INTO answer_record
      (ask_ref, viewer, scopes, query, answer, tier, status, confidence, agreement, citations, created_at)
    SELECT ask_ref, viewer, scopes, '', answer, 'escalate', 'found', confidence,
           GREATEST(0.0, LEAST(1.0, 1.0 - disagreement)), '[]'::jsonb, created_at
      FROM deliberation
    ON CONFLICT (ask_ref) DO UPDATE SET
      agreement = EXCLUDED.agreement
    """)
  end

  def down do
    execute("DROP TABLE IF EXISTS calibration_contradiction")
    execute("DROP TABLE IF EXISTS answer_rating")
    execute("DROP TABLE IF EXISTS answer_record")
  end
end
