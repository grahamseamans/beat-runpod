#!/usr/bin/env bash
# Create, or update in place, the RunPod pod template that runs this image.
#
#   ./make-template.sh ghcr.io/<owner>/beat-runpod:<sha>
#
# REST API v1: POST /v1/templates creates; PATCH /v1/templates/{templateId} updates.
#   https://docs.runpod.io/api-reference/templates/POST/templates.md
#   https://docs.runpod.io/api-reference/templates/PATCH/templates/templateId.md
# The API key is read from $SECRETS/runpod_api_key (../secrets.sh, the one place) and only ever reaches curl through a header file on a
# file descriptor (never argv, never stdout). The template id is kept beside it in runpod_template_id.
set -euo pipefail

IMAGE=${1:?usage: make-template.sh <image ref, e.g. ghcr.io/<owner>/beat-runpod:<sha>>}
# a moving tag would let a rebuild change what the next pod runs with no record of which image solved what: the
# template is pinned to a commit tag (40 hex), the one build.yml pushes beside :latest
[[ $IMAGE =~ :[0-9a-f]{40}$ ]] || { echo "make-template.sh: '$IMAGE' is not pinned to a 40-hex commit tag; pass ghcr.io/<owner>/beat-runpod:<sha>" >&2; exit 1; }
source "$(dirname "$0")/../secrets.sh"
KEY_FILE=$SECRETS/runpod_api_key
ID_FILE=$SECRETS/runpod_template_id
API=https://rest.runpod.io/v1
[ -s "$KEY_FILE" ] || { echo "make-template.sh: no API key in $KEY_FILE" >&2; exit 1; }

# curl -H @file reads headers from a file (curl >= 7.55.0, https://curl.se/docs/manpage.html#-H); printf is a shell
# builtin, so the key never appears in any process's argv.
rest() {  # rest <method> <path> <json-body>; fails loudly on any non-2xx with RunPod's response body
  local out code
  out=$(curl -sS -w '\n%{http_code}' -X "$1" \
        -H @<(printf 'Authorization: Bearer %s\n' "$(<"$KEY_FILE")") \
        -H 'Content-Type: application/json' --data "$3" "$API$2")
  code=${out##*$'\n'}; out=${out%$'\n'*}
  if [[ $code != 2* ]]; then echo "RunPod $1 $2 -> HTTP $code: $out" >&2; exit 1; fi
  printf '%s' "$out"
}

# Template fields (schema: TemplateCreateInput in the POST reference above).
# - ports 22/tcp only: full ssh/scp/rsync over the public IP; no Jupyter (8888/http) in this image.
#   https://docs.runpod.io/pods/configuration/use-ssh.md ("ensure that TCP port 22 is exposed")
# - containerDiskInGb 30: the same as the studio pod.sh uses today. Whether RunPod counts the ~8 GB image against
#   it is an open question (README).
# - volumeInGb 0 + volumeMountPath /workspace: no per-pod volume; the network volume, when a pod is created with one,
#   mounts at /workspace. The image keeps everything in /opt, so the mount hides nothing.
# - env {}: no PUBLIC_KEY here. RunPod sets PUBLIC_KEY in every pod from the account's SSH keys
#   (https://docs.runpod.io/pods/templates/environment-variables.md, "Runpod-provided variables"), and a pod-level
#   env PUBLIC_KEY (what pod.sh passes) replaces it. Putting a key in the template would pin one key to every pod.
# - dockerEntrypoint/dockerStartCmd []: use the image's tini + /start.sh.
# - isPublic false: private to the account. The GHCR package itself must be public, or a containerRegistryAuthId added.
body=$(IMAGE=$IMAGE python3 -c '
import json, os
print(json.dumps({
    "name": "beat-runpod",
    "imageName": os.environ["IMAGE"],
    "category": "NVIDIA",
    "isServerless": False,
    "isPublic": False,
    "containerDiskInGb": 30,
    "volumeInGb": 0,
    "volumeMountPath": "/workspace",
    "ports": ["22/tcp"],
    "env": {},
    "dockerEntrypoint": [],
    "dockerStartCmd": [],
    "readme": "Boundary Lab + BEAT Engine 0.3.0 (CPU + CUDA), prebuilt. ssh as root on 22/tcp.",
}))')

if [ -s "$ID_FILE" ]; then
  id=$(<"$ID_FILE")
  # PATCH's TemplateUpdateInput has the same fields minus category and isServerless; drop those two.
  patch=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); [d.pop(k) for k in ("category", "isServerless")]; print(json.dumps(d))' "$body")
  rest PATCH "/templates/$id" "$patch" >/dev/null
  echo "template $id updated -> $IMAGE"
else
  created=$(rest POST /templates "$body")
  id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$created")
  echo "$id" > "$ID_FILE"
  echo "template $id created -> $IMAGE (id saved in $ID_FILE)"
fi
