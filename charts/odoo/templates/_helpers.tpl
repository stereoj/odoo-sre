{{- define "odoo.fullname" -}}
{{- .Release.Name }}-odoo
{{- end -}}

{{- define "odoo.labels" -}}
app.kubernetes.io/name: odoo
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "odoo.selectorLabels" -}}
app.kubernetes.io/name: odoo
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
