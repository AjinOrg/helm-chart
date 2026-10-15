{{/* Service name = Helm release name (ArgoCD: the folder name under apps/) */}}
{{- define "microservice.name" -}}
{{- .Release.Name -}}
{{- end -}}

{{- define "microservice.environment" -}}
{{- required "environment is required (apps/<service>/values-<env>.yaml)" .Values.environment -}}
{{- end -}}

{{/* Common labels on every object */}}
{{- define "microservice.labels" -}}
app.kubernetes.io/name: {{ include "microservice.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ required "image.tag is required" .Values.image.tag | quote }}
app.kubernetes.io/part-of: aws-platform
app.kubernetes.io/managed-by: {{ .Release.Service }}
environment: {{ include "microservice.environment" . }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/* Labels used to select the pods (must never change after the first deploy) */}}
{{- define "microservice.selectorLabels" -}}
app.kubernetes.io/name: {{ include "microservice.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "microservice.secretsMountPath" -}}
{{- .Values.secrets.mountPath | default (printf "/etc/%s/secrets" (include "microservice.name" .)) -}}
{{- end -}}

{{- define "microservice.secretsManagerKey" -}}
{{- .Values.secrets.secretsManagerKey | default (printf "%s/%s/%s" .Values.secrets.keyPrefix (include "microservice.name" .) (include "microservice.environment" .)) -}}
{{- end -}}

{{- define "microservice.ingressPath" -}}
{{- .Values.ingress.path | default (printf "/%s/%s" (include "microservice.environment" .) (include "microservice.name" .)) -}}
{{- end -}}
