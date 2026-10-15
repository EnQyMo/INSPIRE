--
-- Tabela iot_sensor_data
-- Tabela para armazenar todos dos dados recebidos pelos sensores, com o objetivo de:
-- - Criar um histórico de dados, possibilitando auditoria e analises futuras
-- - Processamento no fluxo do INSPIRE
--
create table public.iot_sensor_data (
  id serial not null,
  sensor_id character varying(100) not null,
  "timestamp" timestamp with time zone not null,
  pm25 numeric(8, 2) null,
  pm10 numeric(8, 2) null,
  pm1 numeric(8, 2) null,
  pm4 numeric(8, 2) null,
  co2 integer null,
  temperature numeric(5, 2) null,
  humidity numeric(5, 2) null,
  pressure numeric(8, 2) null,
  gas numeric(12, 2) null,
  typps numeric(5, 2) null,
  air_quality_index integer null,
  validation_status character varying(20) null default 'valid'::character varying,
  processed_at timestamp with time zone null default now(),
  created_at timestamp with time zone null default now(),
  constraint iot_sensor_data_pkey primary key (id)
) TABLESPACE pg_default;

create index IF not exists idx_iot_sensor_new_sensor_id on public.iot_sensor_data using btree (sensor_id) TABLESPACE pg_default;

create index IF not exists idx_iot_sensor_new_timestamp on public.iot_sensor_data using btree ("timestamp") TABLESPACE pg_default;

create index IF not exists idx_iot_sensor_new_air_quality_index on public.iot_sensor_data using btree (air_quality_index) TABLESPACE pg_default;

--
-- Tabela documents
-- Tabela para armazenar todos os papers de pesquisa relevante que serão utilizados com o objetivo de:
-- - RAG para os agentes de IA fazerem correlação de doenças
-- - Vetorização dos documentos para facilitar a busca da IA
--
create table public.documents (
  id uuid not null default extensions.uuid_generate_v4 (),
  text text null,
  metadata jsonb null,
  embedding public.vector null,
  constraint documents_pkey primary key (id)
) TABLESPACE pg_default;

--
-- Tabela system_config
-- Tabela para armazenar as configurações do sistema com o objetivo de:
-- - Parametrizar os thresholds de alto, medio, baixo e critico dos valores dos sensores X paramentros de saúde
-- - Primeira correlação de possíveis doenças associadas
--

create table public.system_config (
  id serial not null,
  config_key character varying(100) not null,
  config_value jsonb not null,
  description text null,
  created_at timestamp with time zone null default now(),
  updated_at timestamp with time zone null default now(),
  constraint system_config_pkey primary key (id),
  constraint system_config_config_key_key unique (config_key)
) TABLESPACE pg_default;

create trigger update_system_config_updated_at BEFORE
update on system_config for EACH row
execute FUNCTION update_updated_at_column ();

--
-- Tabela alert_notifications
-- Tabela para armazenar todos os alertas enviados para o contextnet de locais onde estão fora dos parametros de saude e as doenças associadas
--
create table public.alert_notifications (
  id serial not null,
  alert_id character varying(100) not null,
  notification_type character varying(20) not null,
  recipient text not null,
  status character varying(20) null default 'sent'::character varying,
  sent_at timestamp with time zone null default now(),
  message_content text null,
  created_at timestamp with time zone null default now(),
  constraint alert_notifications_pkey primary key (id)
) TABLESPACE pg_default;

create index IF not exists idx_alert_notifications_alert_id on public.alert_notifications using btree (alert_id) TABLESPACE pg_default;
