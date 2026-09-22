# Barcelona Smart City Pulse: Step-by-Step Solution

This guide describes one complete way to solve the hackathon. Fabric menu names and experiences can evolve, but the architecture, event contracts, and validation approach remain the same.

Use `README.md` as the participant challenge. Use this file as the facilitator guide or reveal it after teams have attempted each act.

## Recommended names

| Artifact | Name used in this guide |
| --- | --- |
| Workspace | `BarcelonaSmartCityHack` |
| Lakehouse | `BarcelonaReferenceData` |
| Traffic Eventstream | `TrafficIngestion` |
| Occupancy Eventstream | `OccupancyIngestion` |
| Eventhouse | `BarcelonaOperations` |
| KQL database | `BarcelonaPulse` |
| Traffic table | `TrafficStream` |
| Occupancy table | `OccupancyStream` |
| Static tables/shortcuts | `SegmentGeometry`, `SpeedState`, `Status` |
| Real-Time Dashboard | `Barcelona Operations Center` |
| Fabric Map | `Barcelona Live Operations` |

Different names are valid, but they must be updated consistently in Eventstream destinations, KQL, maps, dashboards, and alerts.

## Prepare the environment

1. Create or select a Fabric workspace on a capacity that supports Real-Time Intelligence.
2. Create a lakehouse named `BarcelonaReferenceData`.
3. Upload these files to the lakehouse `Files` area:
   - `Static data/segment_long.csv`
   - `Static data/speed_state.csv`
   - `Static data/status.csv`
   - `Static data/occupancy_locations.geojson`
4. Import both notebooks from `Data generators/` into the workspace.
5. Attach `BarcelonaReferenceData` as the default lakehouse for each notebook.
6. Load the three CSV files into lakehouse Delta tables named:
   - `SegmentGeometry`
   - `SpeedState`
   - `Status`
7. Validate the static data:
   - `SegmentGeometry` has 3,228 rows and 527 distinct `Tram` values.
   - `SpeedState` contains codes `-1`, `0`, `1`, `2`, and `3`.
   - `Status` contains codes `0` and `1`.

The occupancy GeoJSON remains an input to the occupancy notebook and does not need to become a table for the core solution.

## Act 1: Ingest and Process Data

### Step 1: Create the Eventhouse

1. Create an Eventhouse named `BarcelonaOperations`.
2. Create or select its KQL database.
3. Name the KQL database `BarcelonaPulse`.
4. Keep the Eventhouse available in another browser tab for validation.

### Step 2: Create the traffic Eventstream

1. Create an Eventstream named `TrafficIngestion`.
2. Add a **Custom endpoint** source named `TrafficSource`.
3. Copy the Event Hub-compatible connection string and entity name.
4. Add an Eventhouse destination.
5. Select `BarcelonaOperations` and `BarcelonaPulse`.
6. Create a destination table named `TrafficStream`.
7. Initially route the source directly to the destination so the raw path can be tested before enrichment is added.

### Step 3: Configure the traffic generator

Open `Data generators/barcelona_traffic_generator.ipynb` and replace the placeholders:

```python
TRAFFIC_EH_CONN_STR = "<traffic custom endpoint connection string>"
TRAFFIC_EH_NAME = "<traffic custom endpoint entity name>"
```

Run the notebook from the beginning. Before starting the final streaming cell, confirm:

- The CSV files load from `/lakehouse/default/Files/`.
- The notebook reports 527 real road segments.
- The dataframe contains the 16 traffic fields documented in `README.md`.
- The event timestamp contains the Barcelona UTC offset.

The default settings produce accelerated live playback:

```python
SPEED_FACTOR = 12
LIVE_SLEEP = True
```

Each event-time interval represents five minutes and is emitted approximately every 25 seconds. For a fast historical load, temporarily set:

```python
LIVE_SLEEP = False
```

Use `LIVE_SLEEP = True` for the final live demonstration.

### Step 4: Validate traffic ingestion

Check the Eventstream source preview and confirm that the JSON fields are parsed separately.

In the KQL database, run:

```kusto
TrafficStream
| take 10
```

Validate the number of segments and event range:

```kusto
TrafficStream
| summarize
    Rows = count(),
    Segments = dcount(segment_id),
    FirstEvent = min(timestamp),
    LastEvent = max(timestamp)
```

After a complete batch, `Segments` should be 527.

Check no-data behavior:

