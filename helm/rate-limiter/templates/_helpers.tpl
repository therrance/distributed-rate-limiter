{{- define "rate-limiter.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "rate-limiter.fullname" -}}
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

{{- define "rate-limiter.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "rate-limiter.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "rate-limiter.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "rate-limiter.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Redis host the edge connects to: the in-cluster Service or an external one.

Must be fully qualified. nginx's `resolver` queries the literal name and does
NOT apply the `search` domains from /etc/resolv.conf, so the bare Service name
that works under Docker's embedded DNS fails here with "Host not found".
*/}}
{{- define "rate-limiter.redisHost" -}}
{{- if .Values.redis.enabled -}}
{{- printf "%s-redis.%s.svc.%s" (include "rate-limiter.fullname" .) .Release.Namespace .Values.clusterDomain -}}
{{- else -}}
{{- required "redis.external.host is required when redis.enabled is false" .Values.redis.external.host -}}
{{- end -}}
{{- end -}}

{{- define "rate-limiter.redisPort" -}}
{{- if .Values.redis.enabled -}}{{ .Values.redis.port }}{{- else -}}{{ .Values.redis.external.port }}{{- end -}}
{{- end -}}

{{/* Fully-qualified app Service, for the edge's proxy_pass upstream. */}}
{{- define "rate-limiter.appHost" -}}
{{- printf "%s-app.%s.svc.%s" (include "rate-limiter.fullname" .) .Release.Namespace .Values.clusterDomain -}}
{{- end -}}
