#!/usr/bin/env bash
# =============================================================================
# get-eval-image.sh — Fetch a MyPCBench VM image for the NO-DOCKER QEMU path
# =============================================================================
# Produces a bootable qcow2 (and the matching OVMF UEFI firmware) on a host
# that has NO docker daemon and NO root — exactly what a shared GPU/compute
# node looks like. Fetches the current daily benchmark VM.
#
# Two fetch methods (auto-selected, override with --method):
#
#   skopeo   Pull the published QEMU image with `skopeo` (no docker daemon
#            needed) and extract the baked qcow2 + OVMF from its layers.
#            Works on any node with `skopeo` installed. DEFAULT when
#            available.
#   hf       Download the raw qcow2 from the HuggingFace dataset
#            (ljang0/mypcbench-qemu-baseline). Needs `huggingface_hub`.
#            Fallback when skopeo is unavailable.
#
# Output (under --out, default ./mypcbench-vm):
#   mypcbench.qcow2            base image (read-only; the runner makes overlays)
#   OVMF_CODE.fd, OVMF_VARS.fd UEFI firmware (only with the skopeo method)
#   env.sh                     `source` it to export MYPCBENCH_* for the runner
#
# Example:
#   bash scripts/get-eval-image.sh --out ./vm-current
#   source ./vm-current/env.sh
#   # free no-API boot sanity (confirms VM + Control API):
#   python3 agent-harness/run_mypcbench.py --backend qemu \
#       --qcow2_path "$MYPCBENCH_QCOW2" --agent_type dummy --model dummy \
#       --tasks_dir tasks/smoke_one --max_steps 4
# =============================================================================
set -euo pipefail

METHOD="auto"
OUT="./mypcbench-vm"
DOCKERHUB_ORG="ljang"
# HuggingFace DATASET repo (fetched below with repo_type="dataset", i.e.
# huggingface.co/datasets/ljang0/...). A same-named MODEL repo also exists but
# is stale/orphaned and must NOT be used — keep repo_type="dataset" everywhere.
HF_REPO="ljang0/mypcbench-qemu-baseline"
NO_DECOMPRESS=0

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --method) METHOD="$2"; shift 2;;
    --out)    OUT="$2"; shift 2;;
    --org)    DOCKERHUB_ORG="$2"; shift 2;;
    --hf-repo) HF_REPO="$2"; shift 2;;
    --no-decompress) NO_DECOMPRESS=1; shift;;
    -h|--help) usage 0;;
    *) echo "Unknown arg: $1" >&2; usage 1;;
  esac
done

QEMU_TAG="latest"
HF_FILE="michael_scott.qcow2"
QEMU_IMAGE="docker.io/${DOCKERHUB_ORG}/mypcbench-qemu:${QEMU_TAG}"

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

if [[ "$METHOD" == "auto" ]]; then
  if command -v skopeo >/dev/null 2>&1; then
    METHOD="skopeo"
  else
    METHOD="hf"
  fi
fi
echo "==> image      : current daily (latest)"
echo "==> method    : $METHOD"
echo "==> output    : $OUT"

if [[ "$METHOD" == "skopeo" ]]; then
  command -v skopeo  >/dev/null || { echo "skopeo not found — install it or use --method hf" >&2; exit 1; }
  command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }
  IMGDIR="$OUT/.oci-${QEMU_TAG}"
  echo "==> skopeo copy $QEMU_IMAGE  (≈6 GB, no docker daemon needed)"
  rm -rf "$IMGDIR"; mkdir -p "$IMGDIR"
  skopeo copy --quiet "docker://${QEMU_IMAGE}" "dir:${IMGDIR}"

  echo "==> locating qcow2 + OVMF layers"
  # The qcow2 lives in the largest layer; OVMF lives in the ubuntu/apt layer.
  mapfile -t LAYERS < <(python3 - "$IMGDIR" <<'PY'
import json,sys,os
d=sys.argv[1]
m=json.load(open(os.path.join(d,"manifest.json")))
for l in sorted(m["layers"], key=lambda x:-x["size"]):
    print(l["digest"].split(":")[1])
PY
)
  : > "$OUT/.x.log"
  GOT_QCOW2=0; GOT_OVMF=0
  for blob in "${LAYERS[@]}"; do
    [[ "$GOT_QCOW2" == 1 && "$GOT_OVMF" == 1 ]] && break
    # `tar -tf/-xf` (no `z`): GNU tar auto-detects the layer compression
    # (gzip / zstd / xz). skopeo preserves the source layer's original
    # codec, and buildkit images are commonly zstd — hardcoding `z`
    # silently failed on those with a misleading "no .qcow2 found".
    if [[ "$GOT_QCOW2" == 0 ]]; then
      q="$(tar -tf "$IMGDIR/$blob" 2>/dev/null | grep -m1 -E '\.qcow2$' || true)"
      if [[ -n "$q" ]]; then
        echo "    qcow2 in layer ${blob:0:12} -> $q"
        tar -xf "$IMGDIR/$blob" -C "$OUT" "$q"
        mv "$OUT/$q" "$OUT/mypcbench.qcow2"
        GOT_QCOW2=1; continue
      fi
    fi
    if [[ "$GOT_OVMF" == 0 ]]; then
      c="$(tar -tf "$IMGDIR/$blob" 2>/dev/null | grep -m1 -E 'OVMF_CODE.*\.fd$' || true)"
      if [[ -n "$c" ]]; then
        v="$(tar -tf "$IMGDIR/$blob" 2>/dev/null | grep -m1 -E 'OVMF_VARS.*\.fd$' || true)"
        echo "    OVMF in layer ${blob:0:12}"
        tar -xf "$IMGDIR/$blob" -C "$OUT" "$c" ${v:+"$v"}
        cp "$OUT/$c" "$OUT/OVMF_CODE.fd"
        [[ -n "$v" ]] && cp "$OUT/$v" "$OUT/OVMF_VARS.fd"
        GOT_OVMF=1
      fi
    fi
  done
  [[ "$GOT_QCOW2" == 1 ]] || { echo "ERROR: no .qcow2 found in image layers" >&2; exit 1; }
  rm -rf "$IMGDIR" "$OUT/baseline" "$OUT/usr" 2>/dev/null || true

