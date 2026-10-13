-- Execute a SQL query
CREATE SCHEMA IF NOT EXISTS access;

CREATE TABLE IF NOT EXISTS access.messages (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  event_id TEXT NOT NULL UNIQUE,
  source TEXT NOT NULL DEFAULT 'demo'
    CHECK (source IN ('demo', 'slack')),
  workspace_id TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  author_id TEXT NOT NULL,
  message_ts TEXT NOT NULL,
  thread_ts TEXT NOT NULL,
  sanitized_text TEXT NOT NULL,
  security_flags JSONB NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(security_flags) = 'array'),
  message_type TEXT
    CHECK (
      message_type IN (
        'access_request',
        'non_request',
        'ambiguous',
        'clarification'
      )
    ),
  llm_message_type TEXT,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (
      status IN ('pending', 'processing', 'processed', 'failed')
    ),
  clarification_question TEXT,
  result JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS access.requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id BIGINT NOT NULL
    REFERENCES access.messages(id),
  request_index INTEGER NOT NULL
    CHECK (request_index >= 0),
  subject TEXT,
  resource TEXT,
  environment TEXT,
  permission TEXT,
  duration_hours INTEGER
    CHECK (duration_hours > 0),
  reason TEXT,
  complete BOOLEAN NOT NULL,
  missing_fields JSONB NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(missing_fields) = 'array'),
  risk_flags JSONB NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(risk_flags) = 'array'),
  route TEXT NOT NULL
    CHECK (
      route IN (
        'standard_approval',
        'needs_clarification',
        'manual_review'
      )
    ),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (message_id, request_index),
  CHECK (
    route <> 'standard_approval'
    OR (
      complete = TRUE
      AND jsonb_array_length(missing_fields) = 0
      AND jsonb_array_length(risk_flags) = 0
    )
  )
);

CREATE INDEX IF NOT EXISTS messages_thread_idx
  ON access.messages (
    workspace_id,
    channel_id,
    thread_ts
  );

CREATE INDEX IF NOT EXISTS messages_pending_idx
  ON access.messages (created_at)
  WHERE status = 'pending';

SELECT 'Database tables are ready' AS result;

-- Configure App User
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_roles
    WHERE rolname = 'access_worker'
  ) THEN
    CREATE ROLE access_worker
      LOGIN
      NOSUPERUSER
      NOCREATEDB
      NOCREATEROLE
      NOREPLICATION
      ;
  END IF;
END
$$;

REVOKE ALL ON SCHEMA access FROM PUBLIC;

GRANT CONNECT ON DATABASE access_requests
  TO access_worker;

GRANT USAGE ON SCHEMA access
  TO access_worker;

GRANT SELECT, INSERT, UPDATE
  ON ALL TABLES IN SCHEMA access
  TO access_worker;

GRANT USAGE, SELECT
  ON ALL SEQUENCES IN SCHEMA access
  TO access_worker;

ALTER DEFAULT PRIVILEGES IN SCHEMA access
  GRANT SELECT, INSERT, UPDATE ON TABLES
  TO access_worker;

ALTER DEFAULT PRIVILEGES IN SCHEMA access
  GRANT USAGE, SELECT ON SEQUENCES
  TO access_worker;

SELECT 'Application database user is ready' AS result;

-- Prepare Queue
ALTER TABLE access.messages
  ADD COLUMN IF NOT EXISTS attempts INTEGER
    NOT NULL DEFAULT 0 CHECK (attempts >= 0),

  ADD COLUMN IF NOT EXISTS available_at TIMESTAMPTZ
    NOT NULL DEFAULT NOW(),

  ADD COLUMN IF NOT EXISTS lease_token UUID,

  ADD COLUMN IF NOT EXISTS leased_until TIMESTAMPTZ,

  ADD COLUMN IF NOT EXISTS processing_execution_id TEXT,

  ADD COLUMN IF NOT EXISTS error_code TEXT;

CREATE INDEX IF NOT EXISTS messages_queue_idx
  ON access.messages (available_at, created_at, id)
  WHERE status = 'pending';

SELECT 'Queue storage is ready' AS result;

