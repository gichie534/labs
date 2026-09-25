-- =============================================================================
-- Amazon Redshift Query Editor v2 — Visual Analytics & Saved Queries
--
-- How to connect:
--   1. In AWS Console, open Amazon Redshift -> Query editor v2.
--   2. Click 'Provisioned warehouses and serverless workgroups' -> 'events-warehouse'.
--   3. Connection method: 'Federated user' (IAM authentication, no password).
--   4. Database: 'labdb'.
--   5. In the left schema tree, expand: labdb -> public -> Views.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Query 1: Pipeline Comparison (Bar Chart)
--
-- Compares event volume between batch and streaming ingestion paths per event type.
--
-- Chart Settings in Query Editor v2:
--   - Toggle from 'Table' to 'Chart'
--   - Type: Grouped Bar
--   - X axis: event
--   - Y axis: event_count
--   - Group by: source_pipeline
-- -----------------------------------------------------------------------------
SELECT 
    event,
    source_pipeline,
    event_count
FROM v_pipeline_event_summary
ORDER BY event, source_pipeline;


-- -----------------------------------------------------------------------------
-- Query 2: Event Type Distribution (Donut / Pie Chart)
--
-- Shows overall distribution of user actions across all ingested events.
--
-- Chart Settings in Query Editor v2:
--   - Toggle from 'Table' to 'Chart'
--   - Type: Donut (or Pie)
--   - Category: event
--   - Value: total_count
-- -----------------------------------------------------------------------------
SELECT 
    event,
    COUNT(*) AS total_count
FROM v_unified_events
GROUP BY event
ORDER BY total_count DESC;


-- -----------------------------------------------------------------------------
-- Query 3: User Engagement Profile (Stacked Bar Chart)
--
-- Shows breakdown of logins, purchases, and logouts per user ID.
--
-- Chart Settings in Query Editor v2:
--   - Toggle from 'Table' to 'Chart'
--   - Type: Bar (Horizontal or Vertical)
--   - X axis: user_id
--   - Y axis: logins, purchases, logouts
-- -----------------------------------------------------------------------------
SELECT 
    CAST(user_id AS VARCHAR) AS user_id,
    total_events,
    logins,
    purchases,
    logouts,
    first_event_time,
    last_event_time
FROM v_user_engagement_profile
ORDER BY total_events DESC;


-- -----------------------------------------------------------------------------
-- Query 4: Raw Unified Timeline Preview
--
-- Inspect individual events unified from both pipelines.
-- -----------------------------------------------------------------------------
SELECT 
    source_pipeline,
    user_id,
    event,
    event_time
FROM v_unified_events
ORDER BY event_time DESC
LIMIT 50;
