CREATE EXTENSION pgcrypto;

CREATE SCHEMA archive;

CREATE SCHEMA history;

CREATE TABLE archive.department (
  department_id uuid PRIMARY KEY,
  department_code text UNIQUE NOT NULL,
  name text NOT NULL,
  updated_at timestamptz NOT NULL
);

CREATE TABLE archive.series (
  series_id uuid PRIMARY KEY,
  department_id uuid NOT NULL REFERENCES archive.department,
  series_code text NOT NULL,
  name text NOT NULL,
  updated_at timestamptz NOT NULL,
  UNIQUE (department_id, series_code)
);

CREATE TABLE archive.record (
  record_id uuid PRIMARY KEY,
  series_id uuid NOT NULL REFERENCES archive.series,
  record_reference text NOT NULL,
  updated_at timestamptz NOT NULL,
  UNIQUE (series_id, record_reference)
);

CREATE TABLE archive.version (
  version_id uuid PRIMARY KEY,
  record_id uuid NOT NULL REFERENCES archive.record,
  version_code text NOT NULL,
  default_title_code text,
  default_description_code text,
  default_path_code text,
  updated_at timestamptz NOT NULL,
  UNIQUE (record_id, version_code)
);

CREATE TABLE archive.version_title (
  version_title_id uuid PRIMARY KEY,
  version_id uuid NOT NULL REFERENCES archive.version,
  title_code text NOT NULL,
  title_text text NOT NULL,
  language_code text NOT NULL,
  variant_code text NOT NULL,
  updated_at timestamptz NOT NULL,
  UNIQUE (version_id, title_code)
);

CREATE TABLE archive.version_description (
  version_description_id uuid PRIMARY KEY,
  version_id uuid NOT NULL REFERENCES archive.version,
  description_code text NOT NULL,
  description_text text NOT NULL,
  language_code text NOT NULL,
  variant_code text NOT NULL,
  updated_at timestamptz NOT NULL,
  UNIQUE (version_id, description_code)
);

CREATE TABLE archive.version_path (
  version_path_id uuid PRIMARY KEY,
  version_id uuid NOT NULL REFERENCES archive.version,
  path_code text NOT NULL,
  path_value text NOT NULL,
  path_type text NOT NULL,
  updated_at timestamptz NOT NULL,
  UNIQUE (version_id, path_code)
);

CREATE TABLE archive.representation (
  representation_id uuid PRIMARY KEY,
  version_id uuid NOT NULL REFERENCES archive.version,
  representation_code text NOT NULL,
  representation_type text NOT NULL,
  updated_at timestamptz NOT NULL,
  UNIQUE (version_id, representation_code)
);

CREATE TABLE archive.consignment (
  consignment_id uuid PRIMARY KEY,
  consignment_reference text UNIQUE NOT NULL,
  received_at timestamptz NOT NULL,
  source_organisation text,
  notes text,
  updated_at timestamptz NOT NULL
);

CREATE TABLE archive.file (
  file_id uuid PRIMARY KEY,
  representation_id uuid NOT NULL REFERENCES archive.representation,
  consignment_id uuid NOT NULL REFERENCES archive.consignment,
  file_name text NOT NULL,
  relative_path text NOT NULL,
  updated_at timestamptz NOT NULL,
  UNIQUE (representation_id, relative_path)
);

CREATE TABLE archive.sensitivity (
  sensitivity_id uuid PRIMARY KEY,
  version_id uuid REFERENCES archive.version,
  version_title_id uuid REFERENCES archive.version_title,
  version_description_id uuid REFERENCES archive.version_description,
  version_path_id uuid REFERENCES archive.version_path,
  sensitivity_type text NOT NULL CHECK (
    sensitivity_type in (
      'FOIA',
      'AUR',
      'Retained',
      'not crown copyright',
      'commercial',
      'do not publish'
    )
  ),
  sensitivity_type_code text,
  sensitivity_status text NOT NULL CHECK (
    sensitivity_status IN (
      'active',
      'lapsed',
      'under investigation',
      'superceeded',
      'cancelled'
    )
  ),
  sensitivity_start date,
  sensitivity_period text,
  sensitivity_rule text NOT NULL CHECK (
    sensitivity_rule IN ('JAN_AFTER_PERIOD', 'EXACT_PERIOD', 'MANUAL')
  ),
  sensitivity_end date,
  investigation_date date,
  investigation_outcome text CHECK (investigation_outcome IN ('open', 'close')),
  schedule_reference text,
  archivist_note text,
  updated_at timestamptz NOT NULL,
  CHECK (
    num_nonnulls (
      version_id,
      version_title_id,
      version_description_id,
      version_path_id
    ) = 1
  )
);