-- Create Queue Claim Function
CREATE OR REPLACE FUNCTION access.claim_next_message(
  p_execution_id TEXT
)
RETURNS SETOF access.messages
LANGUAGE plpgsql
AS $$
BEGIN
  IF p_execution_id IS NULL
     OR trim(p_execution_id) = '' THEN
    RAISE EXCEPTION 'Execution ID is required';
  END IF;

  PERFORM pg_advisory_xact_lock(90426001);

  UPDATE access.messages
  SET
    status = CASE
      WHEN attempts >= 3 THEN 'failed'
      ELSE 'pending'
    END,
    error_code = 'processing_lease_expired',
    available_at = NOW(),
    lease_token = NULL,
    leased_until = NULL,
    processing_execution_id = NULL,
    updated_at = NOW()
  WHERE status = 'processing'
    AND leased_until <= NOW();

  RETURN QUERY
  WITH candidate AS (
    SELECT m.id
    FROM access.messages m
    WHERE m.status = 'pending'
      AND m.available_at <= NOW()
      AND m.attempts < 3
      AND NOT EXISTS (
        SELECT 1
        FROM access.messages earlier
        WHERE earlier.workspace_id = m.workspace_id
          AND earlier.channel_id = m.channel_id
          AND earlier.thread_ts = m.thread_ts
          AND earlier.id < m.id
          AND earlier.status IN ('pending', 'processing')
      )
    ORDER BY m.created_at, m.id
    LIMIT 1
    FOR UPDATE OF m SKIP LOCKED
  )
  UPDATE access.messages m
  SET
    status = 'processing',
    attempts = m.attempts + 1,
    lease_token = gen_random_uuid(),
    leased_until = NOW() + INTERVAL '5 minutes',
    processing_execution_id = p_execution_id,
    updated_at = NOW()
  FROM candidate c
  WHERE m.id = c.id
  RETURNING m.*;
END;
$$;

REVOKE ALL
  ON FUNCTION access.claim_next_message(TEXT)
  FROM PUBLIC;

GRANT EXECUTE
  ON FUNCTION access.claim_next_message(TEXT)
  TO access_worker;

SELECT 'Queue claim function is ready' AS result;

-- Create Notification Outbox
CREATE TABLE IF NOT EXISTS access.notification_outbox (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  message_id BIGINT NOT NULL
    REFERENCES access.messages(id),

  kind TEXT NOT NULL CHECK (
    kind IN (
      'clarification',
      'standard_approval',
      'manual_review'
    )
  ),

  payload JSONB NOT NULL CHECK (
    jsonb_typeof(payload) = 'object'
  ),

  status TEXT NOT NULL DEFAULT 'pending' CHECK (
    status IN (
      'pending',
      'processing',
      'sent',
      'failed',
      'cancelled'
    )
  ),

  attempts INTEGER NOT NULL DEFAULT 0 CHECK (
    attempts >= 0
  ),

  available_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  lease_token UUID,
  leased_until TIMESTAMPTZ,
  processing_execution_id TEXT,

  slack_message_ts TEXT,
  last_error_code TEXT,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (message_id, kind),

  CHECK (
    (
      status = 'processing'
      AND lease_token IS NOT NULL
      AND leased_until IS NOT NULL
    )
    OR (
      status <> 'processing'
      AND lease_token IS NULL
      AND leased_until IS NULL
    )
  )
);

CREATE INDEX IF NOT EXISTS notification_outbox_pending_idx
ON access.notification_outbox (
  available_at,
  created_at,
  id
)
WHERE status = 'pending';

GRANT SELECT, INSERT, UPDATE
ON access.notification_outbox
TO access_worker;

SELECT 'Notification outbox is ready' AS result;

-- Create Notification Outbox1
CREATE OR REPLACE FUNCTION access.enqueue_notifications()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_result JSONB;
  v_requests JSONB;
  v_standard JSONB;
  v_manual JSONB;
  v_incomplete JSONB;
  v_payload JSONB;
  v_question TEXT;