```kusto
TrafficStream
| where status_code == 0
| project
    segment_id,
    timestamp,
    status_code,
    speed_state_code,
    vehicle_count,
    avg_speed_kmh,
    incident_flag
| take 10
```

These records should have speed state `-1`, zero vehicles, a null speed, and `incident_flag == false`.

### Step 5: Enrich traffic in Eventstream

Add `speed_state.csv` as Eventstream reference data and join it to the traffic stream on `speed_state_code`.

`Helper/sqltransformation.sql` provides a starting pattern. Adapt the Eventstream source and destination names to the names shown in your designer.

The enriched result should preserve the complete traffic payload and add:

```text
speed_state_label
speed_state_description
typical_speed_kmh
system_timestamp
```

When building the Eventstream transformation:

1. Cast the traffic timestamp to `datetime` if necessary.
2. Cast both join keys to compatible numeric types.
3. Rename the reference-data `description` field to `speed_state_description`.
4. Add the Eventstream processing time as `system_timestamp`.
5. Preserve all zone, road, coordinate, and distance fields.
6. Route the enriched result to the Eventhouse destination.
7. Optionally route the same result to a derived stream for Business Events.

If the original `TrafficStream` table was inferred from the raw payload, update the destination mapping or use a new table named `TrafficEnriched`. The remaining KQL in this guide assumes the final enriched events are in `TrafficStream`.

### Step 6: Create the occupancy Eventstream

1. Create an Eventstream named `OccupancyIngestion`.
2. Add a Custom endpoint source named `OccupancySource`.
3. Copy its connection string and entity name.
4. Add an Eventhouse destination targeting `BarcelonaPulse`.
5. Create a table named `OccupancyStream`.
6. Preserve an Eventstream system timestamp as `ingestion_timestamp`.
7. Use `dynamic` as the Eventhouse type for `geometry`.

The payload itself contains:

```text
occupancySignalId
category
currentOccupancy
totalOccupancy
geometry
```

The additional `ingestion_timestamp` becomes the time axis for queries, dashboards, and anomaly detection.

### Step 7: Configure the occupancy generator

Open `Data generators/occupancy_stream_generator.ipynb` and replace:

```python
OCCUPANCY_EH_CONN_STR = "<occupancy custom endpoint connection string>"
OCCUPANCY_EH_NAME = "<occupancy custom endpoint entity name>"
```

Run the notebook. The final cell sends 15 records every five seconds.

The default run lasts 10 minutes:

```python
MAX_BATCHES = 120
```

Set `MAX_BATCHES = None` only when continuous generation is required and the notebook cell will be stopped manually afterward.

### Step 8: Validate occupancy ingestion

Run:

```kusto
OccupancyStream
| take 10
```

Validate the entity count and ingestion range:

```kusto
OccupancyStream
| summarize
    Rows = count(),
    Locations = dcount(occupancySignalId),
    FirstReceived = min(ingestion_timestamp),
    LastReceived = max(ingestion_timestamp)
```

After one complete batch, `Locations` should be 15.

Check that occupancy stays within capacity:

```kusto
OccupancyStream
| where currentOccupancy < 0 or currentOccupancy > totalOccupancy
```

The query should return no rows.

## Act 2: Analyze Data

### Step 1: Connect static data with OneLake shortcuts

In the `BarcelonaPulse` KQL database:

1. Create a OneLake shortcut to the `SegmentGeometry` Delta table.
2. Create a shortcut to `SpeedState`.
3. Create a shortcut to `Status`.
4. Keep the names used in this guide or update the KQL accordingly.

Validate the shortcuts:

```kusto
SegmentGeometry
| summarize Rows = count(), Segments = dcount(Tram)
```

```kusto
SpeedState
| order by speed_state_code asc
```

```kusto
Status
| order by status_code asc
```

If shortcut fields are inferred as strings, normalize them in functions with `tolong()`, `toreal()`, or `tostring()`.

### Step 2: Create the segment geometry function

`SegmentGeometry` contains several ordered points for each road segment. Convert those points into one GeoJSON `LineString` per segment:

```kusto
.create-or-alter function with (skipvalidation = "true") SegmentLines() {
    SegmentGeometry
    | order by Tram asc, Tram_Components asc
    | extend coordinate = pack_array(toreal(Longitud), toreal(Latitud))
    | summarize
        coordinates = make_list(coordinate),
        road_name = take_any(Descripci_)
      by segment_id = tolong(Tram)
    | extend geometry = bag_pack("type", "LineString", "coordinates", coordinates)
    | project segment_id, road_name, geometry
}
```

