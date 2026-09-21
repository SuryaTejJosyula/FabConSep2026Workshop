-- **************************************************************
-- Here are docs TO help you get started WITH ASAQL
-- EventStream SQL Operator Intro - https://aka.ms/es-sql-intro
-- SQL language reference - https://aka.ms/asaql-language-ref
-- **************************************************************
WITH TrafficEnriched AS (
SELECT tf.segment_id, 
  CAST(tf.TIMESTAMP AS datetime) AS timestamp,
  tf.status_code,
  tf.speed_state_code,
  tf.vehicle_count,
  tf.avg_speed_kmh,
  tf.incident_flag,
  rd.speed_state_label,
  rd.description,
  rd.typical_speed_kmh,
  System.TIMESTAMP() AS system_timestamp 
FROM [traffic_es-stream] AS tf
JOIN Referenceddata AS rd ON tf.speed_state_code = cast(rd.speed_state_code AS bigint)
)

SELECT * INTO DerivedStream FROM TrafficEnriched

SELECT * INTO Eventhouse FROM TrafficEnriched