CREATE TABLE archive.metadata_change_event (
  metadata_change_event_id uuid PRIMARY KEY,
  source_event_id uuid UNIQUE NOT NULL,
  entity_type text NOT NULL,
  entity_id uuid,
  entity_key jsonb NOT NULL,
  change_type char(1) NOT NULL CHECK (change_type IN ('I', 'U', 'D')),
  outcome text NOT NULL,
  processing_status text NOT NULL,
  changes jsonb NOT NULL,
  raw_change_payload jsonb NOT NULL,
  changed_at timestamptz NOT NULL,
  received_at timestamptz NOT NULL DEFAULT clock_timestamp (),
  processed_at timestamptz,
  changed_by_id text NOT NULL,
  changed_by_name text,
  change_reason text NOT NULL,
  source_system text NOT NULL,
  error_message text
);

CREATE TABLE history.department (
  history_id uuid PRIMARY KEY,
  department_id uuid NOT NULL REFERENCES archive.department,
  department_code text NOT NULL,
  name text NOT NULL,
  valid_from timestamptz NOT NULL,
  valid_to timestamptz,
  is_current boolean NOT NULL,
  changed_at timestamptz NOT NULL,
  changed_by_id text NOT NULL,
  changed_by_name text,
  change_reason text NOT NULL,
  source_event_id uuid UNIQUE NOT NULL
);

CREATE TABLE history.series (
  history_id uuid PRIMARY KEY,
  series_id uuid NOT NULL REFERENCES archive.series,
  department_id uuid NOT NULL REFERENCES archive.department,
  series_code text NOT NULL,
  name text NOT NULL,
  valid_from timestamptz NOT NULL,
  valid_to timestamptz,
  is_current boolean NOT NULL,
  changed_at timestamptz NOT NULL,
  changed_by_id text NOT NULL,
  changed_by_name text,
  change_reason text NOT NULL,
  source_event_id uuid UNIQUE NOT NULL
);

CREATE TABLE history.record (
  history_id uuid PRIMARY KEY,
  record_id uuid NOT NULL REFERENCES archive.record,
  series_id uuid NOT NULL REFERENCES archive.series,
  record_reference text NOT NULL,
  valid_from timestamptz NOT NULL,
  valid_to timestamptz,
  is_current boolean NOT NULL,
  changed_at timestamptz NOT NULL,
  changed_by_id text NOT NULL,
  changed_by_name text,
  change_reason text NOT NULL,
  source_event_id uuid UNIQUE NOT NULL
);

CREATE TABLE history.version (
  history_id uuid PRIMARY KEY,
  version_id uuid NOT NULL REFERENCES archive.version,
  record_id uuid NOT NULL REFERENCES archive.record,
  version_code text NOT NULL,
  default_title_code text,
  default_description_code text,
  default_path_code text,
  valid_from timestamptz NOT NULL,
  valid_to timestamptz,
  is_current boolean NOT NULL,
  changed_at timestamptz NOT NULL,
  changed_by_id text NOT NULL,
  changed_by_name text,
  change_reason text NOT NULL,
  source_event_id uuid UNIQUE NOT NULL
);

CREATE TABLE history.version_title (
  history_id uuid PRIMARY KEY,
  version_title_id uuid NOT NULL REFERENCES archive.version_title,
  version_id uuid NOT NULL REFERENCES archive.version,
  title_code text NOT NULL,
  title_text text NOT NULL,
  language_code text NOT NULL,
  variant_code text NOT NULL,
  valid_from timestamptz NOT NULL,
  valid_to timestamptz,
  is_current boolean NOT NULL,
  changed_at timestamptz NOT NULL,
  changed_by_id text NOT NULL,
  changed_by_name text,
  change_reason text NOT NULL,
  source_event_id uuid UNIQUE NOT NULL
);

CREATE TABLE history.version_description (
  history_id uuid PRIMARY KEY,
  version_description_id uuid NOT NULL REFERENCES archive.version_description,
  version_id uuid NOT NULL REFERENCES archive.version,
  description_code text NOT NULL,
  description_text text NOT NULL,
  language_code text NOT NULL,
  variant_code text NOT NULL,
  valid_from timestamptz NOT NULL,
  valid_to timestamptz,
  is_current boolean NOT NULL,
  changed_at timestamptz NOT NULL,
  changed_by_id text NOT NULL,
  changed_by_name text,
  change_reason text NOT NULL,
  source_event_id uuid UNIQUE NOT NULL
);

CREATE TABLE history.version_path (
  history_id uuid PRIMARY KEY,
  version_path_id uuid NOT NULL REFERENCES archive.version_path,
  version_id uuid NOT NULL REFERENCES archive.version,
  path_code text NOT NULL,
  path_value text NOT NULL,
  path_type text NOT NULL,
  valid_from timestamptz NOT NULL,
  valid_to timestamptz,
  is_current boolean NOT NULL,
  changed_at timestamptz NOT NULL,
  changed_by_id text NOT NULL,
  changed_by_name text,
  change_reason text NOT NULL,
  source_event_id uuid UNIQUE NOT NULL
);