elif [[ "$METHOD" == "hf" ]]; then
  command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }
  python3 -c 'import huggingface_hub' 2>/dev/null || {
    echo "ERROR: the 'hf' method needs huggingface_hub. Install it with" >&2
    echo "  pip install huggingface_hub" >&2
    echo "or install 'skopeo' and re-run (skopeo is the default method)." >&2
    exit 1
  }
  python3 - "$HF_REPO" "$HF_FILE" "$OUT" <<'PY'
import sys
from huggingface_hub import hf_hub_download
repo,fn,out=sys.argv[1:4]
p=hf_hub_download(repo_id=repo, filename=fn, repo_type="dataset", local_dir=out)
print("downloaded:",p)
PY
  mv -f "$OUT/$HF_FILE" "$OUT/mypcbench.qcow2"
  echo "NOTE: HF method does not ship OVMF — install it (apt install ovmf /"
  echo "      dnf install edk2-ovmf) or set MYPCBENCH_OVMF_CODE yourself."
else
  echo "--method must be auto|skopeo|hf" >&2; exit 1
fi

# Decompress qcow2 clusters for fast in-VM I/O.
#
# The published image is zlib-compressed at the qcow2 cluster level (~5 GB
# on disk vs ~10 GB uncompressed). Every host read decompresses on the fly,
# which serializes I/O when 4 VMs + 17 web apps + GNOME boot at once and
# manifests as transient connection-refused failures on the in-VM control
# HTTP server. Converting to uncompressed clusters once, here, removes the
# decompression overhead entirely and matches the runtime behavior of the
# paper-baseline image. Skip with --no-decompress if you're disk-constrained
# (or can't install qemu-img) and want to keep the ~5 GB on-disk size at the
# cost of occasional retry storms on slower hosts.
if [[ "$NO_DECOMPRESS" == 0 ]] && command -v qemu-img >/dev/null 2>&1; then
  compressed_pct="$(qemu-img check "$OUT/mypcbench.qcow2" 2>/dev/null \
                   | sed -nE 's/.*([0-9.]+)% compressed clusters.*/\1/p' | head -1)"
  if [[ -n "$compressed_pct" ]] && [[ "${compressed_pct%.*}" -gt 0 ]]; then
    echo "==> decompressing qcow2 (${compressed_pct}% compressed clusters → 0%)"
    echo "    (rationale: avoid host decompression overhead during multi-VM"
    echo "     boot; skip with --no-decompress if disk-constrained)"
    tmp_dst="$OUT/mypcbench.qcow2.uncompressed"
    if qemu-img convert -p -O qcow2 -o cluster_size=64K \
                        "$OUT/mypcbench.qcow2" "$tmp_dst"; then
      mv -f "$tmp_dst" "$OUT/mypcbench.qcow2"
      qemu-img check "$OUT/mypcbench.qcow2" | sed 's/^/    /'
    else
      echo "    qemu-img convert failed — keeping the compressed image" >&2
      rm -f "$tmp_dst"
    fi
  else
    echo "==> qcow2 already uncompressed; no convert needed"
  fi
else
  if [[ "$NO_DECOMPRESS" == 1 ]]; then
    echo "==> skipping decompress per --no-decompress"
  else
    echo "==> skipping decompress (qemu-img not on PATH)"
    echo "    install qemu-utils/qemu-img to enable; otherwise the runner"
    echo "    may see transient localhost:* connection-refused under load."
  fi
fi

# Emit a sourceable env file
{
  echo "# source this before running agent-harness/run_mypcbench.py --backend qemu"
  echo "export MYPCBENCH_QCOW2='$OUT/mypcbench.qcow2'"
  [[ -f "$OUT/OVMF_CODE.fd" ]] && echo "export MYPCBENCH_OVMF_CODE='$OUT/OVMF_CODE.fd'"
  [[ -f "$OUT/OVMF_VARS.fd" ]] && echo "export MYPCBENCH_OVMF_VARS='$OUT/OVMF_VARS.fd'"
} > "$OUT/env.sh"

echo
echo "==> DONE. Image ready at: $OUT/mypcbench.qcow2"
ls -lh "$OUT"/mypcbench.qcow2 "$OUT"/OVMF_*.fd 2>/dev/null || true
echo
echo "Next:"
echo "  source $OUT/env.sh"
echo "  # free no-API boot sanity (confirms VM + Control API):"
echo "  python3 agent-harness/run_mypcbench.py --backend qemu \\"
echo "      --qcow2_path \"\$MYPCBENCH_QCOW2\" --agent_type dummy --model dummy \\"
echo "      --tasks_dir tasks/smoke_one --max_steps 4"
