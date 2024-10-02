{{- define "solo.testLabels" -}}
{{- if .Values.deployment.testMetadata.enabled -}}
{{- with .Values.deployment.testMetadata -}}
solo.hedera.com/testSuiteName: "{{ .testSuiteName }}"
solo.hedera.com/testName: "{{ .testName }}"
solo.hedera.com/testRunUID: "{{ .testRunUID }}"
solo.hedera.com/testCreationTimestamp: "{{ .testCreationTimestamp }}"
solo.hedera.com/testExpirationTimestamp: "{{ .testExpirationTimestamp }}"
solo.hedera.com/testRequester: "{{ .testRequester }}"
{{- end }}
{{- end }}
{{- end }}

{{- define "solo.hedera.security.context" -}}
runAsUser: 2000
runAsGroup: 2000
{{- end }}

{{- define "solo.root.security.context" -}}
runAsUser: 0
runAsGroup: 0
{{- end }}

{{- define "solo.root.security.context.privileged" -}}
runAsUser: 0
runAsGroup: 0
privileged: true
{{- end }}

{{- define "solo.defaultEnvVars" -}}
- name: POD_IP
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
{{- end }}

{{- define "solo.images.pullPolicy" -}}
{{ (.image).pullPolicy | default (((.defaults).root).image).pullPolicy }}
{{- end }}


{{- define "solo.container.image" -}}
{{- $reg := (.image).registry | default (((.defaults).root).image).registry -}}
{{- $repo := (.image).repository | default (((.defaults).root).image).repository -}}
{{- $tag := default (((.defaults).root).image).tag (.image).tag | default .Chart.AppVersion -}}
{{ $reg }}/{{ $repo }}:{{ $tag }}
{{- end }}

{{- define "minio.configEnv" -}}
export MINIO_ROOT_USER={{ include "minio.accessKey" . }}
export MINIO_ROOT_PASSWORD={{ include "minio.secretKey" . }}
{{- end -}}

{{- define "solo.volumeClaimTemplate" -}}
- metadata:
    name: {{ .name }}
    annotations:
      helm.sh/resource-policy: keep
    labels:
      solo.hedera.com/type: node-pvc
  spec:
    accessModes: [ "ReadWriteOnce" ]
    resources:
      requests:
        storage: {{ default "2Gi" .storage }}
{{- end -}}

{{- define "solo.volumeTemplate" -}}
- name: {{ .name }}
  {{- if .pvcEnabled }}
  persistentVolumeClaim:
    claimName: {{ .claimName }}
  {{- else }}
  emptyDir: {}
  {{- end }}
{{- end -}}
