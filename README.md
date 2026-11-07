# INSPIRE — AirFlow2 (n8n)

## Description

AirFlow2 is an **n8n** workflow from the **INSPIRE** health initiative, part of the **PUC-Rio** university projects. It turns raw air-pollution readings from IoT sensors into health alerts for patients in the sensors' coverage areas. It handles:

- **Capture.** It receives air-quality readings from IoT sensors over an HTTP webhook, validates them, and stores them in a historical table.
- **Threshold analysis.** Every 2 minutes, it averages each sensor's last 5 minutes of readings. An AI agent then classifies each pollutant as `low`, `moderate`, `high` or `critical`, using thresholds based on EPA, WHO, ANVISA and ASHRAE references.
- **Health correlation.** A second AI agent maps the pollutants above `low` to their possible **short-term** health effects. It uses a disease-mapping configuration and checks it against a vector knowledge base (RAG) of scientific PDFs.
- **Publication.** It persists the resulting alert and publishes it to **ContextNet** via **Kafka** (topic `AppModel`), so patients in the affected sensor areas can be notified.

**Repository:** https://github.com/EnQyMo/INSPIRE  
**Organization:** [EnQyMo](https://github.com/orgs/EnQyMo/)  
**Domain:** Environmental health / air quality / patient alerting

> **Scope:** AirFlow2 is a decision-support component of the broader INSPIRE/PUC health stack. It is **not** a standalone clinical diagnosis system.
>
> **Language:** the agent prompts, disease names and alert contents are in **Portuguese (pt-BR)**.

## Dataset Information

This repository does not ship a static sensor dataset. The workflow **produces and stores live data at runtime**. The configuration entries used in the experiments are provided in `database/experiment_data.sql`.

- **Source of data:** IoT air-quality sensors POST JSON readings to the `/iot-data` webhook. 
- **`iot_sensor_data`:** the historical table of validated readings, used for auditing, later analysis and the alert pipeline.
- **`alert_notifications`:** every alert sent to ContextNet, with the full alert JSON in `message_content`.
- **`system_config`:** JSON configuration in `config_value`. Pollutant thresholds are at `id = 1` and disease mappings at `id = 2` (see [Methodology](#methodology)).
- **`documents`:** the PGVector table holding text chunks, metadata and embeddings of the scientific papers used for RAG.

### Sensor payload → stored columns

| Payload field | Column in `iot_sensor_data` | Meaning | Unit | Evaluated against thresholds? |
|---|---|---|---|---|
| `id` | `sensor_id` (varchar 100) | Sensor identifier | — | — |
| `CO2` | `co2` (integer) | Carbon dioxide | ppm | Yes (`CO2`) |
| `PM1_0` | `pm1` (numeric 8,2) | Particulate matter ≤ 1.0 µm | µg/m³ | Yes (`PM1`) |
| `PM2_5` | `pm25` (numeric 8,2) | Particulate matter ≤ 2.5 µm | µg/m³ | Yes (`PM2.5`) |
| `PM4_0` | `pm4` (numeric 8,2) | Particulate matter ≤ 4.0 µm | µg/m³ | Yes (`PM4`) |
| `PM_10` | `pm10` (numeric 8,2) | Particulate matter ≤ 10 µm | µg/m³ | Yes (`PM10`) |
| `TypPS` | `typps` (numeric 5,2) | Treated by the workflow as **CO** (see [Known limitations](#known-limitations)) | ppm (as configured) | Yes (`CO`) |
| `sIAQ` | `air_quality_index` (integer) | Static indoor air quality index | index | Yes (`IAQ`) |
| `G` | `gas` (numeric 12,2) | Gas sensor reading |  | No (stored and averaged only) |
| `T` | `temperature` (numeric 5,2) | Temperature | °C | No |
| `H` | `humidity` (numeric 5,2) | Relative humidity | | No |
| `P` | `pressure` (numeric 8,2) | Barometric pressure | | No |

The workflow also fills `timestamp` and `created_at` with the n8n server time at reception, not the sensor's own clock. It sets `validation_status` to `'valid'` and `processed_at` to the processing time.

### Exporting a dataset

```sql
COPY (
  SELECT * FROM iot_sensor_data
  WHERE "timestamp" BETWEEN '2026-01-01' AND '2026-02-01'
  ORDER BY sensor_id, "timestamp"
) TO STDOUT WITH CSV HEADER;
```

Export `alert_notifications` the same way to pair readings with the alerts they produced. To generate a comparable **simulated** dataset, see [Reproduction Script](#reproduction-script).

## Code Information

```
INSPIRE/
├── workflows/
│   └── AirFlow2.json          # Exportable n8n workflow (import into n8n)
├── database/                  # (to be added)
│   ├── schema.sql             # Table definitions: iot_sensor_data, documents, system_config, alert_notifications
│   └── experiment_data.sql    # Entries used in the experiments (system_config thresholds + disease mappings, etc.)
├── scripts/                   # (to be added)
│   └── simulate_sensors.py    # Posts synthetic sensor readings to the webhook
├── LICENSE                    # (to be added — see License section)
└── README.md
```

The workflow has three paths:

```text
[A] Ingest          IoT Data Webhook → Validate IoT Data → Save IoT Data (iot_sensor_data)
[B] Knowledge base  On form submission (PDF) → Default Data Loader + Recursive Character Text Splitter
                    → Embeddings OpenAI → Postgres PGVector Store (documents)
[C] Alert pipeline  Schedule Trigger (2 min) → Postgres (5-min averages per sensor)
                    → AI_AGENT_ALERT → Process Analysis1 → If1 (any pollutant above low?)
                    → AI Agent → Process Analysis → If (alert generated?)
                         ├─ yes → Save Alert (alert_notifications) → Edit Fields → Process Analysis4 → Kafka (AppModel)
                         └─ no  → Stop and Error
```

**Nodes**

| Node | Type | Role |
|---|---|---|
| `IoT Data Webhook` | Webhook (POST `iot-data`) | Receives sensor readings |
| `Validate IoT Data` | Code | Checks required and non-negative numeric fields, then normalizes the payload |
| `Save IoT Data` | Supabase | Inserts the reading into `iot_sensor_data` |
| `On form submission` | Form trigger ("Add Document") | Single-file upload |
| `Default Data Loader` | LangChain loader (`pdfLoader`, binary) | Reads uploaded **PDFs** |
| `Recursive Character Text Splitter` | LangChain splitter | Chunks documents (n8n default settings) |
| `Embeddings OpenAI` / `Embeddings OpenAI1` | LangChain embeddings | Embeds chunks and queries (node default model) |
| `Postgres PGVector Store` | PGVector (insert) | Writes to table `documents` |
| `Schedule Trigger` | Schedule | Fires every **2 minutes** |
| `Postgres` | Execute query | Computes per-sensor 5-minute averages (query below) |
| `AI_AGENT_ALERT` | AI Agent v1.8 + `gpt-4.1` | Threshold classification |
| `pollutant_thresholds` | Supabase tool | Reads `system_config` where `id = 1` |
| `Process Analysis1` / `If1` | Code / If | Parses the agent output; continues only if `threshold_afected` is empty |
| `AI Agent` | AI Agent v1.8 + `gpt-4.1-mini` | Health correlation |
| `disease_mappings` | Supabase tool | Reads `system_config` where `id = 2` |
| `vector_base` | PGVector (retrieve-as-tool, tool name `document_base`) | RAG over `documents` |
| `Process Analysis` / `If` | Code / If | Extracts the alert JSON; continues if `alert.length > 0`, otherwise goes to `Stop and Error` |
| `Save Alert` | Supabase | Inserts into `alert_notifications` |
| `Edit Fields` / `Process Analysis4` | Set / Code | Serializes `alert[0]` and re-parses it for publishing |
| `Kafka` | Kafka producer | Publishes to topic `AppModel` (`acks: false`) |

**Aggregation query (`Postgres` node)**

```sql
SELECT sensor_id,
       AVG(pm25) AS avg_pm25, AVG(pm10) AS avg_pm10, AVG(pm1) AS avg_pm1, AVG(pm4) AS avg_pm4,
       AVG(co2) AS avg_co2, AVG(temperature) AS avg_temperature, AVG(humidity) AS avg_humidity,
       AVG(pressure) AS avg_pressure, AVG(gas) AS avg_gas, AVG(typPS) AS avg_co,
       AVG(air_quality_index) AS avg_air_quality_index, COUNT(*) AS total_readings
FROM iot_sensor_data
WHERE timestamp >= NOW() - INTERVAL '5 min'
  AND validation_status = 'valid'
GROUP BY sensor_id
ORDER BY sensor_id;
```

## Usage Instructions

### 1. Get the workflow

```bash
git clone https://github.com/EnQyMo/INSPIRE.git
cd INSPIRE
```

### 2. Prepare the database

The schema targets **Supabase** (it uses `extensions.uuid_generate_v4()` and a `vector` column). On plain PostgreSQL, run this prelude first. On Supabase, only the function is needed if it doesn't already exist.

```sql
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS vector;

-- Used by the update_system_config_updated_at trigger
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

Then create the tables and load the experiment configuration:

```bash
psql "$DATABASE_URL" -f database/schema.sql
psql "$DATABASE_URL" -f database/experiment_data.sql
```

The workflow reads thresholds from `system_config` row **`id = 1`** and disease mappings from row **`id = 2`** (column `config_value`). Make sure those IDs line up after loading.

### 3. Import the workflow

1. Open n8n → **Workflows** → **Import from File** → `workflows/AirFlow2.json`.
2. Re-bind the credentials **Supabase account**, **OpenAi account**, **Postgres account** and **Kafka account**. The export keeps only credential names and IDs, not secrets.
3. Point the Kafka credential at your broker. ContextNet must consume topic `AppModel`.
4. Activate the workflow. It is exported with `active: false`.

### 4. Send a test reading

```bash
curl -X POST "https://<your-n8n-host>/webhook/iot-data" \
  -H "Content-Type: application/json" \
  -d '{"id":"IAQ_6227821","CO2":1450,"PM1_0":15,"PM2_5":40,"PM4_0":30,"PM_10":60,
       "TypPS":0.6,"T":27.5,"H":65,"P":1009,"G":45000,"sIAQ":120}'
```

Every field is required and must be a **non-zero**, non-negative number (see [Known limitations](#known-limitations)). The next scheduled run, at most 2 minutes later, picks the reading up.

### 5. Upload scientific documents

Open the **Add Document** form URL from the `On form submission` node and upload one **PDF** at a time. It is chunked, embedded and stored in `documents`.

### 6. Outputs

**Threshold agent (intermediate).** When at least one pollutant is above `low`:

```json
{ "alert_id": "threshold_1705312200000", "timestamp": "…", "sensor_id": "IAQ_6223456",
  "thresholds": { "poluente": "co2", "indicador": { "risk_level": "moderate", "value": 1250 } } }
```

When nothing is above `low`, the agent returns `{ "threshold_afected": "Não Encontrado" }` ("not found") and the run stops.

**Final alert.** Saved to `alert_notifications.message_content`; `alert[0]` is published to Kafka:

```json
{
  "alert": [{
    "alert_id": "alert_1705312200000",
    "timestamp": "2024-01-15T11:30:00Z",
    "sensores": [{
      "sensor_id": "IAQ_6227821",
      "poluentes": [
        { "poluente": "CO2",   "risk_level": "critical",
          "affected_diseases": { "disease": ["dor de cabeça leve", "dificuldade de concentração", "fadiga"] } },
        { "poluente": "PM2.5", "risk_level": "moderate",
          "affected_diseases": { "disease": ["asma", "bronquite", "irritação respiratória"] } }
      ]
    }]
  }]
}
```

The `alert_notifications` row stores `alert_id`, `sent_at` (the alert timestamp), `message_content` (the full JSON), `notification_type = 'alert'`, `recipient = 'contextNet'` and `status = 'sent'` (the default). The Kafka message body is `{"analisys": <alert[0]>}`.

## Requirements

**Platform**
- n8n with the LangChain / AI nodes. The workflow uses AI Agent node v1.8, OpenAI Chat Model v1.2 and PGVector Store v1.1. 
- **Supabase** (recommended) or PostgreSQL with the `vector` (pgvector) and `uuid-ossp` extensions.
- Apache Kafka broker reachable from n8n.
- A ContextNet integration consuming topic `AppModel`.

**External services**
- OpenAI API:
  - `gpt-4.1` for the threshold agent;
  - `gpt-4.1-mini` for the health-correlation agent;
  - the OpenAI Embeddings node's default model for document and query embeddings.

**n8n credentials**
- Supabase, OpenAI, Postgres (the same database as Supabase, used for the aggregation query and PGVector), Kafka.

**Helper script**
- Python 3.9+ with `requests` (for `scripts/simulate_sensors.py`).

## Methodology

### 1. Acquisition and validation

`Validate IoT Data` rejects a reading in either of these cases:
- one of the 12 required fields is missing or falsy;
- one of the numeric fields isn't a number or is negative.

Valid readings are normalized into `pollutants`, `environmental` and `air_quality_index` groups and written to `iot_sensor_data` with `validation_status = 'valid'`. No upper-bound range checks are applied.

### 2. Aggregation

Every **2 minutes**, the `Postgres` node averages each sensor's valid readings from the **last 5 minutes**. Averaging smooths short spikes. Because the window (5 min) is longer than the interval (2 min), consecutive runs overlap.

### 3. Threshold classification (`AI_AGENT_ALERT`, `gpt-4.1`)

The agent maps the averages to configured pollutants as follows:

| Configured pollutant | Average field |
|---|---|
| `PM2.5` | `avg_pm25` |
| `PM10` | `avg_pm10` |
| `PM1` | `avg_pm1` |
| `PM4` | `avg_pm4` |
| `CO2` | `avg_co2` |
| `CO` | `avg_co` |
| `IAQ` | `avg_air_quality_index` |

It reads the bands from `system_config.config_value` (id 1) through the `pollutant_thresholds` tool, which it is told to use as its only knowledge source. It keeps only the pollutants **not** classified as `low`.

Thresholds used in the experiments:

| Pollutant | Unit | Reference | low | moderate | high | critical |
|---|---|---|---|---|---|---|
| PM2.5 | µg/m³ | EPA / WHO | 0 – 12 | 12.1 – 35.4 | 35.5 – 55.4 | ≥ 55.5 |
| PM10 | µg/m³ | EPA / WHO | 0 – 54 | 55 – 154 | 155 – 254 | ≥ 255 |
| PM4 | µg/m³ | EPA / market practice | 0 – 10 | 10.1 – 25 | 25.1 – 50 | ≥ 50.1 |
| PM1 | µg/m³ | EPA / market practice | 0 – 10 | 10.1 – 20 | 20.1 – 40 | ≥ 40.1 |
| CO2 | ppm | ANVISA / ASHRAE | 400 – 1000 | 1001 – 1500 | 1501 – 2000 | ≥ 2001 |
| CO | ppm | EPA | 0 – 9 | 9.1 – 35 | 35.1 – 100 | ≥ 100.1 |
| IAQ | index | EPA general index | 0 – 50 | 51 – 100 | 101 – 150 | ≥ 151 |

The configuration is stored in this shape:

```json
{ "poluentes": [ { "nome": "PM2.5", "unidade": "µg/m³", "referencia": "EPA / OMS",
    "thresholds": { "low": {"min": 0, "max": 12}, "moderate": {"min": 12.1, "max": 35.4},
                    "high": {"min": 35.5, "max": 55.4}, "critical": {"min": 55.5, "max": null} } } ] }
```

### 4. Health correlation (`AI Agent`, `gpt-4.1-mini`)

For each sensor and each pollutant above `low`, the agent looks up the pollutant by `nome` in the disease-mapping config (`system_config` id 2, via `disease_mappings`) and takes the diseases listed under **`curto_prazo`** (short-term). The config also defines medium-term (`medio_prazo`) and long-term (`longo_prazo`) effects with severity and exposure intervals, but the agent uses only short-term effects.

Before producing its output, the agent queries the vector knowledge base to check whether the scientific literature suggests adding or changing any disease.

| Mapping entry (`nome`) | Short-term effects (as emitted, pt-BR) | English | Exposure interval |
|---|---|---|---|
| PM2.5 e PM10 | asma, bronquite, irritação respiratória | asthma, bronchitis, respiratory irritation | minutes to 7 days |
| PM4 e PM1 | irritação respiratória, inflamação sistêmica leve | respiratory irritation, mild systemic inflammation | minutes to 7 days |
| CO | dor de cabeça, náuseas, confusão mental, fadiga | headache, nausea, mental confusion, fatigue | minutes to a few hours |
| CO2 | dor de cabeça leve, dificuldade de concentração, fadiga | mild headache, difficulty concentrating, fatigue | minutes to 7 days |
| IAQ (Índice Geral de Qualidade do Ar) | irritação olhos, nariz e garganta; dor de cabeça; alergias respiratórias | eye, nose and throat irritation; headache; respiratory allergies | minutes to 7 days |

### 5. Persistence and publication

If the agent produced at least one alert, the alert is saved to `alert_notifications`. Its first element is then serialized and published to Kafka topic `AppModel` for ContextNet, which notifies patients in the sensors' areas. If no alert was produced, the run ends in `Stop and Error`.

### 6. Knowledge base construction

Uploaded PDFs are loaded with the PDF loader and split with the recursive character text splitter (n8n defaults). They are embedded with the OpenAI Embeddings node's default model and stored in `documents` (`text`, `metadata`, `embedding`).

### Known limitations

- **`TypPS` is treated as CO.** The workflow maps `TypPS` to `pollutants.co` / `avg_co` and evaluates it against CO thresholds in ppm. On particulate sensors, `TypPS` usually denotes *typical particle size* (µm). Interpret CO results accordingly.
- **Zero values are rejected.** Validation uses a truthiness check, so any field equal to `0` is reported as missing. Normalization (`parseFloat(x) || null`) would also turn `0` into `null`.
- **The webhook response mode** is set to "Respond to Webhook node", but the workflow has no such node. Clients may receive an error or time out even though the reading is saved.
- **Tool name mismatch.** The RAG tool is exposed to the agent as `document_base`, while the agent prompt refers to it as `vector_base`.
- **Repeated alerts.** The 2-minute schedule over a 5-minute window means the same readings can contribute to consecutive runs.
- **Per-row agent runs.** `AI_AGENT_ALERT` receives all Postgres rows on every item (`$('Postgres').all()`), so with several sensors the threshold analysis may run once per sensor over the full set.
- **LLM classification.** Threshold classification and disease mapping are performed by LLMs following rules, not by deterministic code, so outputs may vary between runs.

## Reproduction Script

There is no static sensor dataset to regenerate. To reproduce the experimental environment:

1. Create the schema and load the experiment configuration: `database/schema.sql`, then `database/experiment_data.sql` (see [Usage step 2](#2-prepare-the-database)).
2. Import and activate `workflows/AirFlow2.json`.
3. Upload the same scientific PDFs used in the experiments through the **Add Document** form (see [Citations](#citations)).
4. Generate sensor traffic with the simulator below. Then export `iot_sensor_data` and `alert_notifications` as shown in [Exporting a dataset](#exporting-a-dataset).

### `scripts/simulate_sensors.py`

```python
"""Post synthetic air-quality readings to the AirFlow2 webhook.

Usage:
  python simulate_sensors.py --url https://<host>/webhook/iot-data \
      --sensors 3 --interval 10 --count 60 --spike-prob 0.2 --seed 42

Values are always > 0 because the workflow rejects zero-valued fields.
Spikes push pollutants into the moderate/high/critical bands of the
experiment thresholds (e.g. PM2.5 > 12 µg/m³, CO2 > 1000 ppm, IAQ > 50).
"""
import argparse
import random
import time

import requests


def reading(sensor_id: str, spike: bool) -> dict:
    f = random.uniform(3, 6) if spike else 1.0
    pm1 = random.uniform(2, 6) * f
    pm25 = pm1 + random.uniform(1, 4) * f
    pm4 = pm25 + random.uniform(0.5, 2) * f
    pm10 = pm4 + random.uniform(1, 5) * f
    return {
        "id": sensor_id,
        "CO2": round(random.uniform(450, 900) * (random.uniform(1.4, 2.6) if spike else 1.0)),
        "PM1_0": round(pm1, 2),
        "PM2_5": round(pm25, 2),
        "PM4_0": round(pm4, 2),
        "PM_10": round(pm10, 2),
        "TypPS": round(random.uniform(0.4, 1.2), 2),
        "T": round(random.uniform(20, 30), 2),
        "H": round(random.uniform(40, 75), 2),
        "P": round(random.uniform(1000, 1020), 2),
        "G": round(random.uniform(20_000, 200_000), 2),
        "sIAQ": round(random.uniform(20, 50) * (random.uniform(1.5, 4) if spike else 1.0)),
    }


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--url", required=True)
    p.add_argument("--sensors", type=int, default=3)
    p.add_argument("--interval", type=float, default=10, help="seconds between rounds")
    p.add_argument("--count", type=int, default=60, help="number of rounds")
    p.add_argument("--spike-prob", type=float, default=0.2)
    p.add_argument("--seed", type=int, default=42)
    args = p.parse_args()

    random.seed(args.seed)
    ids = [f"IAQ_{6227821 + i}" for i in range(args.sensors)]
    for n in range(args.count):
        spike = random.random() < args.spike_prob
        for sid in ids:
            r = requests.post(args.url, json=reading(sid, spike), timeout=10)
            print(f"[{n + 1}/{args.count}] {sid} spike={spike} -> {r.status_code}")
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
```

The fixed `--seed` makes the generated readings repeatable. The alert outputs can still vary, because classification is done by LLMs.

## Citations

If you use AirFlow2 in academic work, please cite this repository:

```bibtex
@misc{enqymo_inspire_airflow2,
  author       = {{EnQyMo}},
  title        = {{INSPIRE — AirFlow2: n8n workflow for air pollution sensing,
                   threshold analysis, AI health correlation, and ContextNet alerts}},
  year         = {2026},
  howpublished = {\url{https://github.com/EnQyMo/INSPIRE}},
  note         = {PUC — INSPIRE health project}
}
```

**Threshold references.** These are the sources named in the `referencia` field of the threshold configuration:

- World Health Organization. *WHO global air quality guidelines: particulate matter (PM2.5 and PM10), ozone, nitrogen dioxide, sulfur dioxide and carbon monoxide.* Geneva: WHO, 2021.
- U.S. Environmental Protection Agency. *Technical Assistance Document for the Reporting of Daily Air Quality – the Air Quality Index (AQI)*, 2018 edition. The PM2.5, PM10, CO and index bands follow its AQI breakpoints.
- Agência Nacional de Vigilância Sanitária (ANVISA). *Resolução RE nº 9, de 16 de janeiro de 2003* — reference standards for indoor air quality in climate-controlled environments.
- ASHRAE. *Standard 62.1 — Ventilation and Acceptable Indoor Air Quality.*

**Knowledge base.** Dynamically created but what we used initially is in [documents_rows_data.sql](https://github.com/EnQyMo/INSPIRE/blob/main/workflows/documents_rows_data.sql)

## License & Contribution Guidelines

No license file is currently included in this repository, so the code is not licensed for reuse or redistribution until one is added. Contact the repository owner ([EnQyMo](https://github.com/orgs/EnQyMo/)) before reusing this workflow.

Contributions: this repository does not currently define a formal contribution process. If you'd like to contribute, please [open an issue](https://github.com/EnQyMo/INSPIRE/issues) first to discuss the proposed change before submitting a pull request.

**Security:** the exported workflow references credential names and IDs only; it does not embed API keys or passwords. Never commit live secrets; configure them only in your n8n instance.
