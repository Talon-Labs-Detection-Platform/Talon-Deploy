{{- define "talon-control.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "talon-control.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "talon-control.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "talon-control.selectorLabels" -}}
app.kubernetes.io/name: {{ include "talon-control.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "talon-control.labels" -}}
helm.sh/chart: {{ include "talon-control.chart" . }}
{{ include "talon-control.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "talon-control.secretName" -}}
{{- if .Values.secrets.existingSecret -}}
{{- .Values.secrets.existingSecret -}}
{{- else -}}
{{- printf "%s-secrets" (include "talon-control.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/* The PVC holding /app/data: one you manage, or the one this chart renders. */}}
{{- define "talon-control.dataClaimName" -}}
{{- if .Values.persistence.existingClaim -}}
{{- .Values.persistence.existingClaim -}}
{{- else -}}
{{- printf "%s-data" (include "talon-control.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "talon-control.postgresHost" -}}
{{- printf "%s-postgres" (include "talon-control.fullname" .) -}}
{{- end -}}

{{/*
  The bundled Postgres password, required. The chart used to default it to
  "talon", which the pod and every connection URL silently took, so
  it is no longer defaulted: set postgres.password, or reference an existing
  Secret with postgres.passwordSecret and supply the password there.
*/}}
{{- define "talon-control.postgresPassword" -}}
{{- required "postgres.password is required for bundled Postgres — generate one (openssl rand -hex 24) and set it via --set/values, or reference an existing Secret with postgres.passwordSecret. It binds at first init; rotating it later is a manual ALTER ROLE." .Values.postgres.password -}}
{{- end -}}

{{/* The Postgres connection URL: bundled service, or the external URL. */}}
{{- define "talon-control.postgresUrl" -}}
{{- if .Values.postgres.bundled -}}
{{- printf "postgresql://%s:%s@%s:5432/%s" .Values.postgres.user (include "talon-control.postgresPassword" .) (include "talon-control.postgresHost" .) .Values.postgres.database -}}
{{- else -}}
{{- required "postgres.external.url is required when postgres.bundled=false" .Values.postgres.external.url -}}
{{- end -}}
{{- end -}}
