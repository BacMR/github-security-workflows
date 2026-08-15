-- secscan database schema
-- Applied idempotently by deploy/install-tools.sh (psql -f db/schema.sql)

CREATE TABLE IF NOT EXISTS scan_runs (
  id            bigserial PRIMARY KEY,
  github_run_id bigint,
  run_type      text        NOT NULL DEFAULT 'org',
  org           text,
  started_at    timestamptz NOT NULL DEFAULT now(),
  finished_at   timestamptz
);

-- migration for databases created before the org column existed
ALTER TABLE scan_runs ADD COLUMN IF NOT EXISTS org text;

CREATE TABLE IF NOT EXISTS repo_scans (
  id             bigserial PRIMARY KEY,
  scan_run_id    bigint      NOT NULL REFERENCES scan_runs(id) ON DELETE CASCADE,
  repository     text        NOT NULL,
  scanner        text        NOT NULL CHECK (scanner IN ('gitleaks', 'trivy', 'semgrep')),
  findings_count integer     NOT NULL DEFAULT 0,
  report         jsonb       NOT NULL DEFAULT '{}'::jsonb,
  scanned_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS repo_scans_run_idx  ON repo_scans (scan_run_id);
CREATE INDEX IF NOT EXISTS repo_scans_repo_idx ON repo_scans (repository, scanned_at DESC);

CREATE TABLE IF NOT EXISTS findings (
  id           bigserial PRIMARY KEY,
  repo_scan_id bigint      NOT NULL REFERENCES repo_scans(id) ON DELETE CASCADE,
  repository   text        NOT NULL,
  scanner      text        NOT NULL,
  rule_id      text,
  severity     text,
  title        text,
  file_path    text,
  line         integer,
  fingerprint  text,
  detail       jsonb,
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS findings_repo_idx        ON findings (repository, created_at DESC);
CREATE INDEX IF NOT EXISTS findings_fingerprint_idx ON findings (fingerprint);
CREATE INDEX IF NOT EXISTS findings_scan_idx        ON findings (repo_scan_id);

-- Stores the raw report and explodes it into normalized findings rows.
-- Returns the repo_scans.id it created.
CREATE OR REPLACE FUNCTION ingest_report(
  p_run_id  bigint,
  p_repo    text,
  p_scanner text,
  p_report  jsonb
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
  v_id    bigint;
  v_count integer := 0;
BEGIN
  INSERT INTO repo_scans (scan_run_id, repository, scanner, report)
  VALUES (p_run_id, p_repo, p_scanner, p_report)
  RETURNING id INTO v_id;

  IF p_scanner = 'gitleaks' AND jsonb_typeof(p_report) = 'array' THEN
    INSERT INTO findings (repo_scan_id, repository, scanner, rule_id, severity,
                          title, file_path, line, fingerprint, detail)
    SELECT v_id, p_repo, p_scanner,
           f->>'RuleID', 'SECRET',
           f->>'Description', f->>'File',
           NULLIF(f->>'StartLine', '')::integer,
           f->>'Fingerprint', f
    FROM jsonb_array_elements(p_report) AS f;

  ELSIF p_scanner = 'trivy' THEN
    INSERT INTO findings (repo_scan_id, repository, scanner, rule_id, severity,
                          title, file_path, line, fingerprint, detail)
    SELECT v_id, p_repo, p_scanner,
           v->>'VulnerabilityID', v->>'Severity',
           coalesce(v->>'Title', v->>'VulnerabilityID'),
           r->>'Target', NULL,
           concat_ws(':', p_repo, r->>'Target', v->>'VulnerabilityID',
                     v->>'PkgName', v->>'InstalledVersion'),
           v
    FROM jsonb_array_elements(coalesce(p_report->'Results', '[]'::jsonb)) AS r,
         jsonb_array_elements(coalesce(r->'Vulnerabilities', '[]'::jsonb)) AS v;

  ELSIF p_scanner = 'semgrep' THEN
    INSERT INTO findings (repo_scan_id, repository, scanner, rule_id, severity,
                          title, file_path, line, fingerprint, detail)
    SELECT v_id, p_repo, p_scanner,
           f->>'check_id', upper(f#>>'{extra,severity}'),
           left(f#>>'{extra,message}', 500), f->>'path',
           NULLIF(f#>>'{start,line}', '')::integer,
           f#>>'{extra,fingerprint}', f
    FROM jsonb_array_elements(coalesce(p_report->'results', '[]'::jsonb)) AS f;
  END IF;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  UPDATE repo_scans SET findings_count = v_count WHERE id = v_id;
  RETURN v_id;
END;
$$;
