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

{{/*
Convert a Kubernetes storage quantity (500Gi, 100M, 2048) to whole kibibytes, so a shell script can
compare it against `df -Pk` output without having to parse suffixes itself. Binary suffixes (Ki, Mi,
Gi, Ti) and decimal SI suffixes (k, M, G, T) are different quantities and are converted separately;
a bare number is bytes. Rounds down, which keeps the comparison conservative.
*/}}
{{- define "solo.quantityToKibibytes" -}}
{{- $quantity := toString . -}}
{{- $number := regexFind "^[0-9]+(\\.[0-9]+)?" $quantity | float64 -}}
{{- $suffix := regexFind "[A-Za-z]+$" $quantity -}}
{{- if eq $suffix "Ki" -}}
{{- printf "%.0f" $number -}}
{{- else if eq $suffix "Mi" -}}
{{- printf "%.0f" (mulf $number 1024) -}}
{{- else if eq $suffix "Gi" -}}
{{- printf "%.0f" (mulf $number 1048576) -}}
{{- else if eq $suffix "Ti" -}}
{{- printf "%.0f" (mulf $number 1073741824) -}}
{{- else if eq $suffix "k" -}}
{{- printf "%.0f" (divf (mulf $number 1000) 1024) -}}
{{- else if eq $suffix "M" -}}
{{- printf "%.0f" (divf (mulf $number 1000000) 1024) -}}
{{- else if eq $suffix "G" -}}
{{- printf "%.0f" (divf (mulf $number 1000000000) 1024) -}}
{{- else if eq $suffix "T" -}}
{{- printf "%.0f" (divf (mulf $number 1000000000000) 1024) -}}
{{- else -}}
{{- printf "%.0f" (divf $number 1024) -}}
{{- end -}}
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
    {{- if .storageClassName }}
    storageClassName: {{ .storageClassName }}
    {{- end }}
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