BEGIN
  -- Only real Slack events produce notifications.
  IF NEW.source <> 'slack' THEN
    RETURN NEW;
  END IF;

  v_result := COALESCE(NEW.result, '{}'::jsonb);

  v_requests := CASE
    WHEN jsonb_typeof(v_result->'requests') = 'array'
      THEN v_result->'requests'
    ELSE '[]'::jsonb
  END;

  SELECT
    COALESCE(
      jsonb_agg(r.value) FILTER (
        WHERE r.value->>'route' = 'standard_approval'
      ),
      '[]'::jsonb
    ),
    COALESCE(
      jsonb_agg(r.value) FILTER (
        WHERE r.value->>'route' = 'manual_review'
      ),
      '[]'::jsonb
    ),
    COALESCE(
      jsonb_agg(r.value) FILTER (
        WHERE r.value->>'complete' = 'false'
      ),
      '[]'::jsonb
    )
  INTO v_standard, v_manual, v_incomplete
  FROM jsonb_array_elements(v_requests) AS r(value);

  v_question := NULLIF(
    btrim(v_result->>'clarification_question'),
    ''
  );

  -- Delivery destinations will be selected from trusted configuration.
  v_payload := jsonb_build_object(
    'message_id', NEW.id,
    'workspace_id', NEW.workspace_id,
    'channel_id', NEW.channel_id,
    'author_id', NEW.author_id,
    'message_ts', NEW.message_ts,
    'thread_ts', NEW.thread_ts,
    'sanitized_text', NEW.sanitized_text,
    'message_type', NEW.message_type,
    'processing_status', NEW.status,
    'error_code', NEW.error_code,
    'message_risk_flags',
      COALESCE(
        v_result->'message_risk_flags',
        NEW.security_flags,
        '[]'::jsonb
      ),
    'message_validation_flags',
      COALESCE(
        v_result->'message_validation_flags',
        '[]'::jsonb
      )
  );

  IF NEW.status = 'processed'
     AND jsonb_array_length(v_incomplete) > 0
     AND v_question IS NOT NULL
  THEN
    INSERT INTO access.notification_outbox (
      message_id, kind, payload
    )
    VALUES (
      NEW.id,
      'clarification',
      v_payload || jsonb_build_object(
        'requests', v_incomplete,
        'clarification_question', v_question
      )
    )
    ON CONFLICT (message_id, kind) DO NOTHING;
  END IF;

  IF NEW.status = 'processed'
     AND jsonb_array_length(v_standard) > 0
  THEN
    INSERT INTO access.notification_outbox (
      message_id, kind, payload
    )
    VALUES (
      NEW.id,
      'standard_approval',
      v_payload || jsonb_build_object(
        'requests', v_standard
      )
    )
    ON CONFLICT (message_id, kind) DO NOTHING;
  END IF;

  IF NEW.status = 'failed'
     OR v_result->>'message_route' = 'manual_review'
     OR jsonb_array_length(v_manual) > 0
  THEN
    INSERT INTO access.notification_outbox (
      message_id, kind, payload
    )
    VALUES (
      NEW.id,
      'manual_review',
      v_payload || jsonb_build_object(
        'requests', v_manual
      )
    )
    ON CONFLICT (message_id, kind) DO NOTHING;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION access.enqueue_notifications()
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION access.enqueue_notifications()
TO access_worker;

CREATE OR REPLACE TRIGGER enqueue_message_notifications
AFTER UPDATE OF status ON access.messages
FOR EACH ROW
WHEN (
  OLD.status IS DISTINCT FROM NEW.status
  AND NEW.status IN ('processed', 'failed')
)
EXECUTE FUNCTION access.enqueue_notifications();

SELECT 'Notification trigger is ready' AS result;

-- Create Notification Claim Function
CREATE OR REPLACE FUNCTION access.claim_next_notification(
  p_execution_id TEXT
)
RETURNS SETOF access.notification_outbox
LANGUAGE plpgsql
AS $$
DECLARE
  v_notification_id UUID;
BEGIN
  IF p_execution_id IS NULL
     OR btrim(p_execution_id) = ''
  THEN
    RAISE EXCEPTION 'Execution ID is required';
  END IF;

  -- Serialize the short claim transaction.
  PERFORM pg_advisory_xact_lock(90426002);

  -- Recover jobs whose processing lease has expired.
  UPDATE access.notification_outbox AS n
  SET
    status = CASE
      WHEN n.attempts >= 3 THEN 'failed'
      ELSE 'pending'
    END,
    available_at = NOW() + INTERVAL '15 seconds',
    lease_token = NULL,
    leased_until = NULL,
    processing_execution_id = NULL,
    last_error_code = 'delivery_lease_expired',
    updated_at = NOW()
  WHERE n.status = 'processing'
    AND n.leased_until <= NOW();

  SELECT n.id
  INTO v_notification_id
  FROM access.notification_outbox AS n
  WHERE n.status = 'pending'
    AND n.available_at <= NOW()
    AND n.attempts < 3
  ORDER BY n.created_at, n.id
  LIMIT 1
  FOR UPDATE OF n SKIP LOCKED;

  IF v_notification_id IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  UPDATE access.notification_outbox AS n
  SET
    status = 'processing',
    attempts = n.attempts + 1,
    lease_token = gen_random_uuid(),
    leased_until = NOW() + INTERVAL '5 minutes',
    processing_execution_id = p_execution_id,
    updated_at = NOW()
  WHERE n.id = v_notification_id
  RETURNING n.*;
END;
$$;

REVOKE ALL ON FUNCTION access.claim_next_notification(TEXT)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION access.claim_next_notification(TEXT)
TO access_worker;

SELECT 'Notification claim function is ready' AS result;