`Helper/segment_geometry_kql.kql` contains a similar starter implementation.

Validate that the function returns one row per segment:

```kusto
SegmentLines()
| summarize Rows = count(), Segments = dcount(segment_id)
```

Both values should be 527.

### Step 3: Create the traffic enrichment function

Even when Eventstream adds the speed-state label, Eventhouse should provide a reusable function that joins both compact lookup tables:

```kusto
.create-or-alter function with (skipvalidation = "true") TrafficEnriched() {
    TrafficStream
    | lookup kind=leftouter (
        SpeedState
        | project
            speed_state_code = tolong(speed_state_code),
            speed_state_label,
            speed_state_description = description,
            typical_speed_kmh
      ) on speed_state_code
    | lookup kind=leftouter (
        Status
        | project
            status_code = tolong(status_code),
            status_label,
            status_description = description
      ) on status_code
}
```

If Eventstream already added fields with these names, project them out or rename them before the lookups to avoid duplicate columns.

Validate the result:

```kusto
TrafficEnriched()
| summarize
    Rows = count(),
    MissingSpeedLabels = countif(isempty(speed_state_label)),
    MissingStatusLabels = countif(isempty(status_label))
```

Both missing-label counts should be zero.

### Step 4: Create the occupancy enrichment function

```kusto
.create-or-alter function with (skipvalidation = "true") OccupancyEnriched() {
    OccupancyStream
    | extend occupancy_pct =
        round(100.0 * todouble(currentOccupancy) / todouble(totalOccupancy), 1)
    | extend occupancy_band = case(
        occupancy_pct >= 90.0, "Critical",
        occupancy_pct >= 80.0, "High",
        occupancy_pct >= 60.0, "Moderate",
        "Normal"
      )
}
```

If the dataset is changed so `totalOccupancy` can be zero, guard the calculation with `iff(totalOccupancy > 0, ..., real(null))`.

### Step 5: Create current-state materialized views

Create the latest traffic record for each road segment:

```kusto
.create-or-alter materialized-view with (backfill=true) TrafficCurrent on table TrafficStream
{
    TrafficStream
    | summarize arg_max(timestamp, *) by segment_id
}
```

Create the latest occupancy record for each location:

```kusto
.create-or-alter materialized-view with (backfill=true) OccupancyCurrent on table OccupancyStream
{
    OccupancyStream
    | summarize arg_max(ingestion_timestamp, *) by occupancySignalId
}
```

If the environment does not allow `*` in the materialized-view aggregation, list the required fields explicitly in `arg_max()`.

Validate freshness and expected entity counts:

```kusto
TrafficCurrent
| summarize Segments = count(), LatestEvent = max(timestamp)
```

```kusto
OccupancyCurrent
| summarize Locations = count(), LatestReceived = max(ingestion_timestamp)
```

The expected counts are 527 segments and 15 locations.

### Step 6: Find the current traffic problems

Current traffic state:

```kusto
TrafficCurrent
| lookup kind=leftouter (
    SpeedState
    | project speed_state_code = tolong(speed_state_code), speed_state_label
  ) on speed_state_code
| project
    timestamp,
    segment_id,
    road_name,
    zone_approx,
    speed_state_label,
    avg_speed_kmh,
    vehicle_count,
    incident_flag
| order by avg_speed_kmh asc
```

Top congested segments:

```kusto
TrafficCurrent
| where speed_state_code == 3
| top 10 by avg_speed_kmh asc
| project
    segment_id,
    road_name,
    zone_approx,
    avg_speed_kmh,
    vehicle_count,
    incident_flag,
    timestamp
```

Zone-level congestion:

```kusto
TrafficStream
| where timestamp > ago(30m)
| summarize
    avg_speed_kmh = round(avg(avg_speed_kmh), 1),
    total_vehicles = sum(vehicle_count),
    pct_congested = round(100.0 * countif(speed_state_code == 3) / count(), 1),
    incident_rate_pct = round(100.0 * countif(incident_flag) / count(), 1)
  by zone_approx
| order by pct_congested desc
```

CCIB corridor trend:

```kusto
TrafficStream
| where zone_approx == "Sant Marti / Ronda Litoral"
| summarize
    avg_speed_kmh = avg(avg_speed_kmh),
    total_vehicles = sum(vehicle_count)
  by bin(timestamp, 5m)
| render timechart
```

### Step 7: Investigate incidents and sensor health

Recent incidents:

```kusto
TrafficStream
| where incident_flag == true
| summarize
    incident_start = min(timestamp),
    incident_end = max(timestamp),
    min_speed_kmh = min(avg_speed_kmh),
    readings = count()
  by segment_id, road_name, zone_approx
| extend duration_min = datetime_diff("minute", incident_end, incident_start)
| order by incident_start desc
```

Sensors returning no data:

```kusto
TrafficStream
| summarize
    total = count(),
    no_data = countif(status_code == 0)
  by segment_id
| extend no_data_pct = round(100.0 * no_data / total, 1)
| where no_data_pct > 0
| order by no_data_pct desc
```

`Helper/kql_example_queries.kql` contains additional traffic analysis patterns.

### Step 8: Analyze occupancy pressure

Current occupancy:

```kusto
OccupancyCurrent
| extend occupancy_pct =
    round(100.0 * todouble(currentOccupancy) / todouble(totalOccupancy), 1)
| project
    ingestion_timestamp,
    occupancySignalId,
    category,
    currentOccupancy,
    totalOccupancy,
    occupancy_pct,
    geometry
| order by occupancy_pct desc
```

Locations above 80%:

```kusto
OccupancyCurrent
| extend occupancy_pct =
    round(100.0 * todouble(currentOccupancy) / todouble(totalOccupancy), 1)
| where occupancy_pct >= 80.0
| order by occupancy_pct desc
```

Occupancy trend:

```kusto
OccupancyStream
| extend occupancy_pct =
    100.0 * todouble(currentOccupancy) / todouble(totalOccupancy)
| summarize avg_occupancy_pct = avg(occupancy_pct)
  by occupancySignalId, bin(ingestion_timestamp, 30s)
| render timechart
```

### Step 9: Explore occupancy anomalies with KQL

The occupancy generator creates one rotating spike or drop in every five-minute Barcelona-time window:

```kusto
OccupancyStream
| extend occupancy_pct =
    100.0 * todouble(currentOccupancy) / todouble(totalOccupancy)
| make-series occupancy_pct = avg(occupancy_pct)
  on ingestion_timestamp
  from ago(30m) to now() step 10s
  by occupancySignalId
| extend anomalies = series_decompose_anomalies(occupancy_pct, 1.5)
| mv-expand
    ingestion_timestamp to typeof(datetime),
    occupancy_pct to typeof(real),
    anomalies to typeof(real)
| where anomalies != 0
| project
    ingestion_timestamp,
    occupancySignalId,
    occupancy_pct,
    anomaly_direction = iff(anomalies > 0, "Spike", "Drop")
| order by ingestion_timestamp desc
```

Run the occupancy generator for at least 10 minutes so the time series contains multiple normal and anomalous windows.

## Act 3: Visualize Data

### Step 1: Build the traffic map layer

Create a Fabric Map named `Barcelona Live Operations`.

Use one of these approaches:

- Bind `mid_lat` and `mid_lng` from `TrafficCurrent` for a point layer.
- Join `TrafficCurrent` to `SegmentLines()` and bind the GeoJSON `LineString` for a road layer.

Road-layer query:

```kusto
TrafficCurrent
| lookup kind=leftouter (
    SpeedState
    | project speed_state_code = tolong(speed_state_code), speed_state_label
  ) on speed_state_code
| join kind=leftouter (SegmentLines()) on segment_id
| project
    timestamp,
    segment_id,
    road_name,
    zone_approx,
    speed_state_code,
    speed_state_label,
    avg_speed_kmh,
    vehicle_count,
    incident_flag,
    mid_lat,
    mid_lng,
    geometry
```

Use a consistent state color:

| State | Suggested color |
| --- | --- |
| Fluid | Green |
| Dense | Amber |
| Congested | Red |
| No Data / Unknown | Gray |

Include the road, zone, speed, vehicle count, incident flag, and timestamp in the tooltip.

### Step 2: Build the occupancy map layer

Use the polygons already included in the occupancy stream:

```kusto
OccupancyCurrent
| extend occupancy_pct =
    round(100.0 * todouble(currentOccupancy) / todouble(totalOccupancy), 1)
| project
    ingestion_timestamp,
    occupancySignalId,
    category,
    currentOccupancy,
    totalOccupancy,
    occupancy_pct,
    geometry
```