CREATE TABLE history.representation (
  history_id uuid PRIMARY KEY,
  representation_id uuid NOT NULL REFERENCES archive.representation,
  version_id uuid NOT NULL REFERENCES archive.version,
  representation_code text NOT NULL,
  representation_type text NOT NULL,
  valid_from timestamptz NOT NULL,
  valid_to timestamptz,
  is_current boolean NOT NULL,
  changed_at timestamptz NOT NULL,
  changed_by_id text NOT NULL,
  changed_by_name text,
  change_reason text NOT NULL,
  source_event_id uuid UNIQUE NOT NULL
);

CREATE TABLE history.consignment (
  history_id uuid PRIMARY KEY,
  consignment_id uuid NOT NULL REFERENCES archive.consignment,
  consignment_reference text NOT NULL,
  received_at timestamptz NOT NULL,
  source_organisation text,
  notes text,
  valid_from timestamptz NOT NULL,
  valid_to timestamptz,
  is_current boolean NOT NULL,
  changed_at timestamptz NOT NULL,
  changed_by_id text NOT NULL,
  changed_by_name text,
  change_reason text NOT NULL,
  source_event_id uuid UNIQUE NOT NULL
);

CREATE TABLE history.file (
  history_id uuid PRIMARY KEY,
  file_id uuid NOT NULL REFERENCES archive.file,
  representation_id uuid NOT NULL REFERENCES archive.representation,
  consignment_id uuid NOT NULL REFERENCES archive.consignment,
  file_name text NOT NULL,
  relative_path text NOT NULL,
  valid_from timestamptz NOT NULL,
  valid_to timestamptz,
  is_current boolean NOT NULL,
  changed_at timestamptz NOT NULL,
  changed_by_id text NOT NULL,
  changed_by_name text,
  change_reason text NOT NULL,
  source_event_id uuid UNIQUE NOT NULL
);

CREATE TABLE history.sensitivity (
  history_id uuid PRIMARY KEY,
  sensitivity_id uuid NOT NULL REFERENCES archive.sensitivity,
  version_id uuid REFERENCES archive.version,
  version_title_id uuid REFERENCES archive.version_title,
  version_description_id uuid REFERENCES archive.version_description,
  version_path_id uuid REFERENCES archive.version_path,
  sensitivity_type text NOT NULL CHECK (
    sensitivity_type in (
      'FOIA',
      'AUR',
      'Retained',
      'not crown copyright',
      'commercial',
      'do not publish'
    )
  ),
  sensitivity_type_code text,
  sensitivity_status text NOT NULL CHECK (
    sensitivity_status IN (
      'active',
      'lapsed',
      'under investigation',
      'superceeded',
      'cancelled'
    )
  ),
  sensitivity_start date,
  sensitivity_period text,
  sensitivity_rule text NOT NULL CHECK (
    sensitivity_rule IN ('JAN_AFTER_PERIOD', 'EXACT_PERIOD', 'MANUAL')
  ),
  sensitivity_end date,
  investigation_date date,
  investigation_outcome text CHECK (investigation_outcome IN ('open', 'close')),
  schedule_reference text,
  archivist_note text,
  valid_from timestamptz NOT NULL,
  valid_to timestamptz,
  is_current boolean NOT NULL,
  changed_at timestamptz NOT NULL,
  changed_by_id text NOT NULL,
  changed_by_name text,
  change_reason text NOT NULL,
  source_event_id uuid UNIQUE NOT NULL
);

CREATE VIEW archive.current_version_display AS
SELECT
  v.version_id,
  d.department_code,
  s.series_code,
  r.record_reference,
  v.version_code,
  t.title_text AS default_title,
  ds.description_text AS default_description,
  p.path_value AS default_path
FROM
  archive.version v
  JOIN archive.record r ON r.record_id = v.record_id
  JOIN archive.series s ON s.series_id = r.series_id
  JOIN archive.department d ON d.department_id = s.department_id
  LEFT JOIN archive.version_title t ON t.version_id = v.version_id
  AND t.title_code = v.default_title_code
  LEFT JOIN archive.version_description ds ON ds.version_id = v.version_id
  AND ds.description_code = v.default_description_code
  LEFT JOIN archive.version_path p ON p.version_id = v.version_id
  AND p.path_code = v.default_path_code;

CREATE VIEW archive.current_active_sensitivity AS
SELECT
  *
FROM
  archive.sensitivity
WHERE
  sensitivity_status in ('active', 'under investigation');
