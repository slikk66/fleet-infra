#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# hardway cluster-fix #5 — enable the Kubernetes API AGGREGATION LAYER.
#
# WHY: aggregated APIs (e.g. metrics.k8s.io served by metrics-server, which
# powers `kubectl top` + HPA) require kube-apiserver to authenticate to the
# extension apiserver via a front-proxy client cert, and to trust incoming
# requestheader identities. The stock k8s-the-hard-way apiserver omits all of
# this, so any APIService stays Available=False until these flags + PKI exist.
#
# WHAT: generates a front-proxy CA + proxy-client cert in /var/lib/kubernetes,
# adds the requestheader/proxy-client/aggregator-routing flags to the
# kube-apiserver systemd unit, and restarts it. Idempotent + backs up the unit.
#
# NOT GitOps — this is control-plane (systemd + PKI) on control-1, which Flux
# cannot manage. Run it ON control-1 as root:
#   ssh control-1@orb 'sudo bash -s' < scripts/hardway/05-enable-aggregation-layer.sh
# Roll back: restore the timestamped /etc/systemd/system/kube-apiserver.service.bak.*
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
PKI=/var/lib/kubernetes
UNIT=/etc/systemd/system/kube-apiserver.service

echo "[1/3] front-proxy CA + proxy-client cert"
if [[ ! -f "$PKI/front-proxy-ca.pem" ]]; then
  openssl genrsa -out "$PKI/front-proxy-ca-key.pem" 2048
  openssl req -x509 -new -nodes -key "$PKI/front-proxy-ca-key.pem" \
    -subj "/CN=front-proxy-ca" -days 3650 -out "$PKI/front-proxy-ca.pem"
  echo "  created front-proxy CA"
else
  echo "  front-proxy CA already present, skipping"
fi
if [[ ! -f "$PKI/front-proxy-client.pem" ]]; then
  openssl genrsa -out "$PKI/front-proxy-client-key.pem" 2048
  openssl req -new -key "$PKI/front-proxy-client-key.pem" \
    -subj "/CN=front-proxy-client" -out /tmp/fpc.csr
  printf "extendedKeyUsage=clientAuth\n" > /tmp/fpc.ext
  openssl x509 -req -in /tmp/fpc.csr -CA "$PKI/front-proxy-ca.pem" \
    -CAkey "$PKI/front-proxy-ca-key.pem" -CAcreateserial \
    -out "$PKI/front-proxy-client.pem" -days 3650 -extfile /tmp/fpc.ext
  rm -f /tmp/fpc.csr /tmp/fpc.ext
  echo "  created proxy-client cert (CN=front-proxy-client)"
else
  echo "  proxy-client cert already present, skipping"
fi
chmod 600 "$PKI"/front-proxy-*-key.pem

echo "[2/3] add aggregation flags to $UNIT"
if grep -q 'requestheader-client-ca-file' "$UNIT"; then
  echo "  flags already present, skipping"
else
  cp -a "$UNIT" "$UNIT.bak.$(date +%s)"
  python3 - "$UNIT" <<'PY'
import sys
unit = sys.argv[1]
flags = [
 "  --requestheader-client-ca-file=/var/lib/kubernetes/front-proxy-ca.pem \\",
 "  --requestheader-allowed-names=front-proxy-client \\",
 "  --requestheader-extra-headers-prefix=X-Remote-Extra- \\",
 "  --requestheader-group-headers=X-Remote-Group \\",
 "  --requestheader-username-headers=X-Remote-User \\",
 "  --proxy-client-cert-file=/var/lib/kubernetes/front-proxy-client.pem \\",
 "  --proxy-client-key-file=/var/lib/kubernetes/front-proxy-client-key.pem \\",
 "  --enable-aggregator-routing=true \\",
]
lines = open(unit).read().splitlines()
out = []
for l in lines:
    if l.strip().startswith("--v="):
        out.extend(flags)
    out.append(l)
open(unit, "w").write("\n".join(out) + "\n")
PY
  echo "  inserted 8 flags before --v="
fi

echo "[3/3] daemon-reload + restart kube-apiserver"
systemctl daemon-reload
systemctl restart kube-apiserver
sleep 6
systemctl is-active kube-apiserver && echo "  kube-apiserver active"
echo "DONE."