Render `geometry` as a filled GeoJSON polygon and use occupancy percentage for color or intensity.

If the current Fabric Map configuration cannot combine the two query results in one view, create two synchronized map visuals or separate traffic and occupancy pages.

### Step 3: Build the Real-Time Dashboard

Create a Real-Time Dashboard named `Barcelona Operations Center` and connect it to `BarcelonaPulse`.

Use this suggested layout.

#### Current KPIs

Congested segments:

```kusto
TrafficCurrent
| summarize CongestedSegments = countif(speed_state_code == 3)
```

Active incidents:

```kusto
TrafficCurrent
| summarize ActiveIncidents = countif(incident_flag)
```

Average speed:

```kusto
TrafficCurrent
| summarize AverageSpeedKmh = round(avg(avg_speed_kmh), 1)
```

High-occupancy locations:

```kusto
OccupancyCurrent
| extend occupancy_pct =
    100.0 * todouble(currentOccupancy) / todouble(totalOccupancy)
| summarize HighOccupancyLocations = countif(occupancy_pct >= 80.0)
```

#### Trends

- CCIB corridor average speed and vehicle count.
- Occupancy percentage by location.
- Congestion percentage by zone.

#### Operational detail

- Ten slowest congested segments.
- Highest occupancy locations.
- Recent incidents.
- Sensors with no-data readings.

Add time-range, zone, and category parameters if time permits.

### Step 4: Configure anomaly detection

Use:

- Time field: `ingestion_timestamp`
- Entity key: `occupancySignalId`
- Metric: `100.0 * currentOccupancy / totalOccupancy`
- Aggregation: average

Start with the default sensitivity and tune only if the generated spike or drop is not detected. Ensure the occupancy generator runs long enough to provide normal behavior and at least one complete anomaly window.

### Step 5: Configure the alert

Create an Activator alert from the anomaly result or from a deterministic high-occupancy condition.

A practical condition is:

```text
Anomaly detected OR occupancy percentage is at least 90
```

Include:

- `occupancySignalId`
- `category`
- occupancy percentage
- current and total occupancy
- ingestion timestamp
- anomaly direction, when available

Choose a supported action such as email, Teams notification, or running another Fabric item. Test the condition while the generator is active and capture evidence that the action fired.

### Step 6: Create congested-segment Business Events

Use the enriched traffic stream or its derived Eventstream branch and filter:

```text
speed_state_code == 3
```

Use `Helper/traffic_schema.json` as the starting schema. The final Business Event should include:

- Segment identifier.
- Event timestamp.
- Speed state code and label.
- Average speed.
- Vehicle count.
- Incident flag.
- Zone or road context.
- Eventstream system timestamp.

Configure an Activator rule for repeated congestion, very low speed, or congestion combined with `incident_flag == true`.

### Step 7: Optional Operations agent

Create the agent only after the core map, dashboard, and anomaly flow work.

Ground the agent in curated objects such as:

- `TrafficCurrent`
- `OccupancyCurrent`
- `TrafficEnriched()`
- A zone congestion summary function
- A recent incidents function

Test realistic questions:

- Which zone is currently most congested?
- What are the five slowest road segments?
- Which locations are above 80% occupancy?
- Are there active incidents near the CCIB?
- Which sensors have recently returned no data?
- What changed during the last 15 minutes?

Validate every agent answer against a direct KQL query before including it in the demonstration.

## Final validation

Run both generators and verify the complete solution:

1. Both Eventstream source previews update.
2. Both Eventhouse tables receive new rows.
3. `TrafficCurrent` contains 527 segments.
4. `OccupancyCurrent` contains 15 locations.
5. Traffic speed and status labels are populated.
6. `SegmentLines()` returns one row per segment.
7. The map updates when new batches arrive.
8. Dashboard KPIs and trends refresh.
9. An occupancy spike or drop is detected.
10. The alert or action fires.
11. A congested record creates the expected Business Event.

Use this query to compare the most recent timestamps:

```kusto
print
    LatestTraffic = toscalar(TrafficStream | summarize max(timestamp)),
    LatestOccupancy = toscalar(OccupancyStream | summarize max(ingestion_timestamp))
```

The solution is complete when every checkbox in the `README.md` success criteria can be demonstrated with live evidence.
