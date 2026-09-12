# INSPIRE — AirFlow2 (n8n)

Part of the **INSPIRE** health initiative linked to **PUC** university projects. This repository publishes the **AirFlow2** n8n workflow that captures air-pollution sensor data, evaluates international health thresholds, correlates exceedances with possible human health impacts using AI agents grounded in medical knowledge sources, and publishes alerts to **ContextNet** for patients in sensor risk areas.

## Purpose

AirFlow2 is responsible for:

1. **Capturing** air-pollution readings from IoT sensors.
2. **Analyzing thresholds** against international health norms (e.g. EPA / WHO / ASHRAE-aligned configs).
3. **Correlating** pollutants above threshold with possible health problems those pollutants may cause, using AI agents and medical-community publication sources (vector RAG + disease mappings).
4. **Publishing** the resulting alert payload to **ContextNet** (via Kafka) so patients in the affected sensor areas can be notified.

## Repository contents

| Path | Description |
|------|-------------|
| `workflows/AirFlow2.json` | Exportable n8n workflow (import into n8n) |
| `README.md` | This documentation |

## Prerequisites

Before importing and running AirFlow2, prepare:

| Requirement | Why it is needed |
|-------------|------------------|
| **n8n** (self-hosted or cloud) with LangChain nodes | Hosts the workflow and AI agents |
| **Supabase** (or compatible Postgres API used by n8n Supabase nodes) | Persists `iot_sensor_data`, `alert_notifications`, and `system_config` (thresholds + disease mappings) |
| **PostgreSQL** (same or linked DB) | Aggregation queries over recent sensor windows; also hosts **PGVector** for scientific document embeddings |
| **OpenAI API** credentials | Chat models (`gpt-4.1` / `gpt-4.1-mini`) and embeddings used by agents and the vector store |
| **Kafka** broker reachable from n8n | Publishes alert messages to topic `AppModel` for ContextNet consumption |
| **ContextNet** integration consuming that Kafka topic | Delivers alerts to patients in risk areas |
| Configured n8n credentials | Re-bind after import: Supabase, OpenAI, Postgres, Kafka (export only keeps credential *names/ids*, not secrets) |

### Expected data / config surfaces

- Table **`iot_sensor_data`**: historical validated sensor readings.
- Table **`alert_notifications`**: persisted alert payloads (recipient marked as `contextNet`).
- Table **`system_config`**: JSON configs for pollutant thresholds (`id = 1`) and disease mappings (`id = 2`).
- PGVector collection/table **`documents`**: embeddings of uploaded scientific / medical documents.
- Webhook path **`/iot-data`** (POST): IoT ingestion endpoint.
- Form trigger **Add Document**: upload medical/scientific files into the vector knowledge base.

### Example IoT webhook payload fields

Sensors should POST a body including at least:

`id`, `CO2`, `PM1_0`, `PM2_5`, `PM4_0`, `PM_10`, `TypPS`, `T`, `H`, `P`, `G`, `sIAQ`

## Workflow overview (AirFlow2)

The workflow has **three coordinated paths**:

```text
[A] Ingest          Webhook → Validate → Save IoT Data (Supabase)
[B] Knowledge base  Form upload → Split → Embed → PGVector Store
[C] Alert pipeline  Schedule → Aggregate (Postgres)
                    → AI_AGENT_ALERT (thresholds)
                    → AI Agent (health correlation + RAG)
                    → Save Alert → Kafka (ContextNet)
```

### Path A — Sensor capture and storage

1. **IoT Data Webhook** receives POST `/iot-data`.
2. **Validate IoT Data** checks required fields and numeric ranges, then normalizes pollutants (CO₂, PM1/2.5/4/10, CO/TypPS, gas), environment (T/H/P), and IAQ.
3. **Save IoT Data** writes the reading to Supabase `iot_sensor_data` for historical analysis.

### Path B — Medical / scientific knowledge ingestion

1. **On form submission** accepts a document upload.
2. The document is split (**Recursive Character Text Splitter**), embedded (**Embeddings OpenAI**), and stored in **Postgres PGVector Store**.
3. This vector base later supports the health-correlation agent (`vector_base` tool), so inferences can be cross-checked against publications from the medical community.

### Path C — Threshold analysis, health correlation, and ContextNet alert

1. **Schedule Trigger** runs on a short interval and queries Postgres for **per-sensor averages** over the last **5 minutes** (valid readings only).
2. **AI_AGENT_ALERT** (threshold agent) compares averages to configured international thresholds via the **`pollutant_thresholds`** tool (`system_config`).
   - Risk bands: `low`, `moderate`, `high`, `critical`.
   - Only pollutants **above `low`** continue in the pipeline.
3. If thresholds are affected, **AI Agent** (health correlation agent) runs with:
   - **`disease_mappings`** tool — maps pollutants to short-/medium-/long-term health effects;
   - **`vector_base`** tool — RAG over embedded medical/scientific documents;
   - OpenAI chat model for structured JSON alert generation (sensor, pollutant, risk level, affected diseases).
4. **Process Analysis** / **If** gates ensure an alert exists before persistence.
5. **Save Alert** stores the notification in `alert_notifications`.
6. **Edit Fields** / **Process Analysis4** shape the message.
7. **Kafka** publishes to topic **`AppModel`** for **ContextNet**, enabling patient alerts in the geographic risk areas covered by the sensors.

## AI agents in detail

### 1. `AI_AGENT_ALERT` — threshold evaluation

| Aspect | Detail |
|--------|--------|
| Model | OpenAI Chat (`gpt-4.1`) |
| Tool | `pollutant_thresholds` (Supabase `system_config`) |
| Input | Aggregated sensor averages from Postgres |
| Job | Classify each pollutant vs EPA/WHO/ASHRAE-style bands |
| Output | JSON listing only non-`low` pollutants and risk levels (or `threshold_afected = Não Encontrado` when none) |

### 2. `AI Agent` — health impact correlation

| Aspect | Detail |
|--------|--------|
| Model | OpenAI Chat (`gpt-4.1-mini`) |
| Tools | `disease_mappings` (config JSON of pollutant → diseases by exposure window); `vector_base` (PGVector RAG) |
| Input | Threshold exceedance analysis from the previous agent |
| Job | Correlate elevated pollutants with possible human health problems (focus on short-term respiratory and related risks), validating against vectorized medical sources |
| Output | Structured alert JSON: `alert_id`, timestamp, sensors, pollutants, `risk_level`, `affected_diseases` |

Together, the agents implement the project goal: **norm-based thresholding** plus **evidence-informed health correlation**, then **ContextNet publication** for at-risk patients.

## Importing into n8n

1. Open n8n → **Workflows** → **Import from File**.
2. Select `workflows/AirFlow2.json`.
3. Reconnect credentials: Supabase, OpenAI, Postgres, Kafka.
4. Confirm tables/configs (`iot_sensor_data`, `system_config`, `alert_notifications`, PGVector `documents`) exist and are populated.
5. Activate the workflow and verify webhook URL, schedule, and Kafka topic `AppModel`.

## Security notes

- The exported JSON references credential **names/IDs** only; it does **not** embed API keys or passwords.
- Do not commit live secrets. Configure them in your n8n instance environment.
- Treat medical alert outputs as decision-support for the broader INSPIRE/PUC health stack, not as a standalone clinical diagnosis system.

## Project context

**Organization:** [EnQyMo](https://github.com/orgs/EnQyMo/)  
**Repository:** INSPIRE  
**Domain:** Environmental health / air quality / patient alerting  
**University context:** PUC-related health project workstream
